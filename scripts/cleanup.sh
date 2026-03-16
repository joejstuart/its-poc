#!/usr/bin/env bash
# Cleanup demo resources

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Configuration
NAMESPACE="${NAMESPACE:-work}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-its-demo}"

echo_step() {
    echo -e "\n\033[1;34m==>\033[0m \033[1m$1\033[0m"
}

echo_success() {
    echo -e "\033[1;32m✓\033[0m $1"
}

echo_info() {
    echo -e "\033[0;36m$1\033[0m"
}

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --pipelineruns    Delete PipelineRuns only"
    echo "  --namespace       Delete the work namespace"
    echo "  --cluster         Delete the entire Kind cluster"
    echo "  --all             Delete everything (cluster)"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Default: Delete PipelineRuns only"
}

cleanup_pipelineruns() {
    echo_step "Deleting PipelineRuns in namespace '${NAMESPACE}'"

    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        kubectl delete pipelinerun --all -n "${NAMESPACE}" --ignore-not-found
        echo_success "PipelineRuns deleted"
    else
        echo_info "Namespace '${NAMESPACE}' does not exist"
    fi
}

cleanup_namespace() {
    echo_step "Deleting namespace '${NAMESPACE}'"

    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        kubectl delete namespace "${NAMESPACE}"
        echo_success "Namespace deleted"
    else
        echo_info "Namespace '${NAMESPACE}' does not exist"
    fi
}

cleanup_cluster() {
    echo_step "Deleting Kind cluster '${KIND_CLUSTER_NAME}'"

    if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        kind delete cluster --name "${KIND_CLUSTER_NAME}"
        echo_success "Kind cluster deleted"
    else
        echo_info "Kind cluster '${KIND_CLUSTER_NAME}' does not exist"
    fi
}

# Parse arguments
ACTION="pipelineruns"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pipelineruns)
            ACTION="pipelineruns"
            shift
            ;;
        --namespace)
            ACTION="namespace"
            shift
            ;;
        --cluster|--all)
            ACTION="cluster"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Execute cleanup
case "${ACTION}" in
    pipelineruns)
        cleanup_pipelineruns
        ;;
    namespace)
        cleanup_pipelineruns
        cleanup_namespace
        ;;
    cluster)
        cleanup_cluster
        ;;
esac

echo_step "Cleanup complete"
