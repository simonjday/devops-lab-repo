#!/usr/bin/env bash
# =============================================================================
# port-forwards.sh — open all devops-lab service UIs in one command
# Works with any kind cluster regardless of extraPortMappings config
#
# Usage:
#   ./scripts/port-forwards.sh           # start all (platform + apps + ai + kubecost)
#   ./scripts/port-forwards.sh platform  # platform UIs only (ArgoCD/Grafana/Prometheus)
#   ./scripts/port-forwards.sh apps      # app UIs only (guestbook/podinfo)
#   ./scripts/port-forwards.sh ai        # AI gateway only (Bifrost + Open WebUI)
#   ./scripts/port-forwards.sh kubecost  # Kubecost UI only
#   ./scripts/port-forwards.sh stop      # stop all
#   ./scripts/port-forwards.sh status    # show what's running
# =============================================================================

PIDFILE="/tmp/devops-lab-pf.pids"
LOGFILE="/tmp/devops-lab-pf.log"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

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

AI_FORWARDS=(
  "Bifrost|svc/bifrost|ai-gateway|8080|8080"
)

KUBECOST_FORWARDS=(
  "Kubecost|svc/kubecost-cost-analyzer|kubecost|9099|9090"
)

start_one() {
  local name="$1" resource="$2" ns="$3" local_port="$4" remote_port="$5"
  kubectl port-forward "${resource}" -n "${ns}" \
    "${local_port}:${remote_port}" >> "${LOGFILE}" 2>&1 &
  echo $! >> "${PIDFILE}"
  echo -e "  ${GREEN}✔${NC} ${name} → http://localhost:${local_port}"
}

start_open_webui() {
  # Already running — nothing to do
  if docker ps --filter "name=open-webui" --filter "status=running" \
      --format "{{.Names}}" 2>/dev/null | grep -q "open-webui"; then
    echo -e "  ${GREEN}✔${NC} Open WebUI → http://localhost:3001 (already running)"
    return
  fi

  # Container exists but is stopped — restart it
  if docker ps -a --filter "name=open-webui" --format "{{.Names}}" \
      2>/dev/null | grep -q "open-webui"; then
    docker start open-webui >> "${LOGFILE}" 2>&1
    echo -e "  ${GREEN}✔${NC} Open WebUI → http://localhost:3001 (restarted)"
    return
  fi

  # Container does not exist — create and start it
  if [ -z "${BIFROST_VIRTUAL_KEY}" ]; then
    echo -e "  ${YELLOW}!${NC} BIFROST_VIRTUAL_KEY is not set — Open WebUI will start without a key"
    echo -e "      Set it with: export BIFROST_VIRTUAL_KEY=\"sk-bf-your-key-here\""
  fi
  docker run -d \
    --name open-webui \
    -p 3001:8080 \
    -e OPENAI_API_BASE_URL=http://host.docker.internal:8080/v1 \
    -e OPENAI_API_KEY="${BIFROST_VIRTUAL_KEY:-changeme}" \
    -v open-webui:/app/backend/data \
    --restart always \
    ghcr.io/open-webui/open-webui:main >> "${LOGFILE}" 2>&1
  echo -e "  ${GREEN}✔${NC} Open WebUI → http://localhost:3001 (created and started)"
  echo -e "      ${YELLOW}Note:${NC} First startup takes ~30s while the image pulls"
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

  if [[ "${mode}" == "all" || "${mode}" == "ai" ]]; then
    echo -e "\n${BOLD}${CYAN}── AI Gateway ────────────────────────────${NC}"
    for entry in "${AI_FORWARDS[@]}"; do
      IFS='|' read -r name resource ns local_port remote_port <<< "${entry}"
      start_one "${name}" "${resource}" "${ns}" "${local_port}" "${remote_port}"
    done
    start_open_webui
  fi

  if [[ "${mode}" == "all" || "${mode}" == "kubecost" ]]; then
    echo -e "\n${BOLD}${CYAN}── Kubecost ──────────────────────────────${NC}"
    # Check kubecost namespace exists before attempting forward
    if kubectl get namespace kubecost &>/dev/null; then
      for entry in "${KUBECOST_FORWARDS[@]}"; do
        IFS='|' read -r name resource ns local_port remote_port <<< "${entry}"
        start_one "${name}" "${resource}" "${ns}" "${local_port}" "${remote_port}"
      done
    else
      echo -e "  ${YELLOW}!${NC} Kubecost not installed — skipping (run: helm install kubecost ...)"
    fi
  fi

  # Get ArgoCD password
  PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")

  echo -e "\n${BOLD}Access URLs:${NC}"
  if [[ "${mode}" == "all" || "${mode}" == "platform" ]]; then
    echo -e "  ${BLUE}ArgoCD${NC}       http://localhost:9080   (admin / ${PW})"
    echo -e "  ${BLUE}Grafana${NC}      http://localhost:3000   (admin / admin)"
    echo -e "  ${BLUE}Prometheus${NC}   http://localhost:9090"
    echo -e "  ${BLUE}Alertmanager${NC} http://localhost:9093"
  fi
  if [[ "${mode}" == "all" || "${mode}" == "apps" ]]; then
    echo -e "  ${BLUE}Guestbook${NC}    http://localhost:8888"
    echo -e "  ${BLUE}Podinfo${NC}      http://localhost:9898"
  fi
  if [[ "${mode}" == "all" || "${mode}" == "ai" ]]; then
    echo -e "  ${BLUE}Bifrost UI${NC}   http://localhost:8080"
    echo -e "  ${BLUE}Open WebUI${NC}   http://localhost:3001"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} Set BIFROST_VIRTUAL_KEY before using Bifrost:"
    echo -e "        export BIFROST_VIRTUAL_KEY=\"sk-bf-your-key-here\""
    echo -e "        Get your key from http://localhost:8080 → Keys"
  fi
  if [[ "${mode}" == "all" || "${mode}" == "kubecost" ]]; then
    echo -e "  ${BLUE}Kubecost${NC}     http://localhost:9099"
  fi
  echo ""
  echo -e "${YELLOW}Stop all:${NC} ./scripts/port-forwards.sh stop"
  echo "Logs: ${LOGFILE}"
}

stop_forwards() {
  # Kill tracked PIDs from pidfile
  if [ -f "${PIDFILE}" ]; then
    while IFS= read -r pid; do
      kill "${pid}" 2>/dev/null && echo -e "  ${GREEN}✔${NC} Stopped PID ${pid}" || true
    done < "${PIDFILE}"
    rm -f "${PIDFILE}"
  fi

  # Kill any remaining kubectl port-forward processes not tracked by pidfile
  # (covers manual port-forwards or orphaned processes from previous sessions)
  local orphans
  orphans=$(pgrep -f "kubectl port-forward" 2>/dev/null || true)
  if [ -n "${orphans}" ]; then
    echo -e "  ${YELLOW}!${NC} Found orphaned kubectl port-forward processes — stopping them"
    pkill -f "kubectl port-forward" 2>/dev/null || true
    sleep 1
    pkill -9 -f "kubectl port-forward" 2>/dev/null || true
  fi

  # Belt-and-braces: kill any kubectl process holding our known ports directly
  # This catches port-forwards started in other terminal sessions
  for port in 8080 9080 3000 9090 9093 8888 9898 9099; do
    pids_on_port=$(lsof -ti tcp:${port} 2>/dev/null || true)
    if [ -n "${pids_on_port}" ]; then
      while IFS= read -r pid_on_port; do
        proc_name=$(ps -p "${pid_on_port}" -o comm= 2>/dev/null || true)
        if echo "${proc_name}" | grep -q kubectl; then
          kill -9 "${pid_on_port}" 2>/dev/null || true
          echo -e "  ${GREEN}✔${NC} Killed kubectl PID ${pid_on_port} on port ${port}"
        fi
      done <<< "${pids_on_port}"
    fi
  done
  echo -e "  ${GREEN}✔${NC} All port-forwards stopped"

  # Stop Open WebUI container if running
  if docker ps --filter "name=open-webui" --filter "status=running" \
      --format "{{.Names}}" 2>/dev/null | grep -q "open-webui"; then
    docker stop open-webui >> "${LOGFILE}" 2>&1
    echo -e "  ${GREEN}✔${NC} Open WebUI stopped"
  fi
}

status_forwards() {
  echo -e "\n${BOLD}${CYAN}── kubectl port-forward processes ────────${NC}"
  local pf_procs
  pf_procs=$(pgrep -a -f "kubectl port-forward" 2>/dev/null || true)
  if [ -z "${pf_procs}" ]; then
    echo "  No kubectl port-forward processes running"
  else
    while IFS= read -r line; do
      echo -e "  ${GREEN}running${NC} ${line}"
    done <<< "${pf_procs}"
  fi

  echo -e "\n${BOLD}${CYAN}── Open WebUI ─────────────────────────────${NC}"
  if docker ps --filter "name=open-webui" --filter "status=running" \
      --format "{{.Names}}" 2>/dev/null | grep -q "open-webui"; then
    echo -e "  ${GREEN}running${NC} Open WebUI → http://localhost:3001"
  else
    echo -e "  stopped  Open WebUI"
  fi

  echo -e "\n${BOLD}${CYAN}── Kubecost ───────────────────────────────${NC}"
  if pgrep -f "port-forward.*kubecost" &>/dev/null || \
     pgrep -f "port-forward.*9099" &>/dev/null; then
    echo -e "  ${GREEN}running${NC} Kubecost → http://localhost:9099"
  else
    echo -e "  stopped  Kubecost"
  fi
  echo ""
}

case "${1:-all}" in
  all|platform|apps|ai|kubecost) start_forwards "${1:-all}" ;;
  stop)                           stop_forwards ;;
  status)                         status_forwards ;;
  *)                              echo "Usage: $0 [all|platform|apps|ai|kubecost|stop|status]" ;;
esac
