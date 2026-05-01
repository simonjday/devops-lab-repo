#!/usr/bin/env bash
# =============================================================================
# Bifrost + MCP Server Setup
# Generates the kubeconfig SA token and prints connection config for:
#   - Bifrost (AI gateway proxy for Kubernetes)
#   - Any MCP server needing cluster access
# =============================================================================
set -euo pipefail

CLUSTER_NAME="${KIND_CLUSTER:-devops-lab}"
SA_NAMESPACE="apps"
SA_NAME="devops-lab-viewer"
SECRET_NAME="devops-lab-viewer-token"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# Make sure we're on the right context
kubectl config use-context "kind-${CLUSTER_NAME}" 2>/dev/null || true

log "Applying RBAC for viewer service account ..."
kubectl apply -f base/rbac/rbac.yaml

log "Waiting for SA token secret to be populated ..."
for i in {1..30}; do
  TOKEN=$(kubectl get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "${TOKEN}" ] && break
  sleep 2
done
[ -z "${TOKEN}" ] && { echo "ERROR: Could not get token"; exit 1; }

CA=$(kubectl get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | base64 | tr -d '\n')

API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

success "Service account token retrieved"

# ── Write kubeconfig for external tools ───────────────────────────────────────
KUBECONFIG_FILE="./devops-lab-viewer.kubeconfig"
cat > "${KUBECONFIG_FILE}" << EOF
apiVersion: v1
kind: Config
clusters:
  - name: devops-lab
    cluster:
      server: ${API_SERVER}
      certificate-authority-data: ${CA}
contexts:
  - name: devops-lab-viewer
    context:
      cluster: devops-lab
      user: devops-lab-viewer
      namespace: apps
current-context: devops-lab-viewer
users:
  - name: devops-lab-viewer
    user:
      token: ${TOKEN}
EOF

success "Kubeconfig written: ${KUBECONFIG_FILE}"

# ── Print Bifrost config snippet ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Bifrost Configuration${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo ""
cat << EOF
# bifrost.yaml (or your Bifrost config section)
kubernetes:
  clusters:
    - name: devops-lab
      api_server: ${API_SERVER}
      token: ${TOKEN}
      # Or use kubeconfig:
      # kubeconfig: ./devops-lab-viewer.kubeconfig
  default_namespace: apps
  allowed_namespaces:
    - apps
    - apps-staging
    - monitoring
    - kyverno
    - argocd
EOF

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  MCP Server (kubernetes-mcp) Configuration${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo ""
cat << EOF
# Claude Desktop / MCP client config (claude_desktop_config.json)
{
  "mcpServers": {
    "kubernetes-devops-lab": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-kubernetes"],
      "env": {
        "KUBECONFIG": "$(pwd)/${KUBECONFIG_FILE}"
      }
    }
  }
}

# OR if using the kubernetes-local MCP server already installed:
# Set context: kubectl config use-context kind-${CLUSTER_NAME}
# The MCP server will use the active kubeconfig context automatically.
EOF

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Verify Access${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
echo ""
echo "Test the viewer kubeconfig:"
echo "  KUBECONFIG=${KUBECONFIG_FILE} kubectl get pods -n apps"
echo "  KUBECONFIG=${KUBECONFIG_FILE} kubectl get applications -n argocd"
echo "  KUBECONFIG=${KUBECONFIG_FILE} kubectl get clusterpolicies"
echo ""
echo -e "${YELLOW}Note:${NC} The viewer SA has read-only access. Write operations will be denied."
