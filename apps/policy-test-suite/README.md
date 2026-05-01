# Policy Test Suite

This directory contains manifests that test the Kyverno policies installed in the cluster.

## Running the tests

```bash
# Apply the policy-test namespace first
kubectl create namespace policy-test --dry-run=client -o yaml | kubectl apply -f -

# Apply the compliant pod (should succeed silently)
kubectl apply -f compliant-pod.yaml

# Apply audit violations (these WILL be created, but violations are logged)
kubectl apply -f missing-limits.yaml
kubectl apply -f missing-labels.yaml
kubectl apply -f root-user.yaml

# Apply the enforce violation (this WILL BE BLOCKED)
kubectl apply -f privileged-pod.yaml
# Expected: Error from server (Forbidden): ... disallow-privileged-containers

# View policy reports
kubectl get policyreport -n policy-test -o wide
kubectl describe policyreport -n policy-test
```

## Expected results

| Manifest | Result | Policy | Mode |
|---|---|---|---|
| `compliant-pod.yaml` | ✅ Created, no violations | all | — |
| `missing-limits.yaml` | ⚠️ Created + audit report | `require-resource-limits` | Audit |
| `missing-labels.yaml` | ⚠️ Created + audit report | `require-pod-labels` | Audit |
| `root-user.yaml` | ⚠️ Created + audit report | `disallow-root-user` | Audit |
| `privileged-pod.yaml` | ❌ Blocked | `disallow-privileged-containers` | Enforce |
