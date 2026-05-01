# DevOps Lab — GitOps Repository

The GitOps source-of-truth for the `devops-lab` kind cluster.

## Repository Layout

```
devops-lab-repo/
├── apps/
│   ├── guestbook/          # Classic demo app (Deployment, Service, ServiceMonitor)
│   ├── podinfo/            # Feature-rich app with /metrics, /healthz — Prometheus demo
│   ├── load-generator/     # k6 load generator → drives Grafana dashboards
│   └── policy-test-suite/  # Kyverno test pods (compliant + violating)
├── base/
│   ├── namespaces/         # All namespace definitions
│   ├── rbac/               # Viewer SA for Bifrost / MCP access
│   └── network-policies/   # Default-deny + allow rules
├── argocd/
│   ├── projects/           # AppProject scoping repos + destinations
│   ├── applications/       # Individual Application manifests
│   └── appsets/            # ApplicationSet (single-entrypoint deploy)
├── kyverno/
│   └── policies/           # 7 ClusterPolicies (validate + mutate)
├── prometheus/
│   └── rules/              # PrometheusRule — app + Kyverno + ArgoCD alerts
├── scripts/
│   ├── bootstrap-repo.sh   # Create GitHub repo + push + apply AppSet
│   ├── bifrost-mcp-setup.sh # Generate viewer kubeconfig for Bifrost/MCP
│   └── demo-flow.sh        # Interactive demo runner
└── .github/workflows/
    └── validate.yaml       # kubeconform + kyverno-cli CI
```

## Quick Start

### 1. Bootstrap the repo

```bash
# Authenticate GitHub CLI
gh auth login

# Create repo, push manifests, apply ArgoCD ApplicationSet
./scripts/bootstrap-repo.sh --org YOUR_GITHUB_USER
```

### 2. Apply base resources to the cluster

```bash
kubectl apply -f base/namespaces/
kubectl apply -f base/rbac/
kubectl apply -f base/network-policies/
```

### 3. Apply the ArgoCD AppSet (syncs everything)

```bash
kubectl apply -f argocd/projects/devops-lab-project.yaml
kubectl apply -f argocd/appsets/devops-lab-appset.yaml
```

After ~2 minutes all apps will appear in ArgoCD UI (http://localhost:30950).

## Sample Applications

### podinfo

Exposes real Prometheus metrics at `:9898/metrics`. The load-generator fires HTTP traffic continuously so Grafana dashboards are populated immediately.

```bash
kubectl port-forward svc/podinfo 9898:9898 -n apps
open http://localhost:9898
```

### guestbook

Classic multi-tier web app. Good for testing scaling, rolling updates, and ArgoCD sync drift.

### load-generator

k6-based continuous traffic generator. Drives `http_requests_total`, `http_request_duration_seconds`, and error rate metrics.

```bash
# Scale up for higher load
kubectl scale deployment load-generator -n apps --replicas=3
```

## Kyverno Policies

| # | Policy | Mode | Tests |
|---|--------|------|-------|
| 01 | `require-resource-limits` | Audit | `missing-limits.yaml` |
| 02 | `disallow-root-user` | Audit | `root-user.yaml` |
| 03 | `disallow-privileged-containers` | **Enforce** | `privileged-pod.yaml` |
| 04 | `require-pod-labels` | Audit | `missing-labels.yaml` |
| 05 | `add-default-labels` | Mutate | any pod in `apps` |
| 06 | `disallow-latest-tag` | Audit | `:latest` images |
| 07 | `require-liveness-readiness-probes` | Audit | pods without probes |

```bash
# Run policy tests
kubectl apply -f apps/policy-test-suite/
kubectl get policyreport -n policy-test -o wide
```

## Bifrost + MCP Integration

```bash
# Generate viewer kubeconfig + print Bifrost/MCP config
./scripts/bifrost-mcp-setup.sh
```

This creates a read-only `ServiceAccount` with a token, writes `./devops-lab-viewer.kubeconfig`, and prints the configuration block for:
- **Bifrost** (`bifrost.yaml` kubernetes block)
- **MCP server** (`claude_desktop_config.json` entry)

## Demo Flow

```bash
# Full demo sequence
./scripts/demo-flow.sh all

# Individual scenarios
./scripts/demo-flow.sh argocd      # GitOps drift + self-heal
./scripts/demo-flow.sh kyverno     # Policy enforce + audit
./scripts/demo-flow.sh prometheus  # Metrics + alerting
./scripts/demo-flow.sh mcp         # Bifrost/MCP config
```

## Prometheus Alerts

The `PrometheusRule` in `prometheus/rules/` covers:

- **App health** — PodCrashLooping, DeploymentReplicasMismatch, PodNotReady
- **Resource pressure** — ContainerHighCpuUsage, ContainerHighMemoryUsage, NodeHighMemoryPressure
- **Kyverno** — KyvernoPolicyViolation, KyvernoHighViolationRate
- **ArgoCD** — ArgoCDAppOutOfSync, ArgoCDAppUnhealthy

## CI Validation

Every PR runs:
1. `kubeconform` — validates all YAML against Kubernetes schemas + CRD schemas
2. `kyverno apply` — runs policies against the test suite manifests
3. YAML diff summary

---

*See the cluster setup README at the root of the devops-lab scripts repo.*
