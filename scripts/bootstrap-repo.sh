#!/usr/bin/env bash
# =============================================================================
# DevOps Lab — Full Bootstrap
# Creates the kind cluster, installs all platform tooling, pushes to GitHub,
# and wires up ArgoCD to sync everything from the repo.
#
# Prerequisites: docker, kind, kubectl, helm, git, gh
# Usage:
#   ./scripts/bootstrap-repo.sh --org <github-user-or-org>
#   ./scripts/bootstrap-repo.sh --org <github-user-or-org> --cluster my-lab --private
#   ./scripts/bootstrap-repo.sh --skip-github   # cluster only, no GitHub push
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
CLUSTER_NAME="devops-lab"
REPO_NAME="devops-lab-repo"
VISIBILITY="public"
ORG=""
DEFAULT_BRANCH="main"
SKIP_GITHUB=false
ARGOCD_VERSION="v2.11.3"
ARGOCD_NAMESPACE="argocd"

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --org)          ORG="$2";           shift 2 ;;
    --cluster)      CLUSTER_NAME="$2";  shift 2 ;;
    --name)         REPO_NAME="$2";     shift 2 ;;
    --private)      VISIBILITY="private"; shift ;;
    --skip-github)  SKIP_GITHUB=true;   shift ;;
    --help|-h)
      echo "Usage: $0 --org <github-user> [--cluster <name>] [--private] [--skip-github]"
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

# ── Script location (repo root is one level up from scripts/) ─────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
cd "${REPO_ROOT}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 0 — Preflight checks
# ═════════════════════════════════════════════════════════════════════════════
header "Step 0 — Preflight Checks"

check() { command -v "$1" &>/dev/null || error "'$1' not found. Install it first."; success "$1"; }
check docker
check kind
check kubectl
check helm
check git
docker info &>/dev/null || error "Docker daemon is not running"

if [ "${SKIP_GITHUB}" = false ]; then
  check gh
  gh auth status &>/dev/null || error "Not logged into GitHub CLI. Run: gh auth login"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — Kind cluster
# ═════════════════════════════════════════════════════════════════════════════
header "Step 1 — Kind Cluster: ${CLUSTER_NAME}"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
  warn "Delete it first with: kind delete cluster --name ${CLUSTER_NAME}"
else
  log "Writing kind config ..."
  cat > /tmp/kind-${CLUSTER_NAME}.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # ArgoCD UI
      - containerPort: 30950
        hostPort: 9080
        protocol: TCP
      # Grafana
      - containerPort: 30300
        hostPort: 3000
        protocol: TCP
      # Prometheus
      - containerPort: 30900
        hostPort: 9090
        protocol: TCP
      # General ingress
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "workload=apps"

networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
EOF

  kind create cluster --config /tmp/kind-${CLUSTER_NAME}.yaml
  success "Cluster '${CLUSTER_NAME}' created"
fi

# Switch context
kubectl config use-context "kind-${CLUSTER_NAME}"
success "Context: kind-${CLUSTER_NAME}"
kubectl get nodes -o wide

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — Namespaces
# ═════════════════════════════════════════════════════════════════════════════
header "Step 2 — Namespaces"

for ns in "${ARGOCD_NAMESPACE}" monitoring kyverno apps apps-staging policy-test; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  success "namespace/${ns}"
done
kubectl apply -f base/namespaces/namespaces.yaml

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — ArgoCD
# ═════════════════════════════════════════════════════════════════════════════
header "Step 3 — ArgoCD ${ARGOCD_VERSION}"

ARGOCD_INSTALLED=$(kubectl get deployment argocd-server -n "${ARGOCD_NAMESPACE}" \
  --ignore-not-found --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "${ARGOCD_INSTALLED}" = "0" ]; then
  kubectl apply -n "${ARGOCD_NAMESPACE}" \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

  log "Waiting for ArgoCD CRDs ..."
  kubectl wait --for=condition=established \
    crd/applications.argoproj.io \
    crd/applicationsets.argoproj.io \
    crd/appprojects.argoproj.io \
    --timeout=120s

  log "Waiting for argocd-server rollout ..."
  kubectl rollout status deployment/argocd-server \
    -n "${ARGOCD_NAMESPACE}" --timeout=300s

  # Insecure mode for local dev (no TLS redirect)
  kubectl patch deployment argocd-server -n "${ARGOCD_NAMESPACE}" \
    --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

  # NodePort wired to the extraPortMapping above (hostPort 9080 → nodePort 30950)
  kubectl apply -f - << EOF
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: ${ARGOCD_NAMESPACE}
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - name: http
      port: 80
      targetPort: 8080
      nodePort: 30950
EOF
  success "ArgoCD installed"
else
  warn "ArgoCD already installed — skipping"
  kubectl wait --for=condition=established \
    crd/applications.argoproj.io crd/appprojects.argoproj.io \
    --timeout=60s 2>/dev/null || true
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — Prometheus + Grafana
# ═════════════════════════════════════════════════════════════════════════════
header "Step 4 — kube-prometheus-stack"

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community --fail-on-repo-update-fail 2>/dev/null || helm repo update

if ! helm status kube-prometheus-stack -n monitoring &>/dev/null; then
  helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --set grafana.enabled=true \
    --set grafana.adminPassword=admin \
    --set "grafana.service.type=NodePort" \
    --set "grafana.service.nodePort=30300" \
    --set prometheus.prometheusSpec.retention=12h \
    --set "prometheus.service.type=NodePort" \
    --set "prometheus.service.nodePort=30900" \
    --set alertmanager.enabled=true \
    --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
    --set prometheus.prometheusSpec.resources.limits.memory=512Mi \
    --wait --timeout=5m
  success "kube-prometheus-stack installed"
else
  warn "kube-prometheus-stack already installed — skipping"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 — Kyverno
# ═════════════════════════════════════════════════════════════════════════════
header "Step 5 — Kyverno"

helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo update kyverno 2>/dev/null || helm repo update

if ! helm status kyverno -n kyverno &>/dev/null; then
  helm upgrade --install kyverno kyverno/kyverno \
    --namespace kyverno \
    --set replicaCount=1 \
    --wait --timeout=5m

  kubectl wait --for=condition=established \
    crd/clusterpolicies.kyverno.io \
    --timeout=120s
  success "Kyverno installed"
else
  warn "Kyverno already installed — skipping"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 — RBAC (Bifrost / MCP viewer SA)
# ═════════════════════════════════════════════════════════════════════════════
header "Step 6 — RBAC"
kubectl apply -f base/rbac/rbac.yaml
success "Viewer ServiceAccount ready"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7 — GitHub repo + push
# ═════════════════════════════════════════════════════════════════════════════
header "Step 7 — GitHub Repository"

if [ "${SKIP_GITHUB}" = true ]; then
  warn "--skip-github set — skipping repo creation and push"
  REPO_URL="https://github.com/${ORG:-YOUR_ORG}/${REPO_NAME}"
else
  [ -z "${ORG}" ] && error "--org is required unless --skip-github is set"
  GH_USER=$(gh api user --jq .login)
  OWNER="${ORG:-${GH_USER}}"
  REPO_URL="https://github.com/${OWNER}/${REPO_NAME}"

  log "GitHub user: ${GH_USER} | Owner: ${OWNER}"

  if gh repo view "${OWNER}/${REPO_NAME}" &>/dev/null; then
    warn "Repo ${OWNER}/${REPO_NAME} already exists — skipping creation"
  else
    gh repo create "${OWNER}/${REPO_NAME}" \
      --${VISIBILITY} \
      --description "DevOps Lab — kind + ArgoCD + Prometheus + Kyverno"
    success "Repo created: ${REPO_URL}"
  fi

  # Git init + patch + push
  if [ ! -d .git ]; then
    git init
    git checkout -b "${DEFAULT_BRANCH}" 2>/dev/null || true
    git remote add origin "git@github.com:${OWNER}/${REPO_NAME}.git"
  else
    git remote set-url origin "git@github.com:${OWNER}/${REPO_NAME}.git" 2>/dev/null || true
  fi

  # Patch YOUR_ORG placeholder in ArgoCD manifests (perl: cross-platform)
  log "Patching repo URL into ArgoCD manifests ..."
  find argocd/ -name '*.yaml' -print0 | \
    xargs -0 perl -pi -e "s|https://github\.com/YOUR_ORG/devops-lab-repo|${REPO_URL}|g"
  success "Manifests updated: ${REPO_URL}"

  git add -A
  git diff --cached --quiet && log "Nothing new to commit" || \
    git commit -m "chore: bootstrap — patch ArgoCD repo URL to ${REPO_URL}"

  git push -u origin "${DEFAULT_BRANCH}" --force
  success "Pushed to ${REPO_URL}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8 — ArgoCD project + ApplicationSet
# ═════════════════════════════════════════════════════════════════════════════
header "Step 8 — ArgoCD Project + ApplicationSet"

kubectl apply -f argocd/projects/devops-lab-project.yaml 2>&1 \
  | grep -v "unrecognized format" || true

kubectl apply -f argocd/appsets/devops-lab-appset.yaml 2>&1 \
  | grep -v "unrecognized format" || true

success "ApplicationSet applied — ArgoCD will begin syncing all apps"

# Wait a moment for apps to be created
sleep 5
kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret \
  argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "(not ready yet)")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  DevOps Lab — Bootstrap Complete 🚀              ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Cluster:${NC}      kind-${CLUSTER_NAME}"
echo -e "  ${BOLD}Repo:${NC}         ${REPO_URL}"
echo ""
echo -e "  ${BOLD}ArgoCD UI:${NC}    http://localhost:9080"
echo -e "  ${BOLD}             ${NC} user: admin / pass: ${ARGOCD_PASSWORD}"
echo -e "  ${BOLD}Grafana:${NC}      http://localhost:3000   (admin / admin)"
echo -e "  ${BOLD}Prometheus:${NC}   http://localhost:9090"
echo ""
echo -e "  ${YELLOW}Note:${NC} URLs work directly — no port-forward needed"
echo -e "        (kind extraPortMappings configured during cluster creation)"
echo ""
echo -e "  ${BOLD}Quick commands:${NC}"
echo "    kubectl get applications -n argocd"
echo "    kubectl get clusterpolicies"
echo "    kubectl get pods -n apps"
echo "    ./scripts/demo-flow.sh"
echo ""
echo -e "  ${BOLD}Teardown:${NC}"
echo "    kind delete cluster --name ${CLUSTER_NAME}"
