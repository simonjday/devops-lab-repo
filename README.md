# DevOps Lab — GitOps Repository

The GitOps source-of-truth for the `devops-lab` kind cluster.

> **Cluster:** `kind-devops-lab` | **Repo:** `https://github.com/simonjday/devops-lab-repo`

---

## Repository Layout

```
devops-lab-repo/
├── apps/
│   ├── guestbook/          # Classic demo app (Deployment, Service, ServiceMonitor)
│   ├── podinfo/            # Feature-rich app with /metrics, /healthz — Prometheus demo
│   ├── load-generator/     # k6 continuous traffic generator → drives Grafana dashboards
│   └── policy-test-suite/  # Kyverno test pods (compliant + violating)
├── base/
│   ├── namespaces/         # All namespace definitions
│   ├── rbac/               # Viewer SA for Bifrost / MCP access
│   └── network-policies/   # Default-deny + allow rules
├── argocd/
│   ├── projects/           # AppProject scoping repos + destinations
│   ├── applications/       # Individual Application manifests (reference only)
│   └── appsets/            # ApplicationSet — single entrypoint, manages all apps
├── kyverno/
│   └── policies/           # 7 ClusterPolicies (validate + mutate)
├── prometheus/
│   └── rules/              # PrometheusRule — app health + Kyverno alerts
├── scripts/
│   ├── bootstrap-repo.sh   # Full end-to-end: kind cluster + platform + GitHub + ArgoCD
│   ├── port-forwards.sh    # Open all service UIs in one command
│   ├── bifrost-mcp-setup.sh # Generate viewer kubeconfig for Bifrost/MCP
│   └── demo-flow.sh        # Interactive demo runner (argocd/kyverno/prometheus/mcp)
└── .github/workflows/
    └── validate.yaml       # kubeconform + kyverno-cli CI on every PR
```

---

## Quick Start — Fresh Machine

The bootstrap script handles everything end-to-end: kind cluster creation, platform tooling, GitHub repo, and ArgoCD wiring.

```bash
# Prerequisites: docker, kind, kubectl, helm, git, gh
gh auth login

# Creates cluster, installs ArgoCD + Prometheus + Kyverno,
# pushes to GitHub, and applies the ApplicationSet
./scripts/bootstrap-repo.sh --org simonjday
```

### What the bootstrap does (in order)

| Step | Action |
|------|--------|
| 0 | Preflight checks — docker, kind, kubectl, helm, git, gh |
| 1 | Create kind cluster with `extraPortMappings` (no port-forward needed) |
| 2 | Create namespaces |
| 3 | Install ArgoCD, wait for CRDs, patch `--insecure`, expose NodePort |
| 4 | Install kube-prometheus-stack via Helm |
| 5 | Install Kyverno via Helm, wait for CRDs |
| 6 | Apply RBAC (Bifrost/MCP viewer ServiceAccount) |
| 7 | Create GitHub repo, patch manifests with repo URL, push |
| 8 | Apply ArgoCD AppProject + ApplicationSet |

The script is **idempotent** — safe to re-run if anything fails partway through.

---

## Access

All UIs are available directly on `localhost` — no `kubectl port-forward` needed because the kind cluster is created with `extraPortMappings`.

| Service | URL | Credentials |
|---------|-----|-------------|
| ArgoCD | http://localhost:9080 | admin / (printed at end of bootstrap) |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | — |
| Alertmanager | http://localhost:9093 | — |

> **Note:** `extraPortMappings` are only configured if the cluster was created by `bootstrap-repo.sh`. If you have a pre-existing kind cluster, use `./scripts/port-forwards.sh` instead.

```bash
# Open all UIs via port-forward (for pre-existing clusters)
./scripts/port-forwards.sh start    # starts all 4 in background
./scripts/port-forwards.sh stop     # kills them all
./scripts/port-forwards.sh status   # check which are running
```

---

## ArgoCD Applications

All apps are managed by a single `ApplicationSet` in `argocd/appsets/`. Each app has automated sync with pruning and self-healing enabled.

| App | Source Path | Namespace | Sync | Health |
|-----|------------|-----------|------|--------|
| guestbook | `apps/guestbook` | apps | ✅ Synced | ✅ Healthy |
| podinfo | `apps/podinfo` | apps | ✅ Synced | ✅ Healthy |
| load-generator | `apps/load-generator` | apps | ✅ Synced | ✅ Healthy |
| kyverno-policies | `kyverno/policies` | kyverno | ✅ Synced | ✅ Healthy |
| prometheus-rules | `prometheus/rules` | monitoring | ✅ Synced | ✅ Healthy |

### Kyverno ignoreDifferences

The ApplicationSet includes `ignoreDifferences` for Kyverno `ClusterPolicy` resources. This is required because Kyverno's admission webhook injects additional fields after every apply (`spec.admission`, `spec.emitWarning`, `skipBackgroundRequests`, `allowExistingViolations`, and `autogen-*` rules for Deployments/StatefulSets). Without this, ArgoCD permanently reports OutOfSync even when the resources are correct.

```yaml
ignoreDifferences:
  - group: kyverno.io
    kind: ClusterPolicy
    jqPathExpressions:
      - .spec.admission
      - .spec.emitWarning
      - .spec.rules[].skipBackgroundRequests
      - .spec.rules[].validate.allowExistingViolations
      - .spec.rules[] | select(.name | startswith("autogen-"))
      - .status
syncOptions:
  - RespectIgnoreDifferences=true
```

---

## Sample Applications

### podinfo

Exposes real Prometheus metrics at `:9898/metrics` out of the box. The load-generator fires continuous HTTP traffic so Grafana dashboards populate immediately.

```bash
kubectl port-forward svc/podinfo 9898:9898 -n apps
open http://localhost:9898
```

### guestbook

> **Image note:** The original `gcr.io/google-samples/gb-frontend:v4` was removed by Google from GCR. This repo uses the current location: `us-docker.pkg.dev/google-samples/containers/gke/gb-frontend:v5`

Good for ArgoCD drift demos — scale it down directly and watch self-heal trigger.

```bash
# Simulate drift — ArgoCD restores within ~3 minutes
kubectl scale deployment guestbook -n apps --replicas=0

# Or force an immediate sync
argocd app sync guestbook --force
```

### load-generator

k6-based continuous traffic generator running in-cluster against podinfo. Drives `http_requests_total`, latency histograms, and error rate metrics in Grafana.

```bash
# Scale up for higher load on the demo
kubectl scale deployment load-generator -n apps --replicas=3
```

---

## Kyverno Policies

All 7 policies are deployed and managed via ArgoCD from `kyverno/policies/`.

| # | Policy | Mode | What it checks |
|---|--------|------|----------------|
| 01 | `require-resource-limits` | Audit | CPU + memory limits on all containers |
| 02 | `disallow-root-user` | Audit | `runAsNonRoot: true` and `runAsUser > 0` |
| 03 | `disallow-privileged-containers` | **Enforce** | Blocks `privileged: true` — pods are rejected |
| 04 | `require-pod-labels` | Audit | `app` and `env` labels required in workload namespaces |
| 05 | `add-default-labels` | **Mutate** | Injects `managed-by: kyverno` + `cluster: devops-lab` on all pods |
| 06 | `disallow-latest-tag` | Audit | Image tag must be pinned (not `:latest` or untagged) |
| 07 | `require-liveness-readiness-probes` | Audit | Both probes must be defined on containers |

> **Operator note:** Policy 06 uses `AnyNotIn` operator. `NotContains` was removed in Kyverno 3.x and will be rejected by the admission webhook. All policies automatically get `autogen-*` variants for Deployments, StatefulSets, DaemonSets, and CronJobs generated by Kyverno.

### Running the policy test suite

```bash
kubectl create namespace policy-test --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f apps/policy-test-suite/

# Expected results:
#   compliant-pod.yaml   → ✅ Created, no violations
#   missing-limits.yaml  → ⚠️  Created + audit report
#   missing-labels.yaml  → ⚠️  Created + audit report
#   root-user.yaml       → ⚠️  Created + audit report
#   privileged-pod.yaml  → ❌ BLOCKED (Enforce mode)

kubectl get policyreport -n policy-test -o wide
kubectl describe policyreport -n policy-test
```

---

## Prometheus Alerts

The `PrometheusRule` in `prometheus/rules/devops-lab-alerts.yaml` is validated by the Prometheus operator admission webhook on apply. Rules use single-metric expressions for compatibility.

| Group | Alert | Trigger |
|-------|-------|---------|
| app.health | `PodCrashLooping` | >3 restarts in 10m |
| app.health | `DeploymentReplicasMismatch` | spec replicas ≠ available replicas for 5m |
| app.health | `PodNotReady` | Pod Pending/Unknown for 5m |
| resource.pressure | `NodeHighMemoryPressure` | Node memory < 10% free |
| kyverno.policy | `KyvernoPolicyViolation` | Any policy `fail` result in 5m window |
| kyverno.policy | `KyvernoHighViolationRate` | >1 violation/s over 10m |

> **Note:** ArgoCD sync/health alerts were removed — ArgoCD metrics are not scraped by Prometheus in this setup by default. Multi-dimensional ratio expressions (e.g. `container_cpu / kube_pod_container_resource_limits`) are rejected by the operator webhook; use single-metric queries only.

---

## Bifrost + MCP Integration

A read-only `ServiceAccount` (`devops-lab-viewer`) is created in the `apps` namespace with cluster-wide read access to pods, deployments, ArgoCD applications, Kyverno policies, and Prometheus rules.

```bash
# Generate kubeconfig + print ready-to-paste config for Bifrost and MCP
./scripts/bifrost-mcp-setup.sh
```

This writes `./devops-lab-viewer.kubeconfig` and prints config blocks for:

- **Bifrost** — `bifrost.yaml` kubernetes cluster stanza
- **MCP server** — `claude_desktop_config.json` entry using `@modelcontextprotocol/server-kubernetes`

The Kubernetes MCP server (`kubernetes-local`) can be pointed at the `kind-devops-lab` context directly for AI-assisted cluster inspection and debugging.

---

## Demo Flow

```bash
# Run all scenarios in sequence
./scripts/demo-flow.sh all

# Or run individually
./scripts/demo-flow.sh argocd      # GitOps drift detection + self-heal
./scripts/demo-flow.sh kyverno     # Policy enforce (blocked) + audit (logged)
./scripts/demo-flow.sh prometheus  # Live metrics, port-forward, alert firing
./scripts/demo-flow.sh mcp         # Bifrost/MCP kubeconfig + config output
```

---

## CI Validation

Every PR triggers `.github/workflows/validate.yaml` which runs:

1. **kubeconform** — validates all YAML against upstream Kubernetes schemas and CRD schemas from `datreeio/CRDs-catalog`
2. **kyverno-cli** — applies all policies against the test suite manifests and reports violations
3. **Diff summary** — lists changed YAML files between branches

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `kyverno-policies` OutOfSync after every sync | Kyverno webhook injects fields ArgoCD didn't write | `ignoreDifferences` + `RespectIgnoreDifferences=true` in AppSet ✅ already applied |
| `prometheus-rules` SyncFailed | Prometheus operator rejects invalid PromQL or multi-dim joins | Use single-metric expressions only; avoid label joins across metrics |
| `guestbook` ImagePullBackOff | `gcr.io/google-samples/gb-frontend:v4` removed by Google | ✅ Fixed — now uses `us-docker.pkg.dev/google-samples/containers/gke/gb-frontend:v5` |
| ArgoCD UI 404 on localhost | Pre-existing kind cluster without `extraPortMappings` | Run `./scripts/port-forwards.sh` or recreate cluster with `bootstrap-repo.sh` |
| `sed` errors on macOS during bootstrap | BSD sed vs GNU sed `-i` syntax | ✅ Fixed — bootstrap uses `perl -pi` which is cross-platform |
| `gh repo create --org` flag not found | Flag removed in newer `gh` CLI versions | ✅ Fixed — uses `owner/repo-name` format instead |
| ArgoCD CRD not found on first run | Script exited before CRDs were installed | ✅ Fixed — bootstrap installs and waits for CRDs before applying CRs |

---

## Teardown

```bash
kind delete cluster --name devops-lab
docker system prune -f --filter label=io.x-k8s.kind.cluster
```
