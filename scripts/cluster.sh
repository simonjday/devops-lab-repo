#!/usr/bin/env bash
# =============================================================================
# DevOps Lab — Cluster Manager
#
# Suspends Docker containers when you don't need them (stops the containers
# so they consume no CPU/RAM) and brings everything back up cleanly.
#
# Usage:
#   ./scripts/cluster.sh stop    # suspend — free up RAM/CPU
#   ./scripts/cluster.sh start   # resume  — restore everything
#   ./scripts/cluster.sh status  # show current state
#
# Environment variables (optional):
#   MANAGE_KIND=true            # manage kind cluster (default: true)
#   MANAGE_K3D=false            # manage k3d-demo cluster (default: false)
#   MANAGE_OPENWEBUI=true       # manage open-webui container (default: true)
#
# Examples:
#   ./scripts/cluster.sh stop                      # stop kind + open-webui
#   MANAGE_K3D=true ./scripts/cluster.sh stop      # stop kind + k3d + open-webui
#   MANAGE_KIND=false MANAGE_K3D=true ./scripts/cluster.sh stop    # stop k3d only
#   MANAGE_OPENWEBUI=false ./scripts/cluster.sh start    # start kind only
#
# "stop" does NOT delete clusters — all data and config is preserved.
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
MANAGE_KIND="${MANAGE_KIND:-true}"
MANAGE_K3D="${MANAGE_K3D:-false}"
MANAGE_OPENWEBUI="${MANAGE_OPENWEBUI:-true}"

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

  if [[ "$MANAGE_KIND" == "false" && "$MANAGE_K3D" == "false" && "$MANAGE_OPENWEBUI" == "false" ]]; then
    error "Nothing to manage. Set MANAGE_KIND=true, MANAGE_K3D=true, or MANAGE_OPENWEBUI=true"
  fi

  if [[ "$MANAGE_KIND" == "true" ]]; then
    cluster_exists || error "Cluster '${CLUSTER_NAME}' does not exist."

    if ! cluster_running; then
      success "Kind cluster is already stopped."
    else
      log "Stopping Docker containers (CPU/RAM will be freed) ..."
      docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
        --format "{{.ID}}" | xargs -r docker stop --timeout=10

      log "Pausing containers to prevent auto-restart ..."
      docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
        --format "{{.ID}}" | xargs -r docker pause 2>/dev/null || true

      log "Removing restart policies (prevents auto-start) ..."
      docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
        --format "{{.ID}}" | while read -r id; do
          docker update --restart=no "$id" 2>/dev/null || true
        done
    fi
  fi

  if [[ "$MANAGE_K3D" == "true" ]]; then
    log "Stopping k3d cluster (k3d-demo) ..."
    docker ps --filter "name=k3d-demo" \
      --format "{{.ID}}" | xargs -r docker stop --timeout=10 2>/dev/null || true

    log "Pausing k3d containers ..."
    docker ps -a --filter "name=k3d-demo" \
      --format "{{.ID}}" | xargs -r docker pause 2>/dev/null || true

    log "Removing restart policies from k3d ..."
    docker ps -a --filter "name=k3d-demo" \
      --format "{{.ID}}" | while read -r id; do
        docker update --restart=no "$id" 2>/dev/null || true
      done
  fi

  log "Stopping standalone containers (open-webui only) ..."
  if [[ "$MANAGE_OPENWEBUI" == "true" ]]; then
    docker ps --format "{{.ID}}\t{{.Names}}" | grep "open-webui" | cut -f1 \
      | xargs -r docker kill 2>/dev/null || true
  fi
  
  log "Removing restart policies from standalone containers ..."
  if [[ "$MANAGE_OPENWEBUI" == "true" ]]; then
    docker ps -a --format "{{.ID}}\t{{.Names}}" | grep "open-webui" | cut -f1 \
      | while read -r id; do
        docker update --restart=no "$id" 2>/dev/null || true
      done
  fi
  
  log "Pausing standalone containers to lock them ..."
  if [[ "$MANAGE_OPENWEBUI" == "true" ]]; then
    docker ps -a --format "{{.ID}}\t{{.Names}}" | grep "open-webui" | cut -f1 \
      | xargs -r docker pause 2>/dev/null || true
  fi

  echo ""
  success "Cluster stopped and paused. All data preserved — nothing was deleted."
  echo -e "  Resume with: ${BOLD}./scripts/cluster.sh start${NC}"
  echo ""
}

# ── Start ─────────────────────────────────────────────────────────────────────

cmd_start() {
  header "Starting cluster"

  if [[ "$MANAGE_KIND" == "false" && "$MANAGE_K3D" == "false" && "$MANAGE_OPENWEBUI" == "false" ]]; then
    error "Nothing to manage. Set MANAGE_KIND=true, MANAGE_K3D=true, or MANAGE_OPENWEBUI=true"
  fi

  if [[ "$MANAGE_KIND" == "true" ]]; then
    cluster_exists || error "Cluster '${CLUSTER_NAME}' does not exist. Run ./scripts/bootstrap-repo.sh first."

    if cluster_running; then
      success "Kind cluster is already running."
    else
      log "Unpausing kind containers ..."
      docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
        --format "{{.ID}}" | xargs -r docker unpause 2>/dev/null || true

      log "Starting kind Docker containers ..."
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
      # Kyverno v3+ splits into multiple deployments — the admission controller is the primary one
      kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=120s 2>/dev/null \
        || log "Kyverno not found — skipping"

      # Give ArgoCD a moment to reconnect to the repo and reconcile
      log "Giving ArgoCD 10s to reconnect and reconcile ..."
      sleep 10
    fi
  fi

  if [[ "$MANAGE_K3D" == "true" ]]; then
    log "Unpausing k3d containers ..."
    docker ps -a --filter "name=k3d-demo" \
      --format "{{.ID}}" | xargs -r docker unpause 2>/dev/null || true

    log "Starting k3d cluster ..."
    docker ps -a --filter "name=k3d-demo" \
      --format "{{.ID}}" | xargs -r docker start 2>/dev/null || true
  fi

  if [[ "$MANAGE_OPENWEBUI" == "true" ]]; then
    log "Unpausing open-webui ..."
    docker ps -a --format "{{.ID}}\t{{.Names}}" | grep "open-webui" | cut -f1 \
      | xargs -r docker unpause 2>/dev/null || true

    log "Starting open-webui ..."
    docker ps -a --format "{{.ID}}\t{{.Names}}" | grep "open-webui" | cut -f1 \
      | xargs -r docker start 2>/dev/null || true
  fi

  echo ""
  success "Containers started!"
  echo ""

  if [[ "$MANAGE_KIND" == "true" ]]; then
    ARGOCD_PASS=$(kubectl -n "$ARGOCD_NS" get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "<check manually>")

    echo -e "  ${BOLD}Kind cluster — ${CLUSTER_NAME}${NC}"
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
  fi

  if [[ "$MANAGE_K3D" == "true" ]]; then
    echo -e "  ${BOLD}k3d cluster — demo${NC}"
    echo "  (run: k3d cluster list)"
    echo ""
  fi

  if [[ "$MANAGE_OPENWEBUI" == "true" ]]; then
    echo -e "  ${BOLD}Open WebUI${NC}   http://localhost:3001"
    echo ""
  fi
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
    echo "  status  — show running state and app health"
    echo ""
    echo "Environment variables (optional):"
    echo "  MANAGE_KIND=true            # manage kind cluster (default: true)"
    echo "  MANAGE_K3D=false            # manage k3d-demo cluster (default: false)"
    echo "  MANAGE_OPENWEBUI=true       # manage open-webui container (default: true)"
    echo ""
    echo "Examples:"
    echo "  ./scripts/cluster.sh stop"
    echo "  MANAGE_K3D=true ./scripts/cluster.sh stop"
    echo "  MANAGE_KIND=false MANAGE_K3D=true ./scripts/cluster.sh stop"
    echo "  MANAGE_OPENWEBUI=false ./scripts/cluster.sh start"
    exit 1
    ;;
esac
