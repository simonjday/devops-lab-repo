#!/usr/bin/env bash
# =============================================================================
# Bootstrap Script — create GitHub repo and push all manifests
# Prerequisites: gh CLI (brew install gh), git
# Usage: ./scripts/bootstrap-repo.sh --org <your-github-org-or-user> [--private]
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

REPO_NAME="devops-lab-repo"
VISIBILITY="public"
ORG=""
DEFAULT_BRANCH="main"

while [[ $# -gt 0 ]]; do
  case $1 in
    --org)     ORG="$2";          shift 2 ;;
    --name)    REPO_NAME="$2";    shift 2 ;;
    --private) VISIBILITY="private"; shift ;;
    *)         echo "Unknown arg: $1"; exit 1 ;;
  esac
done

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Checks ────────────────────────────────────────────────────────────────────
command -v gh  &>/dev/null || error "gh CLI not found. Install: brew install gh"
command -v git &>/dev/null || error "git not found"

gh auth status &>/dev/null || error "Not logged into GitHub. Run: gh auth login"

GH_USER=$(gh api user --jq .login)
OWNER="${ORG:-$GH_USER}"
log "GitHub user: ${GH_USER} | Repo owner: ${OWNER}"

# ── Create GitHub repo ────────────────────────────────────────────────────────
REPO_URL="https://github.com/${OWNER}/${REPO_NAME}"

if gh repo view "${OWNER}/${REPO_NAME}" &>/dev/null; then
  log "Repo ${OWNER}/${REPO_NAME} already exists — skipping creation"
else
  log "Creating ${VISIBILITY} repo: ${OWNER}/${REPO_NAME} ..."
  # Use owner/name format — works for both personal accounts and orgs
  gh repo create "${OWNER}/${REPO_NAME}" \
    --${VISIBILITY} \
    --description "DevOps Lab — kind + ArgoCD + Prometheus + Kyverno"
  success "Repo created: ${REPO_URL}"
fi

# ── Init git and push ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

cd "${REPO_ROOT}"

if [ ! -d .git ]; then
  git init
  git checkout -b "${DEFAULT_BRANCH}" 2>/dev/null || git checkout "${DEFAULT_BRANCH}" 2>/dev/null || true
  git remote add origin "git@github.com:${OWNER}/${REPO_NAME}.git"
else
  log "Git already initialised"
  git remote set-url origin "git@github.com:${OWNER}/${REPO_NAME}.git" 2>/dev/null || true
fi

# Patch repo URL into all ArgoCD manifests
log "Patching repo URL into ArgoCD manifests ..."
find argocd/ -name '*.yaml' -exec \
  sed -i "s|https://github.com/YOUR_ORG/devops-lab-repo|${REPO_URL}|g" {} \;
success "ArgoCD manifests updated with: ${REPO_URL}"

# Commit and push
git add -A
git commit -m "feat: initial devops-lab repo scaffold

Components:
- Base namespaces and RBAC (MCP/Bifrost viewer SA)
- ArgoCD project, applications, and ApplicationSet
- Sample apps: guestbook, podinfo, load-generator
- Kyverno policy suite (7 policies)
- Prometheus alerting rules
- Policy test suite (compliant + violation pods)
- GitHub Actions CI workflow
" 2>/dev/null || log "Nothing new to commit"

git push -u origin "${DEFAULT_BRANCH}" --force

success "Pushed to ${REPO_URL}"

# ── Cluster bootstrap — install platform tooling before applying CRs ──────────
if ! command -v kubectl &>/dev/null; then
  log "kubectl not found — skipping cluster bootstrap. Apply manually:"
  echo "  kubectl apply -f argocd/projects/devops-lab-project.yaml"
  echo "  kubectl apply -f argocd/appsets/devops-lab-appset.yaml"
else

  ARGOCD_VERSION="v2.11.3"
  ARGOCD_NAMESPACE="argocd"

  # ── 1. Namespaces ────────────────────────────────────────────────────────────
  log "Applying base namespaces ..."
  kubectl apply -f base/namespaces/namespaces.yaml
  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace monitoring              --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace kyverno                --dry-run=client -o yaml | kubectl apply -f -

  # ── 2. ArgoCD — install CRDs + controllers first ────────────────────────────
  ARGOCD_INSTALLED=$(kubectl get deployment argocd-server -n "${ARGOCD_NAMESPACE}" \
    --ignore-not-found --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [ "${ARGOCD_INSTALLED}" = "0" ]; then
    log "Installing ArgoCD ${ARGOCD_VERSION} ..."
    kubectl apply -n "${ARGOCD_NAMESPACE}" \
      -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

    log "Waiting for ArgoCD CRDs to be established ..."
    kubectl wait --for=condition=established \
      crd/applications.argoproj.io \
      crd/applicationsets.argoproj.io \
      crd/appprojects.argoproj.io \
      --timeout=120s

    log "Waiting for argocd-server to be ready ..."
    kubectl rollout status deployment/argocd-server \
      -n "${ARGOCD_NAMESPACE}" --timeout=300s

    # Patch for insecure local mode + expose NodePort
    kubectl patch deployment argocd-server -n "${ARGOCD_NAMESPACE}" \
      --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]' \
      2>/dev/null || true

    kubectl apply -f - <<EOF
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
    log "ArgoCD already installed — skipping"
    # Still wait for CRDs in case it's mid-install
    kubectl wait --for=condition=established \
      crd/applications.argoproj.io \
      crd/appprojects.argoproj.io \
      --timeout=60s 2>/dev/null || true
  fi

  # ── 3. Helm charts — Prometheus + Kyverno ───────────────────────────────────
  if ! command -v helm &>/dev/null; then
    log "helm not found — skipping Prometheus and Kyverno install"
  else
    helm repo add prometheus-community \
      https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
    helm repo update

    if ! helm status kube-prometheus-stack -n monitoring &>/dev/null; then
      log "Installing kube-prometheus-stack ..."
      helm upgrade --install kube-prometheus-stack \
        prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set grafana.enabled=true \
        --set grafana.adminPassword=admin \
        --set prometheus.prometheusSpec.retention=12h \
        --set alertmanager.enabled=true \
        --wait --timeout=5m
      success "Prometheus stack installed"
    else
      log "kube-prometheus-stack already installed — skipping"
    fi

    if ! helm status kyverno -n kyverno &>/dev/null; then
      log "Installing Kyverno ..."
      helm upgrade --install kyverno kyverno/kyverno \
        --namespace kyverno \
        --set replicaCount=1 \
        --wait --timeout=5m

      log "Waiting for Kyverno CRDs ..."
      kubectl wait --for=condition=established \
        crd/clusterpolicies.kyverno.io \
        --timeout=120s
      success "Kyverno installed"
    else
      log "Kyverno already installed — skipping"
    fi
  fi

  # ── 4. RBAC ──────────────────────────────────────────────────────────────────
  log "Applying RBAC ..."
  kubectl apply -f base/rbac/rbac.yaml

  # ── 5. ArgoCD project + ApplicationSet (CRDs now guaranteed to exist) ────────
  log "Applying ArgoCD project ..."
  kubectl apply -f argocd/projects/devops-lab-project.yaml

  log "Applying ArgoCD ApplicationSet ..."
  kubectl apply -f argocd/appsets/devops-lab-appset.yaml

  ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" get secret \
    argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "(secret not ready yet)")

  echo ""
  success "Cluster bootstrap complete"
  echo ""
  kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
  echo ""
  echo -e "${BOLD}ArgoCD UI  →${NC} http://localhost:30950  (admin / ${ARGOCD_PASSWORD})"
  echo -e "${BOLD}Grafana    →${NC} kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
fi

echo ""
echo -e "${BOLD}Done! Repo: ${REPO_URL}${NC}"
echo ""
echo "Next steps:"
echo "  1. Open ArgoCD UI → http://localhost:30950"
echo "  2. Watch apps sync under project: devops-lab"
echo "  3. Port-forward Grafana: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "  4. Apply policy tests: kubectl apply -f apps/policy-test-suite/"
