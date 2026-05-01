# DevOps Lab — Demo Walkthrough

A step-by-step manual demo guide covering ArgoCD GitOps, Kyverno policy enforcement, Prometheus observability, and the sample applications. Run each command yourself — no scripts.

**Cluster:** `kind-devops-lab`  
**Repo:** `https://github.com/simonjday/devops-lab-repo`

---

## Pre-Demo Checklist

Open four browser tabs before starting:

| Tab | URL | Credentials |
|-----|-----|-------------|
| ArgoCD | http://localhost:9080 | admin / (see below) |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | — |
| Guestbook app | http://localhost:8888 | — |

```bash
# Get ArgoCD admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Start port-forwards for sample apps (platform UIs are already on localhost)
./scripts/port-forwards.sh apps
```

Confirm everything is healthy before starting:

```bash
kubectl get nodes
kubectl get applications -n argocd
kubectl get pods -n apps
kubectl get clusterpolicies
```

Expected: 2 nodes Ready, 5 ArgoCD apps Synced/Healthy, 8 pods Running in apps, 7 policies Ready.

---

## Scenario 1 — Cluster & Application Tour

**Narrative:** Start with a quick orient — show the cluster topology, what's running, and how it all connects.

### 1.1 Cluster topology

```bash
# Two nodes — control-plane and worker
kubectl get nodes -o wide
```

Point out: control-plane handles scheduling/API, all workloads land on the worker node (label: `workload=apps`).

```bash
# Show node labels
kubectl get nodes --show-labels
```

### 1.2 Namespaces

```bash
kubectl get namespaces
```

Walk through the purpose of each:

| Namespace | Purpose |
|-----------|---------|
| `argocd` | GitOps controller — watches GitHub, syncs everything |
| `monitoring` | Prometheus, Grafana, Alertmanager |
| `kyverno` | Policy engine — admission controller |
| `apps` | Sample workloads — guestbook, podinfo, load-generator |
| `policy-test` | Disposable namespace for Kyverno demos |

### 1.3 What's running in apps

```bash
kubectl get all -n apps
```

Show: 2× guestbook, 2× podinfo, 1× load-generator, 1× redis-leader, 2× redis-follower.

### 1.4 Kyverno mutation in action

```bash
# Every pod in 'apps' gets these labels injected automatically by Kyverno
kubectl get pod -n apps -l app=podinfo -o jsonpath='{.items[0].metadata.labels}' | python3 -m json.tool
```

Point out `managed-by: kyverno` and `cluster: devops-lab` — neither of these is in our YAML, Kyverno's mutation policy adds them on admission.

---

## Scenario 2 — ArgoCD GitOps

**Narrative:** Show that the cluster is driven entirely from Git. Demonstrate drift detection and self-healing.

### 2.1 View applications in ArgoCD UI

Open http://localhost:9080. Walk through each app tile:
- All show **Synced** (green tick) and **Healthy** (green heart)
- Click into `guestbook` — show the resource graph (Deployment → ReplicaSet → Pods → Service)
- Click **App Details** → **Parameters** → show the repo URL and path

### 2.2 Inspect the ApplicationSet (the engine behind all apps)

```bash
kubectl get applicationset devops-lab -n argocd -o yaml | grep -A 20 "generators:"
```

Show that one `ApplicationSet` with a list generator creates all 5 apps from a single definition.

### 2.3 Demonstrate GitOps drift detection

Simulate someone making a direct change to the cluster (bypassing Git):

```bash
# Scale podinfo to 0 — this is "drift" (not in Git)
kubectl scale deployment podinfo -n apps --replicas=0

# Watch the pods disappear
kubectl get pods -n apps -w
```

In ArgoCD UI: watch the `podinfo` app flip to **OutOfSync** then **Degraded** within ~30 seconds.

```bash
# Check the live replica count
kubectl get deployment podinfo -n apps
```

**Wait ~3 minutes** — ArgoCD's self-heal loop fires and restores replicas to 2 automatically.

```bash
# Confirm self-healed
kubectl get deployment podinfo -n apps
kubectl get pods -n apps -l app=podinfo
```

Or force it immediately:

```bash
kubectl patch application podinfo -n argocd \
  --type merge \
  -p '{"operation": {"initiatedBy": {"username": "demo"}, "sync": {"revision": "HEAD"}}}'
```

### 2.4 Show sync history

```bash
kubectl get application podinfo -n argocd \
  -o jsonpath='{.status.history}' | python3 -m json.tool
```

Shows every sync with timestamp, revision SHA, and who initiated it.

---

## Scenario 3 — Kyverno Policy Engine

**Narrative:** Show policy as code — audit violations are logged, enforce mode blocks bad workloads at the gate.

### 3.1 View all policies

```bash
kubectl get clusterpolicies
```

Walk through the table — note VALIDATE, MUTATE columns, READY=True on all.

```bash
# Describe one policy to show the full rule
kubectl describe clusterpolicy require-resource-limits
```

### 3.2 Create the test namespace

```bash
kubectl create namespace policy-test --dry-run=client -o yaml | kubectl apply -f -
```

### 3.3 Test 1 — Compliant pod (passes everything)

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: compliant-pod
  namespace: policy-test
  labels:
    app: demo
    env: dev
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
  containers:
    - name: app
      image: nginx:1.25-alpine
      resources:
        limits: {cpu: "100m", memory: "64Mi"}
        requests: {cpu: "50m", memory: "32Mi"}
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 1000
        capabilities:
          drop: [ALL]
      livenessProbe:
        httpGet: {path: /, port: 80}
        periodSeconds: 10
      readinessProbe:
        httpGet: {path: /, port: 80}
        periodSeconds: 10
EOF
```

```bash
# Confirm created with no violations, and Kyverno injected labels
kubectl get pod compliant-pod -n policy-test --show-labels
```

Point out `managed-by=kyverno` injected automatically.

### 3.4 Test 2 — Missing resource limits (audit violation)

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: missing-limits
  namespace: policy-test
  labels:
    app: demo
    env: dev
spec:
  containers:
    - name: app
      image: nginx:1.25-alpine
      # No resources block — violation of require-resource-limits
EOF
```

Pod is created (Audit mode doesn't block), but a violation is logged:

```bash
# Wait ~10 seconds for Kyverno to generate the report, then:
kubectl get policyreport -n policy-test
kubectl get policyreport -n policy-test -o jsonpath='{.items[0].results}' | python3 -m json.tool
```

Show the `fail` result for `require-resource-limits`.

### 3.5 Test 3 — Missing labels (audit violation)

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: missing-labels
  namespace: policy-test
  # No labels — violates require-pod-labels
spec:
  containers:
    - name: app
      image: nginx:1.25-alpine
      resources:
        limits: {cpu: "100m", memory: "64Mi"}
        requests: {cpu: "50m", memory: "32Mi"}
EOF
```

```bash
kubectl get policyreport -n policy-test -o wide
```

### 3.6 Test 4 — Privileged container (ENFORCE — will be blocked)

This is the highlight — the pod never gets created:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: policy-test
  labels:
    app: demo
    env: dev
spec:
  containers:
    - name: app
      image: nginx:1.25-alpine
      resources:
        limits: {cpu: "100m", memory: "64Mi"}
        requests: {cpu: "50m", memory: "32Mi"}
      securityContext:
        privileged: true
EOF
```

**Expected output:**
```
Error from server: error when creating "STDIN": admission webhook
"validate-policy.kyverno.svc" denied the request:
disallow-privileged-containers: Privileged containers are not allowed.
```

```bash
# Confirm it was never created
kubectl get pod privileged-pod -n policy-test 2>&1
```

### 3.7 View the full violation report

```bash
kubectl describe policyreport -n policy-test
```

Walk through: policy name, rule name, result (pass/fail), message, and the resource that triggered it.

### 3.8 Cleanup

```bash
kubectl delete pod compliant-pod missing-limits missing-labels -n policy-test --ignore-not-found
```

---

## Scenario 4 — Sample Applications

**Narrative:** Show the actual running apps and what they expose.

### 4.1 Guestbook

Open http://localhost:8888

- Type a message and click **Submit**
- Messages persist via Redis (leader/follower topology running in the cluster)
- Refresh the page — messages survive because they're in Redis, not in memory

```bash
# Show the full guestbook stack — frontend + redis
kubectl get deployments,services -n apps -l "role in (leader,follower)" 
kubectl get deployment guestbook -n apps
```

Show: redis-leader (1 replica, handles writes) + redis-follower (2 replicas, handle reads) + guestbook frontend (2 replicas).

### 4.2 Podinfo

Open http://localhost:9898

```bash
# Port-forward if not already running
kubectl port-forward svc/podinfo 9898:9898 -n apps
```

Point out:
- **UI** shows pod name, namespace, version, colour (configurable via env var)
- **/metrics** endpoint — open http://localhost:9898/metrics in browser
- **/healthz** and **/readyz** — the probes Kubernetes uses
- **/env** — shows container environment

```bash
# Hit the API directly
curl http://localhost:9898/
curl http://localhost:9898/env
curl http://localhost:9898/info
```

### 4.3 Load generator

```bash
# Show k6 is generating continuous traffic to podinfo
kubectl logs -n apps -l app=load-generator --tail=20
```

Show the k6 output — VUs, requests/s, response times. This is what drives the Grafana dashboards.

---

## Scenario 5 — Prometheus & Grafana

**Narrative:** Show live metrics from the cluster and the apps.

### 5.1 Prometheus targets

Open http://localhost:9090/targets

Point out:
- `kube-state-metrics` — Kubernetes object metrics (deployments, pods, etc.)
- `node-exporter` — host-level CPU/memory/disk metrics  
- `kubelet` — container metrics via cAdvisor
- `podinfo` — application metrics (the ServiceMonitor we deployed)

### 5.2 Run live PromQL queries

Open http://localhost:9090 and run these queries to narrate each:

**Pod restarts (would trigger PodCrashLooping alert):**
```promql
rate(kube_pod_container_status_restarts_total{namespace="apps"}[10m]) * 60
```

**Podinfo HTTP request rate (driven by load-generator):**
```promql
rate(http_requests_total{job="podinfo"}[1m])
```

**Memory usage by pod in apps namespace:**
```promql
container_memory_working_set_bytes{namespace="apps", container!=""}
```

**Node memory available:**
```promql
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100
```

**Kyverno policy results (any failures):**
```promql
kyverno_policy_results_total{rule_result="fail"}
```

### 5.3 Alerting rules

Open http://localhost:9090/alerts

```bash
# Also show via kubectl
kubectl get prometheusrule devops-lab-alerts -n monitoring -o yaml
```

Walk through the alert groups — app.health, resource.pressure, kyverno.policy.

### 5.4 Grafana dashboards

Open http://localhost:3000 (admin/admin)

Navigate to **Dashboards → Browse:**

- **Kubernetes / Compute Resources / Namespace (Pods)** — select namespace `apps`, show CPU/memory per pod
- **Kubernetes / Compute Resources / Node** — show node-level resource consumption
- **Node Exporter / Nodes** — OS-level metrics

Point out the load-generator is making the podinfo metrics charts show real traffic.

### 5.5 Trigger an alert (optional — takes ~10 minutes to fire)

```bash
# Run a CPU stress pod in apps namespace
kubectl run stressor -n apps \
  --image=busybox \
  --restart=Never \
  --labels="app=stressor,env=dev" \
  -- sh -c "while true; do :; done"
```

Watch in Prometheus → Alerts for `ContainerHighCpuUsage` to move from **inactive** to **pending** to **firing**.

```bash
# Clean up when done
kubectl delete pod stressor -n apps
```

---

## Scenario 6 — GitOps Change Flow

**Narrative:** Make a real change in Git and watch ArgoCD deploy it end-to-end.

### 6.1 Change podinfo colour

In your editor, open `apps/podinfo/deployment.yaml` and change the UI colour:

```yaml
env:
  - name: PODINFO_UI_COLOR
    value: "#e91e63"   # change from #42a5f5 (blue) to #e91e63 (pink)
```

```bash
git add apps/podinfo/deployment.yaml
git commit -m "demo: change podinfo UI colour to pink"
git push
```

### 6.2 Watch ArgoCD detect and deploy the change

```bash
# Watch ArgoCD pick up the new commit (~3 minute polling interval)
# Or watch the application status
kubectl get application podinfo -n argocd -w
```

In ArgoCD UI: watch `podinfo` flip to **OutOfSync** → **Syncing** → **Synced/Healthy**.

```bash
# Watch the rolling update
kubectl rollout status deployment/podinfo -n apps
```

Open http://localhost:9898 — the UI colour has changed.

### 6.3 Rollback via Git

```bash
git revert HEAD --no-edit
git push
```

ArgoCD deploys the revert automatically. Point out: **the audit trail is in Git** — `git log` shows every change and who made it.

---

## Scenario 7 — MCP / AI Integration

**Narrative:** Show that Claude can inspect and reason about the cluster in real time via the Kubernetes MCP server.

### 7.1 Generate the viewer kubeconfig

```bash
./scripts/bifrost-mcp-setup.sh
```

This creates a read-only service account token and prints the config block for Claude Desktop.

### 7.2 What the MCP server exposes

```bash
# The viewer SA can read everything relevant — show its permissions
kubectl auth can-i list pods --as=system:serviceaccount:apps:devops-lab-viewer -n apps
kubectl auth can-i list applications --as=system:serviceaccount:apps:devops-lab-viewer -n argocd
kubectl auth can-i delete pods --as=system:serviceaccount:apps:devops-lab-viewer -n apps
```

Read access: ✅ pods, deployments, applications, clusterpolicies, prometheusrules  
Write access: ❌ blocked — viewer only

### 7.3 Example MCP-powered queries to demonstrate

With the MCP server connected to Claude, you can ask:

- *"What pods are running in the apps namespace and are they all healthy?"*
- *"Show me the current ArgoCD sync status for all applications"*
- *"Are there any Kyverno policy violations in the cluster?"*
- *"What Prometheus alerts are currently defined?"*
- *"Which pods in apps are not compliant with the resource limits policy?"*

---

## Teardown

```bash
# Stop port-forwards
./scripts/port-forwards.sh stop

# Delete the kind cluster (removes everything)
kind delete cluster --name devops-lab

# Optional: remove Docker resources
docker system prune -f --filter label=io.x-k8s.kind.cluster
```

---

## Quick Reference

```bash
# Context
kubectl config use-context kind-devops-lab

# ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# All apps status
kubectl get applications -n argocd

# All pods
kubectl get pods -A

# Policy reports
kubectl get policyreport -A

# Prometheus rules
kubectl get prometheusrule -n monitoring

# Events (sorted by time — good for debugging)
kubectl get events -n apps --sort-by='.lastTimestamp'

# ArgoCD force sync
kubectl patch application <app-name> -n argocd \
  --type merge \
  -p '{"operation": {"initiatedBy": {"username": "demo"}, "sync": {"revision": "HEAD"}}}'
```
