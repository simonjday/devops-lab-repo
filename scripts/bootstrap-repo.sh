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

# ── Apply ArgoCD project + ApplicationSet ─────────────────────────────────────
if command -v kubectl &>/dev/null; then
  log "Applying ArgoCD project and ApplicationSet to cluster ..."
  kubectl apply -f argocd/projects/devops-lab-project.yaml
  kubectl apply -f argocd/appsets/devops-lab-appset.yaml
  echo ""
  success "ApplicationSet applied — ArgoCD will now sync all apps"
  echo ""
  kubectl get applications -n argocd
else
  log "kubectl not found — apply manually:"
  echo "  kubectl apply -f argocd/projects/devops-lab-project.yaml"
  echo "  kubectl apply -f argocd/appsets/devops-lab-appset.yaml"
fi

echo ""
echo -e "${BOLD}Done! Repo: ${REPO_URL}${NC}"
echo ""
echo "Next steps:"
echo "  1. Open ArgoCD UI → http://localhost:30950"
echo "  2. Watch apps sync under project: devops-lab"
echo "  3. Port-forward Grafana: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
echo "  4. Apply policy tests: kubectl apply -f apps/policy-test-suite/"
