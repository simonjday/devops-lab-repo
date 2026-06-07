# kube-prometheus-stack — Values & Configuration

Helm values for the `kube-prometheus-stack` release in `kind-devops-lab`.
Tracks customisations made to the default chart values so they survive
cluster rebuilds.

## Release info

| Field | Value |
|-------|-------|
| Release name | `kube-prometheus-stack` |
| Namespace | `monitoring` |
| Chart version | `85.0.1` |
| App version | `v0.90.1` (Prometheus Operator) |
| Repo | `prometheus-community` |

---

## Install / Upgrade

### First install

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --create-namespace \
  --version 85.0.1 \
  -f values.yaml \
  --kube-context kind-devops-lab
```

### Upgrade (apply values changes)

```bash
helm repo update prometheus-community

helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --version 85.0.1 \
  -f values.yaml \
  --kube-context kind-devops-lab
```

> Always pin `--version` to avoid pulling a newer chart that may have
> breaking template changes (e.g. nil pointer errors in PrometheusRule templates).

---

## Customisations

### kube-state-metrics label allowlist

**Problem:** kube-state-metrics v2+ drops all pod labels from Prometheus metrics
by default. Without this, `kube_pod_labels` returns empty results and Kubecost
shows all workloads as **Unallocated** regardless of how the pods are labelled.

**Fix:** `--metric-labels-allowlist` explicitly opts in the labels needed for
Kubecost cost attribution.

```yaml
kube-state-metrics:
  extraArgs:
    - --metric-labels-allowlist=pods=[team,cost-centre,environment,app]
```

**Labels exposed:**

| Label | Purpose |
|-------|---------|
| `team` | Primary cost grouping in Kubecost |
| `cost-centre` | Chargeback grouping in Kubecost |
| `environment` | Filter scope (demo/staging/prod) |
| `app` | Per-application breakdown |

> Add any new labels used for cost attribution here and re-run the upgrade.

---

## Verification

### 1. Confirm kube-state-metrics has restarted with new args

```bash
kubectl rollout status deployment/kube-prometheus-stack-kube-state-metrics \
  -n monitoring --context kind-devops-lab

kubectl get deployment kube-prometheus-stack-kube-state-metrics \
  -n monitoring \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  --context kind-devops-lab | tr ',' '\n'
```

Expected: `--metric-labels-allowlist=pods=[team,cost-centre,environment,app]` in the output.

### 2. Confirm labels are flowing through Prometheus

Port-forward Prometheus if not already running:

```bash
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 --context kind-devops-lab
```

Query `kube_pod_labels` for a team namespace:

```bash
curl "http://localhost:9090/api/v1/query?query=kube_pod_labels%7Bnamespace%3D%22team-alpha%22%7D" \
  | jq '.data.result[0].metric'
```

Expected response includes:

```json
{
  "label_app": "alpha-app",
  "label_cost_centre": "engineering",
  "label_environment": "demo",
  "label_team": "alpha",
  "namespace": "team-alpha",
  "pod": "alpha-app-669c97cbd5-xxxxx"
}
```

If the response is `[]` the allowlist is not applied — check the deployment args.

### 3. Confirm Kubecost sees the namespaces (~10 min after step 2)

```bash
curl "http://localhost:9002/model/allocation?window=1d&aggregate=namespace&accumulate=true" \
  | jq '.data[0] | keys'
```

Expected: `team-alpha`, `team-beta`, `team-gamma` appear in the list.

### 4. Kubecost — cost by team label

**UI:** Allocations → Aggregate by → Label → `team`

You should see three rows: `alpha`, `beta`, `gamma` with costs proportional
to their resource requests (beta highest, alpha mid, gamma lowest).

**API:**

```bash
# By team
curl "http://localhost:9002/model/allocation?window=1d&aggregate=label:team&accumulate=true" \
  | jq '.data[0]'

# By cost-centre (chargeback view)
curl "http://localhost:9002/model/allocation?window=1d&aggregate=label:cost-centre&accumulate=true" \
  | jq '.data[0]'

# Both labels combined
curl "http://localhost:9002/model/allocation?window=1d&aggregate=label:team,label:cost-centre&accumulate=true" \
  | jq '.data[0]'

# Filter to demo environment only
curl "http://localhost:9002/model/allocation?window=1d&aggregate=label:team&accumulate=true&filter=label[environment]:demo" \
  | jq '.data[0]'

# 7-day daily breakdown per team
curl "http://localhost:9002/model/allocation?window=7d&aggregate=label:team&accumulate=false" \
  | jq '[.data[] | keys]'
```

### 5. Expected cost split

Given the demo resource profiles:

| Team | CPU req | RAM req | Replicas | Expected share |
|------|---------|---------|----------|----------------|
| beta | 500m | 512Mi | 3 | highest |
| alpha | 100m | 128Mi | 2 | medium |
| gamma | 50m | 64Mi | 1 | lowest |

> On kind, absolute $ values show as `<US$1` — this is expected as kind nodes
> have no cloud provider `instance_type` label. Relative ratios between teams
> are accurate. See the kubecost-team-demo README for optional custom pricing config.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `kube_pod_labels` returns `[]` | allowlist not applied | Check deployment args; re-run upgrade |
| Upgrade fails with nil pointer error | Chart version mismatch | Pin `--version 85.0.1` and run `helm repo update` first |
| Kubecost shows Unallocated after labels appear in Prometheus | Kubecost scrape window not elapsed | Wait 10 min and refresh |
| New label not appearing in Kubecost | Label not in allowlist | Add to `extraArgs` and upgrade |
