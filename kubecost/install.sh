#!/usr/bin/env bash
# =============================================================================
# Kubecost install for devops-lab kind cluster
# Default: v3.0.x (ClickHouse, 10-min granularity)
# Option:  --v2 for lightweight v2.8.x
#
# Usage:
#   ./kubecost/install.sh           # v3 (default)
#   ./kubecost/install.sh --v2      # v2.8.x lightweight
#   ./kubecost/install.sh --uninstall
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

VERSION="v3"
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --v2)        VERSION="v2";   shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    *) echo "Usage: $0 [--v2] [--uninstall]"; exit 1 ;;
  esac
done

command -v helm    &>/dev/null || { echo "helm not found"; exit 1; }
command -v kubectl &>/dev/null || { echo "kubectl not found"; exit 1; }

# ── Uninstall ──────────────────────────────────────────────────────────────────
if [ "${UNINSTALL}" = true ]; then
  log "Uninstalling Kubecost ..."
  helm uninstall kubecost -n kubecost 2>/dev/null || true
  kubectl delete namespace kubecost --ignore-not-found
  kubectl delete pvc --all -n kubecost 2>/dev/null || true
  success "Kubecost uninstalled"
  exit 0
fi

# ── Helm repos ─────────────────────────────────────────────────────────────────
helm repo add kubecost    https://kubecost.github.io/cost-analyzer/ 2>/dev/null || true
helm repo add kubecost-v3 https://kubecost.github.io/kubecost/      2>/dev/null || true
helm repo update

kubectl create namespace kubecost --dry-run=client -o yaml | kubectl apply -f -

# ── v3 install ─────────────────────────────────────────────────────────────────
if [ "${VERSION}" = "v3" ]; then
  log "Installing Kubecost v3 (ClickHouse, 10-min granularity) ..."
  echo ""
  echo "  Storage class: standard (local-path-provisioner)"
  echo "  networkCosts:  disabled (Kyverno blocks privileged DaemonSet)"
  echo "  Custom pricing applied automatically (kind nodes have no instance_type)"
  echo ""
  echo "  NOTE: ClickHouse re-ingests historical data on first install."
  echo "        Expect 20-30 minutes before cost data appears in the UI."
  echo ""

  # Clean up any existing install
  helm uninstall kubecost -n kubecost 2>/dev/null || true
  sleep 5

  helm upgrade --install kubecost kubecost-v3/kubecost \
    --namespace kubecost \
    --set global.clusterId=devops-lab \
    --set persistentVolume.storageClass=standard \
    --set networkCosts.enabled=false \
    --timeout 10m \
    --wait

  # Apply custom pricing immediately after install
  # Prevents blank UI caused by NaN values from missing instance_type labels
  log "Applying custom pricing (prevents blank UI on kind) ..."
  helm upgrade kubecost kubecost-v3/kubecost \
    --namespace kubecost \
    --reuse-values \
    --set kubecostProductConfigs.defaultIdle=true \
    --set kubecostProductConfigs.customPricesEnabled=true \
    --set kubecostProductConfigs.cpuCost=0.031611 \
    --set kubecostProductConfigs.memoryCost=0.004237 \
    --set kubecostProductConfigs.storageCost=0.00005479

# ── v2.8 install ───────────────────────────────────────────────────────────────
else
  log "Installing Kubecost v2.8.x (lightweight, no ClickHouse) ..."

  CHART_VERSION=$(helm search repo kubecost/cost-analyzer --versions \
    | awk '/[[:space:]]2\.8\./ {print $2; exit}')
  [ -z "${CHART_VERSION}" ] && CHART_VERSION="2.8.0"
  log "Chart version: ${CHART_VERSION}"

  helm upgrade --install kubecost kubecost/cost-analyzer \
    --namespace kubecost \
    --version "${CHART_VERSION}" \
    --set kubecostToken="" \
    --set global.clusterId=devops-lab \
    --set prometheus.server.persistentVolume.enabled=false \
    --set prometheus.alertmanager.persistentVolume.enabled=false \
    --set persistentVolume.enabled=false \
    --set networkCosts.enabled=false \
    --wait --timeout=5m
fi

# ── Status ─────────────────────────────────────────────────────────────────────
echo ""
success "Kubecost ${VERSION} installed"
echo ""
kubectl get pods -n kubecost
echo ""

# Detect correct service/port for the UI
UI_SVC=$(kubectl get svc -n kubecost \
  --field-selector=metadata.name=kubecost-cost-analyzer \
  -o name 2>/dev/null | head -1)
[ -z "${UI_SVC}" ] && UI_SVC="kubecost-frontend"

echo -e "${BOLD}Access UI:${NC}"
echo "  kubectl port-forward svc/kubecost-cost-analyzer 9002:9090 -n kubecost"
echo "  open http://localhost:9002"
echo ""
echo -e "${BOLD}Or use:${NC} ./scripts/port-forwards.sh kubecost"
echo ""

if [ "${VERSION}" = "v3" ]; then
  echo -e "${BOLD}Troubleshoot blank UI (NaN issue):${NC}"
  echo "  kubectl logs -n kubecost kubecost-aggregator-0 --tail=30 | grep -E 'NaN|ERR'"
  echo "  kubectl logs -n kubecost -l app=finopsagent --tail=20 | grep instance_type"
  echo ""
  echo -e "${BOLD}Check PVCs (ClickHouse storage):${NC}"
  echo "  kubectl get pvc -n kubecost"
fi
