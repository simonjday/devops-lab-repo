#!/usr/bin/env bash
# =============================================================================
# port-forwards.sh — open all devops-lab service UIs in one command
# Works with any kind cluster regardless of extraPortMappings config
#
# Usage:
#   ./scripts/port-forwards.sh           # start all (platform + apps)
#   ./scripts/port-forwards.sh platform  # platform UIs only (ArgoCD/Grafana/Prometheus)
#   ./scripts/port-forwards.sh apps      # app UIs only (guestbook/podinfo)
#   ./scripts/port-forwards.sh stop      # stop all
#   ./scripts/port-forwards.sh status    # show what's running
# =============================================================================

PIDFILE="/tmp/devops-lab-pf.pids"
LOGFILE="/tmp/devops-lab-pf.log"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# Format: "DisplayName|resource|namespace|local_port|remote_port"
PLATFORM_FORWARDS=(
  "ArgoCD|svc/argocd-server|argocd|9080|80"
  "Grafana|svc/kube-prometheus-stack-grafana|monitoring|3000|80"
  "Prometheus|svc/kube-prometheus-stack-prometheus|monitoring|9090|9090"
  "Alertmanager|svc/kube-prometheus-stack-alertmanager|monitoring|9093|9093"
)

APP_FORWARDS=(
  "Guestbook|svc/guestbook|apps|8888|80"
  "Podinfo|svc/podinfo|apps|9898|9898"
)

start_one() {
  local name="$1" resource="$2" ns="$3" local_port="$4" remote_port="$5"
  kubectl port-forward "${resource}" -n "${ns}" \
    "${local_port}:${remote_port}" >> "${LOGFILE}" 2>&1 &
  echo $! >> "${PIDFILE}"
  echo -e "  ${GREEN}✔${NC} ${name} → http://localhost:${local_port}"
}

start_forwards() {
  local mode="${1:-all}"
  : > "${LOGFILE}"
  : > "${PIDFILE}"

  if [[ "${mode}" == "all" || "${mode}" == "platform" ]]; then
    echo -e "\n${BOLD}${CYAN}── Platform UIs ──────────────────────────${NC}"
    for entry in "${PLATFORM_FORWARDS[@]}"; do
      IFS='|' read -r name resource ns local_port remote_port <<< "${entry}"
      start_one "${name}" "${resource}" "${ns}" "${local_port}" "${remote_port}"
    done
  fi

  if [[ "${mode}" == "all" || "${mode}" == "apps" ]]; then
    echo -e "\n${BOLD}${CYAN}── Sample Apps ───────────────────────────${NC}"
    for entry in "${APP_FORWARDS[@]}"; do
      IFS='|' read -r name resource ns local_port remote_port <<< "${entry}"
      start_one "${name}" "${resource}" "${ns}" "${local_port}" "${remote_port}"
    done
  fi

  # Get ArgoCD password
  PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")

  echo -e "\n${BOLD}Access URLs:${NC}"
  echo -e "  ${BLUE}ArgoCD${NC}       http://localhost:9080   (admin / ${PW})"
  echo -e "  ${BLUE}Grafana${NC}      http://localhost:3000   (admin / admin)"
  echo -e "  ${BLUE}Prometheus${NC}   http://localhost:9090"
  echo -e "  ${BLUE}Alertmanager${NC} http://localhost:9093"
  echo -e "  ${BLUE}Guestbook${NC}    http://localhost:8888"
  echo -e "  ${BLUE}Podinfo${NC}      http://localhost:9898"
  echo ""
  echo -e "${YELLOW}Stop all:${NC} ./scripts/port-forwards.sh stop"
  echo "Logs: ${LOGFILE}"
}

stop_forwards() {
  if [ ! -f "${PIDFILE}" ]; then
    echo "No port-forwards running (no pidfile found)"
    return
  fi
  while IFS= read -r pid; do
    kill "${pid}" 2>/dev/null && echo "  Stopped PID ${pid}" || true
  done < "${PIDFILE}"
  rm -f "${PIDFILE}"
  echo "All port-forwards stopped"
}

status_forwards() {
  if [ ! -f "${PIDFILE}" ]; then
    echo "No port-forwards running"
    return
  fi
  local running=0 dead=0
  while IFS= read -r pid; do
    if kill -0 "${pid}" 2>/dev/null; then
      echo -e "  ${GREEN}running${NC} PID ${pid}"
      ((running++)) || true
    else
      echo -e "  ${RED}dead${NC}    PID ${pid}"
      ((dead++)) || true
    fi
  done < "${PIDFILE}"
  echo ""
  echo "${running} running, ${dead} dead"
}

case "${1:-all}" in
  all|platform|apps) start_forwards "${1:-all}" ;;
  stop)              stop_forwards ;;
  status)            status_forwards ;;
  *)                 echo "Usage: $0 [all|platform|apps|stop|status]" ;;
esac
