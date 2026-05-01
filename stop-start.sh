#!/bin/bash
set -euo pipefail

KIND_CLUSTER_NAME="devops-lab"
CTL_PLANE="kind-${KIND_CLUSTER_NAME}-control-plane"
WORKER="kind-${KIND_CLUSTER_NAME}-worker"

show_usage() {
    echo "Usage: $0 {start|stop}"
    exit 1
}

ensure_containers_exist() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CTL_PLANE}$"; then
        echo "control-plane container not found (did you create the cluster with 'kind create cluster --name ${KIND_CLUSTER_NAME}' first?)"
        exit 1
    fi
}

do_stop() {
    ensure_containers_exist
    echo "Stopping Docker containers for cluster '${KIND_CLUSTER_NAME}'..."

    docker stop "${CTL_PLANE}"  || true
    docker stop "${WORKER}"     || true

    echo "Cluster stopped (containers still exist)."
}

do_start() {
    if kind get clusters | grep -q "${KIND_CLUSTER_NAME}"; then
        echo "Cluster ${KIND_CLUSTER_NAME} already exists."
        echo "kubectl --context=kind-${KIND_CLUSTER_NAME} get nodes"
    else
        echo "Creating multi‑node cluster: ${KIND_CLUSTER_NAME}"
        kind create cluster \
            --name "${KIND_CLUSTER_NAME}" \
            --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF
    fi
    echo "kubectl --context=kind-${KIND_CLUSTER_NAME} get nodes"
}

case "${1:-}" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    *)
        show_usage
        ;;
esac