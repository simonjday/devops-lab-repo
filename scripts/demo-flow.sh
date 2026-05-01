#!/usr/bin/env bash
# =============================================================================
# Demo Flow Script — walks through key scenarios for a live demo
# Each scenario can be run independently or in sequence
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

pause() { echo -e "\n${YELLOW}── Press ENTER to continue ──${NC}"; read -r; }
header() { echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"; \
           echo -e "${BOLD}${CYAN}║  $*${NC}"; \
           echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}\n"; }
log()  { echo -e "${BLUE}▶${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

SCENARIO="${1:-all}"

# ─── Scenario 1: ArgoCD GitOps Demo ──────────────────────────────────────────
demo_argocd() {
  header "SCENARIO 1: ArgoCD GitOps Sync"

  log "Current ArgoCD application states:"
  kubectl get applications -n argocd -o wide
  pause

  log "Simulating drift — scale podinfo to 0 replicas directly:"
  kubectl scale deployment podinfo -n apps --replicas=0
  echo "  (ArgoCD will detect and self-heal this in ~3 minutes)"
  pause

  log "Watching ArgoCD detect the drift ..."
  kubectl get applications podinfo -n argocd -w &
  WATCH_PID=$!
  sleep 30
  kill $WATCH_PID 2>/dev/null || true

  log "Force sync to restore immediately:"
  kubectl patch application podinfo -n argocd \
    --type merge -p '{"operation": {"initiatedBy": {"username": "demo"}, "sync": {"revision": "HEAD"}}}'

  log "Verify podinfo is back:"
  kubectl rollout status deployment/podinfo -n apps --timeout=120s
  ok "ArgoCD self-healed the drift"
}

# ─── Scenario 2: Kyverno Policy Demo ─────────────────────────────────────────
demo_kyverno() {
  header "SCENARIO 2: Kyverno Policy Enforcement"

  log "Current policies:"
  kubectl get clusterpolicies
  pause

  log "1/4 — Applying COMPLIANT pod (should pass all policies):"
  kubectl apply -f apps/policy-test-suite/compliant-pod.yaml
  ok "Compliant pod created"
  pause

  log "2/4 — Applying pod with MISSING RESOURCE LIMITS (audit violation):"
  kubectl apply -f apps/policy-test-suite/missing-limits.yaml
  warn "Pod created but policy violation recorded"
  pause

  log "3/4 — Attempting to create PRIVILEGED pod (will be BLOCKED):"
  kubectl apply -f apps/policy-test-suite/privileged-pod.yaml 2>&1 || \
    warn "Expected block: privileged-pod was rejected by Kyverno (Enforce mode)"
  pause

  log "4/4 — Viewing policy violation reports:"
  kubectl get policyreport -n policy-test -o wide
  echo ""
  kubectl describe policyreport -n policy-test | grep -A5 "Result.*fail" | head -40
  pause

  log "Cleaning up test pods:"
  kubectl delete pod compliant-pod missing-limits missing-labels root-user-pod \
    -n policy-test --ignore-not-found
  ok "Kyverno demo complete"
}

# ─── Scenario 3: Prometheus + Grafana ────────────────────────────────────────
demo_prometheus() {
  header "SCENARIO 3: Prometheus Metrics + Alerting"

  log "Starting port-forwards in background ..."
  kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring &
  PF1=$!
  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring &
  PF2=$!
  sleep 3

  log "Prometheus targets (should see podinfo + guestbook):"
  curl -s http://localhost:9090/api/v1/targets | \
    python3 -c "import sys,json; t=json.load(sys.stdin)['data']['activeTargets']; \
    [print(f\"  {x['labels'].get('job','?')} — {x['health']}\") for x in t]" 2>/dev/null || \
    echo "  (install python3 or open http://localhost:9090/targets in browser)"
  pause

  log "Custom PromQL — podinfo HTTP requests per second:"
  curl -sg "http://localhost:9090/api/v1/query?query=rate(http_requests_total%7Bjob%3D%22podinfo%22%7D%5B5m%5D)" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); \
    [print(f\"  {r['metric']} = {r['value'][1]}\") for r in d['data']['result']]" 2>/dev/null || \
    echo "  Open Grafana → http://localhost:3000 (admin/admin)"
  pause

  log "Active alerting rules:"
  kubectl get prometheusrule -n monitoring
  pause

  log "Trigger a CPU alert — running stress in a pod:"
  kubectl run stressor --image=busybox -n apps -- sh -c "while true; do :; done" \
    --overrides='{"spec":{"containers":[{"name":"stressor","resources":{"limits":{"cpu":"200m","memory":"64Mi"}}}]}}' \
    2>/dev/null || true
  warn "Stressor pod running — watch Prometheus alerts fire after ~10 minutes"
  warn "Cleanup: kubectl delete pod stressor -n apps"
  pause

  kill $PF1 $PF2 2>/dev/null || true
  ok "Prometheus demo complete"
}

# ─── Scenario 4: MCP / Bifrost Integration ───────────────────────────────────
demo_mcp() {
  header "SCENARIO 4: MCP + Bifrost Integration"

  log "Viewer service account token (for MCP/Bifrost):"
  TOKEN=$(kubectl get secret devops-lab-viewer-token -n apps \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "NOT_FOUND")

  if [ "${TOKEN}" = "NOT_FOUND" ]; then
    warn "Run: kubectl apply -f base/rbac/rbac.yaml   (then re-run this scenario)"
    return
  fi

  echo "  Token: ${TOKEN:0:40}..."
  echo ""
  log "Testing read-only access via viewer SA:"
  KUBECONFIG=./devops-lab-viewer.kubeconfig kubectl get pods -n apps 2>/dev/null || \
    warn "devops-lab-viewer.kubeconfig not found — run: ./scripts/bifrost-mcp-setup.sh"
  pause

  log "MCP server config (add to claude_desktop_config.json):"
  cat << 'EOF'
{
  "mcpServers": {
    "k8s-devops-lab": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-kubernetes"],
      "env": {
        "KUBECONFIG": "/path/to/devops-lab-viewer.kubeconfig"
      }
    }
  }
}
EOF
  ok "MCP config printed — restart Claude Desktop to load the MCP server"
}

# ─── Run ──────────────────────────────────────────────────────────────────────
case "${SCENARIO}" in
  argocd)     demo_argocd ;;
  kyverno)    demo_kyverno ;;
  prometheus) demo_prometheus ;;
  mcp)        demo_mcp ;;
  all)
    demo_argocd
    demo_kyverno
    demo_prometheus
    demo_mcp
    ;;
  *)
    echo "Usage: $0 [argocd|kyverno|prometheus|mcp|all]"
    exit 1
    ;;
esac

echo -e "\n${BOLD}${GREEN}Demo complete!${NC}"
