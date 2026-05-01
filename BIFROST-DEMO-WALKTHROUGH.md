# Bifrost AI Gateway — Demo Walkthrough

> **Cluster:** `kind-devops-lab`  
> **Bifrost endpoint:** `http://localhost:8080`  
> **MCP SSE server:** `http://localhost:8811/sse`  
> **Based on:** [simonjday/bifrost-k8s-demo](https://github.com/simonjday/bifrost-k8s-demo) — adapted for kind-devops-lab

---

## Bifrost Setup

**This walkthrough does not duplicate Bifrost installation.** Bifrost setup — including Helm install, MCP SSE server, Ollama, and provider registration — is fully documented and scripted in:

```
https://github.com/simonjday/bifrost-k8s-demo
```

Run the setup from that repo first, then come back here to run the demos against `kind-devops-lab`.

### What the bifrost-k8s-demo repo handles

| Script | What it does |
|--------|-------------|
| `scripts/install.sh` | Installs Bifrost via Helm into the `ai-gateway` namespace, registers Anthropic provider, creates MCP service and endpoints, creates a read-only virtual key |
| `scripts/start-mcp-server.sh` | Starts `kubernetes-mcp-server` in SSE mode on `0.0.0.0:8811` |
| `scripts/warmup-ollama.sh` | Pre-warms Ollama models before demo (optional) |

### Adapter — point MCP server at kind-devops-lab instead of k3d-demo

The bifrost-k8s-demo MCP server picks up whichever context is active in your kubeconfig. Before starting the MCP server, switch to the devops-lab cluster:

```bash
kubectl config use-context kind-devops-lab
kubectl config current-context   # confirm: kind-devops-lab

# Then start the MCP server as documented in bifrost-k8s-demo:
./scripts/start-mcp-server.sh
```

The MCP server will now serve tools for `kind-devops-lab`. Everything else (Bifrost install, virtual key, provider config) stays exactly as documented in the other repo.

> **Note on Bifrost namespace:** Bifrost itself runs in `ai-gateway` on your cluster (whichever cluster it was installed to). The MCP server runs on your Mac and connects to whatever Kubernetes context is active. You can run Bifrost on `k3d-demo` and point the MCP server at `kind-devops-lab` simultaneously — they are independent.

---

## Pre-Demo Setup

### 1 — Infrastructure check

```bash
# Bifrost health
curl -s http://localhost:8080/health | jq .
# Expected: {"status":"ok"}

# MCP SSE server reachable
curl -s --max-time 2 http://localhost:8811/sse | head -2
# Expected: event: endpoint

# MCP client connected in Bifrost
curl -s http://localhost:8080/api/mcp/clients \
  | jq '{name: .clients[0].config.name, state: .clients[0].state, tools: (.clients[0].tools | length)}'
# Expected: name=kubernetes_local, state=connected, tools=19

# At least one provider registered
curl -s http://localhost:8080/api/providers | jq '[.providers[].name]'
# Expected: ["anthropic"] at minimum
```

### 2 — Export your virtual key

```bash
export BIFROST_VIRTUAL_KEY="vk_your_key_here"
echo $BIFROST_VIRTUAL_KEY   # must not be empty
```

Get the key value from **Bifrost UI → http://localhost:8080 → Keys**.

### 3 — Confirm demo namespace and pods

The `bifrost-demo` namespace has a mix of healthy and unhealthy workloads specifically for this demo.

```bash
kubectl get pods -n bifrost-demo
```

Expected:
- `good-app-*` — Running (2 replicas, pinned image, probes, non-root)
- `bad-app-*` — CrashLoopBackOff (exits immediately — intentionally broken)

If `bad-app` pods are not crashlooping yet, wait ~60 seconds and check again.

### 4 — Confirm apps namespace is healthy

```bash
kubectl get pods -n apps
kubectl get applications -n argocd
```

Expected: all 8 pods Running, all 5 ArgoCD apps Synced/Healthy.

### 5 — Key API facts (reference throughout)

| Item | Value |
|------|-------|
| MCP JSON-RPC endpoint | `POST http://localhost:8080/mcp` |
| LLM completions endpoint | `POST http://localhost:8080/v1/chat/completions` |
| Auth header | `X-Api-Key: $BIFROST_VIRTUAL_KEY` |
| MCP client filter | `x-bf-mcp-include-clients: kubernetes_local` |
| Tool name format | `kubernetes_local-<toolname>` |
| Anthropic model | `anthropic/claude-sonnet-4-6` |
| Ollama model prefix | `openai/<modelname>` |

---

## Suggested Demo Order

| # | Demo | Duration | Why first |
|---|------|----------|-----------|
| 1 | Governance Block | 2 min | Opens with security — sets the tone |
| 2 | Cluster Health Triage | 3 min | Single LLM call, multiple tools — shows the value prop immediately |
| 3 | CrashLoopBackOff Diagnosis | 4 min | Real operational workflow step by step |
| 4 | ArgoCD Status via CRDs | 3 min | Proves it works beyond core Kubernetes |
| 5 | Namespace Cost Attribution | 3 min | Observability + full audit trail |
| 6 | LLM Multi-Step Agent | 5 min | Closes with the full agentic picture |

---

## Demo 1 — Governance Boundary (Destructive Tools Blocked)

**Narrative:** A developer has a read-only virtual key. They try three destructive operations. All are blocked at Bifrost — the MCP server is never contacted.

**Show:** Bifrost **UI → Keys** — point out the allowed-tool list on the virtual key before running the curls.

### Attempt 1 — delete a pod

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-pods_delete",
      "arguments": {"name": "podinfo-859d457dfd-74gnm", "namespace": "apps"}
    }
  }' | jq '{attempt: "pods_delete", result: .error.message}'
```

Expected: `tool not found` or similar blocked response.

### Attempt 2 — scale a deployment to zero

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-resources_scale",
      "arguments": {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "name": "podinfo",
        "namespace": "apps",
        "scale": 0
      }
    }
  }' | jq '{attempt: "resources_scale", result: .error.message}'
```

### Attempt 3 — exec into a pod

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-pods_exec",
      "arguments": {
        "name": "podinfo-859d457dfd-74gnm",
        "namespace": "apps",
        "command": ["cat", "/etc/passwd"]
      }
    }
  }' | jq '{attempt: "pods_exec", result: .error.message}'
```

**After running:** Open **Bifrost UI → Logs** — show all three blocked attempts recorded with the virtual key, timestamp, and tool name. The MCP server received zero of these requests.

---

## Demo 2 — Cluster Health Triage (LLM-Driven)

**Narrative:** On-call engineer asks the AI to triage the cluster. Bifrost injects all registered read-only k8s tools into the completion. The LLM decides which tools to call, executes them via Bifrost, and synthesises a structured report — all in one request.

```bash
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -H "x-bf-mcp-include-clients: kubernetes_local" \
  -d '{
    "model": "anthropic/claude-sonnet-4-6",
    "messages": [{
      "role": "user",
      "content": "Triage the kind-devops-lab cluster. Check for any pods not in Running state, warning events, and node resource pressure. Give me a structured summary with severity ratings."
    }]
  }' | jq -r '.choices[0].message.content'
```

**Talking points:**
- The LLM autonomously called `pods_list`, `events_list`, and `nodes_top` — you didn't specify which tools to use
- Bifrost enforced the allow-list throughout — `pods_delete` was never available even if the model tried
- `bad-app` in `bifrost-demo` should appear in the triage as CrashLoopBackOff

After getting the response, open **Bifrost UI → Logs** and show the tool calls that fired behind the scenes.

---

## Demo 3 — CrashLoopBackOff Diagnosis (Step by Step)

**Narrative:** A pod is crashing. Walk through the diagnosis workflow manually — pod list, pod state, logs, events — all through Bifrost, no kubectl needed by the consumer.

### Step 1 — List pods to get the actual pod name

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-pods_list_in_namespace",
      "arguments": {"namespace": "bifrost-demo"}
    }
  }' | jq -r '.result.content[0].text'
```

Note the actual `bad-app-*` pod name from the output — the replicaset hash suffix changes on every redeploy. Use that name in steps 2 and 3.

### Step 2 — Get pod detail

```bash
# Replace <bad-app-pod-name> with the actual name from step 1
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-pods_get",
      "arguments": {
        "name": "<bad-app-pod-name>",
        "namespace": "bifrost-demo"
      }
    }
  }' | jq -r '.result.content[0].text'
```

Point out: `containerStatuses[].restartCount`, `lastState.terminated.exitCode`, `state.waiting.reason: CrashLoopBackOff`.

### Step 3 — Get pod logs

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-pods_log",
      "arguments": {
        "name": "<bad-app-pod-name>",
        "namespace": "bifrost-demo",
        "tail": 20
      }
    }
  }' | jq -r '.result.content[0].text'
```

Shows `"starting"` then exits — the container deliberately exits with code 1.

### Step 4 — Namespace events (shows restart history)

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-events_list",
      "arguments": {"namespace": "bifrost-demo"}
    }
  }' | jq -r '.result.content[0].text'
```

Shows backoff events, restart counts, and the exact failure reason — same information as `kubectl describe pod` but through Bifrost with full audit logging.

**Talking point:** Every one of these four calls appears in **Bifrost UI → Logs** with tool name, virtual key, latency, and response size. Zero kubectl on the operator's terminal.

---

## Demo 4 — ArgoCD Application Status via CRDs

**Narrative:** Query ArgoCD Application resources through Bifrost. No `argocd` CLI, no cluster credentials handed to the consumer — just one governed endpoint.

### List all ArgoCD applications

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-resources_list",
      "arguments": {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Application",
        "namespace": "argocd"
      }
    }
  }' | jq -r '.result.content[0].text'
```

Expected: all 5 applications — guestbook, podinfo, load-generator, kyverno-policies, prometheus-rules — with sync and health status.

### Get a specific application

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-resources_get",
      "arguments": {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Application",
        "name": "podinfo",
        "namespace": "argocd"
      }
    }
  }' | jq -r '.result.content[0].text'
```

Point out: `status.sync.status`, `status.health.status`, `status.history` (last deploy revision and timestamp), and `spec.source.repoURL` — the full GitOps state in one response.

**Talking point:** The same `resources_list` and `resources_get` pattern works for any CRD — Kyverno ClusterPolicies, Prometheus PrometheusRules, or any custom resource. Bifrost doesn't need to know about the CRD — it proxies the tool call transparently.

---

## Demo 5 — Namespace Cost Attribution

**Narrative:** Platform team querying resource consumption across all namespaces for chargeback reporting. Full audit trail of who queried what.

### Step 1 — List namespaces

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-namespaces_list",
      "arguments": {}
    }
  }' | jq -r '.result.content[0].text'
```

### Step 2 — Resource consumption across all namespaces

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-pods_top",
      "arguments": {"all_namespaces": true}
    }
  }' | jq -r '.result.content[0].text'
```

### Step 3 — Nodes resource summary

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-nodes_top",
      "arguments": {}
    }
  }' | jq -r '.result.content[0].text'
```

**After running:** Open **Bifrost UI → Logs** — filter by the virtual key. Show all three queries with timestamps, latency, and tool name. This is the audit trail for every resource query — useful for cost attribution and compliance reporting.

---

## Demo 6 — LLM Multi-Step Agent Diagnosis

**Narrative:** Ask the LLM to investigate the `bifrost-demo` namespace which has a mix of healthy (`good-app`) and unhealthy (`bad-app`) workloads. The LLM calls multiple tools autonomously and returns a full structured diagnosis — the entire agentic loop runs inside Bifrost with zero client roundtrips.

### One-time setup — enable agent mode on the MCP client

This needs to be done once. Get your MCP client ID first:

```bash
MCP_CLIENT_ID=$(curl -s http://localhost:8080/api/mcp/clients \
  | jq -r '.clients[0].id')
echo $MCP_CLIENT_ID
```

Enable `tools_to_auto_execute`:

```bash
curl -s -X PUT "http://localhost:8080/api/mcp/client/$MCP_CLIENT_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "kubernetes_local",
    "connection_type": "sse",
    "connection_string": "http://localhost:8811/sse",
    "auth_type": "none",
    "tools_to_execute": ["*"],
    "tools_to_auto_execute": ["*"],
    "is_ping_available": true
  }' | jq .

# Verify it took
curl -s http://localhost:8080/api/mcp/clients \
  | jq '.clients[0].config | {tools_to_execute, tools_to_auto_execute}'
```

Expected: both fields set to `["*"]`.

> **Note:** `tools_to_auto_execute` is set on the MCP client config — there is no `x-bf-agent-mode` request header. This is a common gotcha from the bifrost-k8s-demo.

### Run the multi-step diagnosis

```bash
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -H "x-bf-mcp-include-clients: kubernetes_local" \
  -d '{
    "model": "anthropic/claude-sonnet-4-6",
    "messages": [{
      "role": "user",
      "content": "Investigate the bifrost-demo namespace. I have a mix of healthy and unhealthy workloads in there. List the pods, check for warning events, and tell me which apps are healthy, which are not, and what the likely cause is. Give me a structured report."
    }]
  }' | jq -r '.choices[0].message.content'
```

**What Bifrost does internally:**
1. Sends completion to Anthropic — Claude returns `tool_calls` for `pods_list_in_namespace` and `events_list`
2. Bifrost executes both tools against the MCP server automatically (no client roundtrip)
3. Feeds tool results back to Claude for synthesis
4. Returns the final `stop` response with the full diagnosis

**Expected output highlights:**
- `good-app` — ✅ Running, pinned image tag, liveness/readiness probes, non-root security context
- `bad-app` — ❌ CrashLoopBackOff, exits with code 1, `busybox:latest` (no pinned tag), no probes

**Key talking point:** Check `finish_reason` in the raw response:

```bash
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -H "x-bf-mcp-include-clients: kubernetes_local" \
  -d '{
    "model": "anthropic/claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "List pods in bifrost-demo namespace and summarise their health."}]
  }' | jq '{finish_reason: .choices[0].finish_reason, content_preview: .choices[0].message.content[:200]}'
```

`finish_reason: "stop"` means the full agentic loop completed inside Bifrost. Not `tool_calls` (which would mean the client needs to handle tool execution) — `stop` means Bifrost did it all.

Open **Bifrost UI → Logs** — show the full tool call chain with each step, latency, and result size.

---

## Kyverno Policies via Bifrost

**Bonus demo — show Kyverno ClusterPolicies as CRDs through the same endpoint.**

```bash
# List all Kyverno policies
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "kubernetes_local-resources_list",
      "arguments": {
        "apiVersion": "kyverno.io/v1",
        "kind": "ClusterPolicy"
      }
    }
  }' | jq -r '.result.content[0].text'
```

```bash
# Ask the LLM to assess the security posture
curl -s -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $BIFROST_VIRTUAL_KEY" \
  -H "x-bf-mcp-include-clients: kubernetes_local" \
  -d '{
    "model": "anthropic/claude-sonnet-4-6",
    "messages": [{
      "role": "user",
      "content": "List all Kyverno ClusterPolicies in the cluster. For each one, tell me what it enforces, whether it is in Audit or Enforce mode, and give me an overall security posture rating."
    }]
  }' | jq -r '.choices[0].message.content'
```

---

## Quick Reference — All Available Tools

```
kubernetes_local-configuration_view
kubernetes_local-namespaces_list
kubernetes_local-events_list
kubernetes_local-nodes_top
kubernetes_local-nodes_stats_summary
kubernetes_local-pods_get
kubernetes_local-pods_list
kubernetes_local-pods_list_in_namespace
kubernetes_local-pods_log
kubernetes_local-pods_top
kubernetes_local-resources_get
kubernetes_local-resources_list
```

---

## Gotchas (from bifrost-k8s-demo)

| Issue | Cause | Fix |
|-------|-------|-----|
| `tool not found` on valid tool | Tool not in virtual key allow-list | Add tool to allowed list in Bifrost UI → Keys |
| Agent mode not working | `x-bf-agent-mode` header doesn't exist | Set `tools_to_auto_execute: ["*"]` on MCP client via PUT API |
| `x-bifrost-key` header not working | Wrong header name for MCP endpoint | Use `X-Api-Key` for both MCP and completions endpoints |
| `mcp_servers` field in body ignored | Field doesn't exist | Use `x-bf-mcp-include-clients` header instead |
| Pod name not found | Pod names include replicaset hash suffix | Always use `pods_list_in_namespace` first to get current name |
| Empty Ollama response from pod | Ollama bound to localhost only | `OLLAMA_HOST=0.0.0.0 ollama serve` |
| Ollama 404 from Bifrost | Wrong provider type or `/v1` in base URL | Use `openai` type, base URL = `http://<LAN-IP>:11434` (no `/v1`) |

---

## Cleanup

```bash
# Remove bifrost-demo namespace and all its resources
kubectl delete namespace bifrost-demo
```
