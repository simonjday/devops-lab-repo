#!/usr/bin/env bash
# =============================================================================
# port-forwards.sh — open all devops-lab service UIs in one command
# Works with any kind cluster regardless of extraPortMappings config
# Usage: ./scripts/port-forwards.sh [start|stop|status]
# =============================================================================

PIDFILE="/tmp/devops-lab-pf.pids"
LOGFILE="/tmp/devops-lab-pf.log"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'

start_forwards() {
  echo "" > "${LOGFILE}"
  > "${PIDFILE}"

  declare -A FORWARDS=(
    ["ArgoCD"]="svc/argocd-server:argocd:9080:80"
    ["Grafana"]="svc/kube-prometheus-stack-grafana:monitoring:3000:80"
    ["Prometheus"]="svc/kube-prometheus-stack-prometheus:monitoring:9090:9090"
    ["Alertmanager"]="svc/kube-prometheus-stack-alertmanager:monitoring:9093:9093"
  )

  echo -e "${BOLD}Starting port-forwards...${NC}"
  for name in "${!FORWARDS[@]}"; do
    IFS=: read -r resource ns local_port remote_port <<< "${FORWARDS[$name]}"
    kubectl port-forward "${resource}" -n "${ns}" \
      "${local_port}:${remote_port}" >> "${LOGFILE}" 2>&1 &
    echo $! >> "${PIDFILE}"
    echo -e "  ${GREEN}✔${NC} ${name} → http://localhost:${local_port}"
  done

  echo ""
  echo -e "${BOLD}Access:${NC}"
  echo -e "  ${BLUE}ArgoCD${NC}       http://localhost:9080   (admin / see below)"
  echo -e "  ${BLUE}Grafana${NC}      http://localhost:3000   (admin / admin)"
  echo -e "  ${BLUE}Prometheus${NC}   http://localhost:9090"
  echo -e "  ${BLUE}Alertmanager${NC} http://localhost:9093"
  echo ""

  # Print ArgoCD password
  PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
  echo -e "  ${BOLD}ArgoCD password:${NC} ${PW}"
  echo ""
  echo -e "${YELLOW}Run './scripts/port-forwards.sh stop' to close all forwards${NC}"
  echo "Logs: ${LOGFILE}"
}

stop_forwards() {
  if [ ! -f "${PIDFILE}" ]; then
    echo "No port-forwards running (no pidfile found)"
    return
  fi
  while IFS= read -r pid; do
    kill "${pid}" 2>/dev/null && echo "Stopped PID ${pid}" || true
  done < "${PIDFILE}"
  rm -f "${PIDFILE}"
  echo "All port-forwards stopped"
}

status_forwards() {
  if [ ! -f "${PIDFILE}" ]; then
    echo "No port-forwards running"
    return
  fi
  echo "Active port-forward PIDs:"
  while IFS= read -r pid; do
    if kill -0 "${pid}" 2>/dev/null; then
      echo "  PID ${pid} — running"
    else
      echo "  PID ${pid} — dead"
    fi
  done < "${PIDFILE}"
}

case "${1:-start}" in
  start)  start_forwards ;;
  stop)   stop_forwards ;;
  status) status_forwards ;;
  *)      echo "Usage: $0 [start|stop|status]" ;;
esac
