#!/bin/bash
set -euo pipefail

KIND_CLUSTER_NAME="devops-lab"
KIND_CONTEXT="kind-${KIND_CLUSTER_NAME}"

show_usage() {
    echo "Usage: $0 {start|stop}"
    exit 1
}

list_lab_containers() {
    # Match the actual names you see in docker ps
    docker ps -a --format '{{.Names}}' | grep "^${KIND_CLUSTER_NAME}-" || true
}

do_stop() {
    if ! kind get clusters | grep -q "${KIND_CLUSTER_NAME}"; then
        echo "Cluster ${KIND_CLUSTER_NAME} not found in 'kind get clusters'."
        echo "Maybe you created it with a different method or name?"
        exit 1
    fi

    echo "Stopping containers for cluster '${KIND_CLUSTER_NAME}'..."
    list_lab_containers | while IFS= read -r container; do
        echo "Stopping container: ${container}"
        docker stop "${container}" || true
    done

    echo "Cluster stopped (containers still exist)."
}

do_start() {
    echo "Starting containers for cluster '${KIND_CLUSTER_NAME}'..."
    list_lab_containers | while IFS= read -r container; do
        echo "Starting container: ${container}"
        docker start "${container}" || true
    done

    echo "Check with:"
    echo "  kubectl --context=${KIND_CONTEXT} get nodes"
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