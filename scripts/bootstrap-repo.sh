#!/usr/bin/env bash
# =============================================================================
# DevOps Lab — Full Bootstrap
# Creates the kind cluster, installs all platform tooling, pushes to GitHub,
# and wires up ArgoCD to sync everything from the repo.
#
# Usage:
#   ./scripts/bootstrap-repo.sh --org <github-org-or-user>
#   ./scripts/bootstrap-repo.sh --org simonjday
#
# Idempotent — safe to re-run. Skips steps that are already done.
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}═══ $* ═══${NC}"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
GITHUB_ORG=""
REPO_NAME="devops-lab-repo"
CLUSTER_NAME="devops-lab"
ARGOCD_VERSION="v2.11.3"
ARGOCD_NS="argocd"
KYVERNO_VERSION="3.2.6"
PROM_STACK_VERSION="58.7.2"

# ── Args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --org)  GITHUB_ORG="$2"; shift 2 ;;
    *)      error "Unknown argument: $1" ;;
  esac
done
[[ -z "$GITHUB_ORG" ]] && error "Usage: $0 --org <github-user-or-org>"

REPO_URL="https://github.com/${GITHUB_ORG}/${REPO_NAME}"

# ── Preflight ─────────────────────────────────────────────────────────────────
header "Preflight checks"
for cmd in docker kind kubectl helm git gh; do
  command -v "$cmd" &>/dev/null || error "'$cmd' not found — please install it first"
  success "$cmd found"
done

# ── STEP 1: kind cluster ─────────────────────────────────────────────────────
header "STEP 1 — kind cluster"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  success "Cluster '${CLUSTER_NAME}' already exists — skipping"
else
  log "Creating kind cluster '${CLUSTER_NAME}' ..."
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080   # ArgoCD
        hostPort: 9080
        protocol: TCP
      - containerPort: 30030   # Grafana
        hostPort: 3000
        protocol: TCP
      - containerPort: 30090   # Prometheus
        hostPort: 9090
        protocol: TCP
      - containerPort: 30093   # Alertmanager
        hostPort: 9093
        protocol: TCP
EOF
  success "Cluster created"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── STEP 2: namespaces ───────────────────────────────────────────────────────
header "STEP 2 — Namespaces"
for ns in argocd monitoring kyverno apps apps-staging; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
success "Namespaces ready"

# ── STEP 3: ArgoCD ───────────────────────────────────────────────────────────
header "STEP 3 — ArgoCD ${ARGOCD_VERSION}"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
if kubectl get deployment argocd-server -n "$ARGOCD_NS" &>/dev/null; then
  success "ArgoCD already installed — skipping Helm install"
else
  log "Installing ArgoCD ..."
  kubectl apply -n "$ARGOCD_NS" -f "$ARGOCD_MANIFEST"
fi

log "Waiting for ArgoCD CRDs ..."
for crd in applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io; do
  kubectl wait --for=condition=established crd/"$crd" --timeout=120s
done

log "Patching argocd-server to --insecure ..."
kubectl patch deployment argocd-server -n "$ARGOCD_NS" \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]' \
  2>/dev/null || true

log "Exposing ArgoCD on NodePort 30080 ..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
  namespace: argocd
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 30080
EOF

log "Waiting for argocd-server rollout ..."
kubectl rollout status deployment/argocd-server -n "$ARGOCD_NS" --timeout=180s
success "ArgoCD ready → http://localhost:9080"

# ── STEP 4: kube-prometheus-stack ────────────────────────────────────────────
header "STEP 4 — kube-prometheus-stack ${PROM_STACK_VERSION}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community
if helm status kube-prometheus-stack -n monitoring &>/dev/null; then
  success "kube-prometheus-stack already installed — skipping"
else
  log "Installing kube-prometheus-stack ..."
  helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version "$PROM_STACK_VERSION" \
    --namespace monitoring \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort=30030 \
    --set prometheus.service.type=NodePort \
    --set prometheus.service.nodePort=30090 \
    --set alertmanager.service.type=NodePort \
    --set alertmanager.service.nodePort=30093 \
    --set grafana.adminPassword=admin \
    --wait --timeout=5m
  success "kube-prometheus-stack ready → http://localhost:3000 (admin/admin)"
fi

# ── STEP 5: Kyverno ──────────────────────────────────────────────────────────
header "STEP 5 — Kyverno ${KYVERNO_VERSION}"
helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
helm repo update kyverno
if helm status kyverno -n kyverno &>/dev/null; then
  success "Kyverno already installed — skipping"
else
  log "Installing Kyverno ..."
  helm install kyverno kyverno/kyverno \
    --version "$KYVERNO_VERSION" \
    --namespace kyverno \
    --wait --timeout=5m
  success "Kyverno ready"
fi

log "Waiting for Kyverno ClusterPolicy CRD ..."
kubectl wait --for=condition=established crd/clusterpolicies.kyverno.io --timeout=120s

# ── STEP 6: GitHub repo ──────────────────────────────────────────────────────
header "STEP 6 — GitHub repo"
log "GitHub user: ${GITHUB_ORG}"
if gh repo view "${GITHUB_ORG}/${REPO_NAME}" &>/dev/null; then
  success "Repo ${GITHUB_ORG}/${REPO_NAME} already exists — skipping creation"
else
  log "Creating repo ${GITHUB_ORG}/${REPO_NAME} ..."
  gh repo create "${GITHUB_ORG}/${REPO_NAME}" --public --description "DevOps Lab GitOps repo"
  success "Repo created: ${REPO_URL}"
fi

if [[ ! -d .git ]]; then
  git init
  git remote add origin "${REPO_URL}.git"
else
  success "Git already initialised"
fi

# ── Patch repoURL into ArgoCD manifests ──────────────────────────────────────
log "Patching repo URL into ArgoCD manifests ..."
find argocd -name "*.yaml" -print0 | xargs -0 \
  perl -pi -e "s|https://github.com/YOUR_ORG/${REPO_NAME}|${REPO_URL}|g"
success "ArgoCD manifests updated with: ${REPO_URL}"

# ── STEP 7: ArgoCD AppProject + ApplicationSet ───────────────────────────────
header "STEP 7 — ArgoCD AppProject + ApplicationSet"

log "Applying AppProject ..."
kubectl apply -f argocd/projects/devops-lab-project.yaml

log "Applying ApplicationSet (with ignoreDifferences for Kyverno webhook fields) ..."
# NOTE: This ApplicationSet includes ignoreDifferences for fields that Kyverno's
# admission webhook injects into ClusterPolicy resources after ArgoCD applies them
# (spec.admission, spec.emitWarning, autogen-* rules, etc). Without this, ArgoCD
# loops OutOfSync forever even though each sync operation succeeds.
kubectl apply -f - <<'APPSET'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: devops-lab
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - name: guestbook
            path: apps/guestbook
            namespace: apps
          - name: podinfo
            path: apps/podinfo
            namespace: apps
          - name: load-generator
            path: apps/load-generator
            namespace: apps
          - name: kyverno-policies
            path: kyverno/policies
            namespace: kyverno
          - name: prometheus-rules
            path: prometheus/rules
            namespace: monitoring
  template:
    metadata:
      name: "{{.name}}"
      namespace: argocd
      labels:
        app.kubernetes.io/part-of: devops-lab
        generator: appset
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: devops-lab
      source:
        repoURL: https://github.com/simonjday/devops-lab-repo
        targetRevision: HEAD
        path: "{{.path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{.namespace}}"
      ignoreDifferences:
        - group: kyverno.io
          kind: ClusterPolicy
          jqPathExpressions:
            - .spec.admission
            - .spec.emitWarning
            - .spec.rules[].skipBackgroundRequests
            - .spec.rules[].validate.allowExistingViolations
            - .spec.rules[].validate.foreach[].deny.conditions.any[].message
            - .status
        - group: kyverno.io
          kind: ClusterPolicy
          jqPathExpressions:
            - .spec.rules[] | select(.name | startswith("autogen-"))
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
          - RespectIgnoreDifferences=true
        retry:
          limit: 3
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
APPSET

success "ApplicationSet applied — ArgoCD will now sync all apps"

# ── STEP 8: Push to GitHub ───────────────────────────────────────────────────
header "STEP 8 — Push to GitHub"
git add -A
git diff --cached --quiet || git commit -m "feat: devops-lab bootstrap

- ArgoCD ApplicationSet with ignoreDifferences for Kyverno webhook fields
- kube-prometheus-stack + Kyverno via Helm
- Kyverno ClusterPolicies, Prometheus rules, sample apps"
git push -u origin main 2>/dev/null || git push -u origin master 2>/dev/null || true
success "Repo pushed: ${REPO_URL}"

# ── Done ─────────────────────────────────────────────────────────────────────
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "<retrieve manually>")

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║        DevOps Lab — Bootstrap Complete       ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}ArgoCD${NC}       http://localhost:9080  (admin / ${ARGOCD_PASS})"
echo -e "  ${BOLD}Grafana${NC}      http://localhost:3000  (admin / admin)"
echo -e "  ${BOLD}Prometheus${NC}   http://localhost:9090"
echo -e "  ${BOLD}Alertmanager${NC} http://localhost:9093"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    kubectl get applications -n argocd"
echo "    kubectl get clusterpolicies"
echo "    kubectl get pods -n apps"
echo ""
echo -e "  ${BOLD}Shutdown (saves Docker resources):${NC}"
echo "    ./scripts/cluster.sh stop"
echo ""
echo -e "  ${BOLD}Teardown:${NC}"
echo "    kind delete cluster --name ${CLUSTER_NAME}"
