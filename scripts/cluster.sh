#!/usr/bin/env bash
# =============================================================================
# DevOps Lab — Cluster Stop / Start
#
# Suspends the cluster when you don't need it (stops the Docker containers
# so they consume no CPU/RAM) and brings everything back up cleanly.
#
# Usage:
#   ./scripts/cluster.sh stop    # suspend — free up RAM/CPU
#   ./scripts/cluster.sh start   # resume  — restore everything
#   ./scripts/cluster.sh status  # show current state
#
# "stop" does NOT delete the cluster — all data and config is preserved.
# Use "kind delete cluster --name devops-lab" to fully tear down.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}═══ $* ═══${NC}"; }

CLUSTER_NAME="${CLUSTER_NAME:-devops-lab}"
ARGOCD_NS="argocd"

# ── Helpers ───────────────────────────────────────────────────────────────────

cluster_containers() {
  # Returns the Docker container IDs for all nodes in the cluster
  docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format "{{.ID}} {{.Names}} {{.Status}}"
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"
}

cluster_running() {
  # True if at least one cluster container is running (not paused/stopped)
  docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --filter "status=running" --format "{{.ID}}" | grep -q .
}

# ── Status ────────────────────────────────────────────────────────────────────

cmd_status() {
  header "Cluster status — ${CLUSTER_NAME}"
  if ! cluster_exists; then
    echo -e "  ${RED}Cluster does not exist.${NC} Run ./scripts/bootstrap-repo.sh to create it."
    exit 0
  fi

  echo ""
  echo "  Docker containers:"
  cluster_containers | while read -r id name status; do
    if echo "$status" | grep -qi "up"; then
      echo -e "    ${GREEN}●${NC}  $name  ($status)"
    else
      echo -e "    ${RED}●${NC}  $name  ($status)"
    fi
  done

  echo ""
  if cluster_running; then
    echo -e "  Cluster: ${GREEN}${BOLD}RUNNING${NC}"
    echo ""
    echo "  ArgoCD apps:"
    kubectl get applications -n "$ARGOCD_NS" \
      --no-headers \
      -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status" \
      2>/dev/null | while read -r name sync health; do
        sync_icon="✅"; health_icon="✅"
        [[ "$sync"   != "Synced"  ]] && sync_icon="⚠️ "
        [[ "$health" != "Healthy" ]] && health_icon="⚠️ "
        printf "    %-22s  sync: %s %-12s  health: %s %s\n" \
          "$name" "$sync_icon" "$sync" "$health_icon" "$health"
      done
  else
    echo -e "  Cluster: ${YELLOW}${BOLD}STOPPED${NC}  (containers exist but are not running)"
    echo "  Run: ./scripts/cluster.sh start"
  fi
  echo ""
}

# ── Stop ──────────────────────────────────────────────────────────────────────

cmd_stop() {
  header "Stopping cluster — ${CLUSTER_NAME}"

  cluster_exists || error "Cluster '${CLUSTER_NAME}' does not exist."

  if ! cluster_running; then
    success "Cluster is already stopped."
    return
  fi

  log "Stopping Docker containers (CPU/RAM will be freed) ..."
  docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format "{{.ID}}" | xargs -r docker stop

  echo ""
  success "Cluster stopped. All data preserved — nothing was deleted."
  echo -e "  Resume with: ${BOLD}./scripts/cluster.sh start${NC}"
  echo ""
}

# ── Start ─────────────────────────────────────────────────────────────────────

cmd_start() {
  header "Starting cluster — ${CLUSTER_NAME}"

  cluster_exists || error "Cluster '${CLUSTER_NAME}' does not exist. Run ./scripts/bootstrap-repo.sh first."

  if cluster_running; then
    success "Cluster is already running."
    cmd_status
    return
  fi

  log "Starting Docker containers ..."
  docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format "{{.ID}}" | xargs -r docker start

  log "Switching kubectl context to kind-${CLUSTER_NAME} ..."
  kubectl config use-context "kind-${CLUSTER_NAME}"

  log "Waiting for API server to be reachable ..."
  local retries=0
  until kubectl cluster-info &>/dev/null 2>&1; do
    retries=$((retries + 1))
    [[ $retries -gt 30 ]] && error "API server did not come up after 60s"
    sleep 2
  done
  success "API server is up"

  log "Waiting for core node to be Ready ..."
  kubectl wait node --all --for=condition=Ready --timeout=120s
  success "Node ready"

  log "Waiting for ArgoCD server to be Running ..."
  kubectl rollout status deployment/argocd-server -n "$ARGOCD_NS" --timeout=120s 2>/dev/null \
    || log "argocd-server not found — skipping (may still be starting)"

  log "Waiting for Kyverno to be Running ..."
  kubectl rollout status deployment/kyverno -n kyverno --timeout=120s 2>/dev/null \
    || log "Kyverno not found — skipping"

  # Give ArgoCD a moment to reconnect to the repo and reconcile
  log "Giving ArgoCD 10s to reconnect and reconcile ..."
  sleep 10

  echo ""
  success "Cluster is up!"
  echo ""

  ARGOCD_PASS=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "<check manually>")

  echo -e "  ${BOLD}ArgoCD${NC}       http://localhost:9080  (admin / ${ARGOCD_PASS})"
  echo -e "  ${BOLD}Grafana${NC}      http://localhost:3000  (admin / admin)"
  echo -e "  ${BOLD}Prometheus${NC}   http://localhost:9090"
  echo -e "  ${BOLD}Alertmanager${NC} http://localhost:9093"
  echo ""
  echo "  ArgoCD apps:"
  kubectl get applications -n "$ARGOCD_NS" \
    --no-headers \
    -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status" \
    2>/dev/null | while read -r name sync health; do
      sync_icon="✅"; health_icon="✅"
      [[ "$sync"   != "Synced"  ]] && sync_icon="⚠️ "
      [[ "$health" != "Healthy" ]] && health_icon="⚠️ "
      printf "    %-22s  sync: %s %-12s  health: %s %s\n" \
        "$name" "$sync_icon" "$sync" "$health_icon" "$health"
    done
  echo ""
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

CMD="${1:-status}"
case "$CMD" in
  stop)   cmd_stop   ;;
  start)  cmd_start  ;;
  status) cmd_status ;;
  *)
    echo "Usage: $0 {stop|start|status}"
    echo ""
    echo "  stop    — suspend cluster containers (frees CPU/RAM, data preserved)"
    echo "  start   — resume cluster and wait for readiness"
    echo "  status  — show running state and ArgoCD app health"
    exit 1
    ;;
esac
