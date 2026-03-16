#!/usr/bin/env bash
# Setup pipeline resources and credentials

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

NAMESPACE="${NAMESPACE:-work}"

echo_step() {
    echo -e "\n\033[1;34m==>\033[0m \033[1m$1\033[0m"
}

echo_success() {
    echo -e "\033[1;32m✓\033[0m $1"
}

echo_info() {
    echo -e "\033[0;36m$1\033[0m"
}

echo_error() {
    echo -e "\033[1;31m✗\033[0m $1" >&2
}

# Create namespace
setup_namespace() {
    echo_step "Setting up namespace '${NAMESPACE}'"

    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        kubectl create namespace "${NAMESPACE}"
    fi

    kubectl config set-context --current --namespace="${NAMESPACE}"
    echo_success "Namespace ready"
}

# Setup registry credentials
setup_credentials() {
    echo_step "Setting up registry credentials"

    # Check for docker config in common locations
    local docker_config=""
    if [[ -f "${HOME}/.docker/config.json" ]]; then
        docker_config="${HOME}/.docker/config.json"
    elif [[ -f "${ROOT}/pipelines/docker.config" ]]; then
        docker_config="${ROOT}/pipelines/docker.config"
    fi

    if [[ -z "${docker_config}" ]]; then
        echo_error "No docker config found"
        echo_info "Create credentials manually:"
        echo_info "  kubectl create secret generic docker-credentials \\"
        echo_info "    --from-file=config.json=<path-to-docker-config> \\"
        echo_info "    -n ${NAMESPACE}"
        exit 1
    fi

    echo_info "Using docker config from: ${docker_config}"

    # Create docker-credentials secret for buildah workspace
    if kubectl get secret docker-credentials -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo_info "Secret 'docker-credentials' already exists"
    else
        kubectl create secret generic docker-credentials \
            --from-file=config.json="${docker_config}" \
            -n "${NAMESPACE}"
        echo_success "Created 'docker-credentials' secret (for buildah)"
    fi

    # Create docker-config secret for service account (proper type for imagePullSecrets)
    kubectl create secret generic docker-config \
        --from-file=.dockerconfigjson="${docker_config}" \
        --type=kubernetes.io/dockerconfigjson \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo_success "Created 'docker-config' secret (for service account)"

    # Patch the default service account to use the credentials
    kubectl patch serviceaccount default -n "${NAMESPACE}" \
        -p '{"imagePullSecrets": [{"name": "docker-config"}], "secrets": [{"name": "docker-config"}]}'
    echo_success "Patched default service account with registry credentials"

    # Create credentials for Tekton Chains to push attestations
    echo_info "Setting up Tekton Chains registry credentials..."
    kubectl create secret generic docker-config \
        --from-file=.dockerconfigjson="${docker_config}" \
        --type=kubernetes.io/dockerconfigjson \
        -n tekton-chains \
        --dry-run=client -o yaml | kubectl apply -f -

    # Patch the tekton-chains-controller service account
    kubectl patch serviceaccount tekton-chains-controller -n tekton-chains \
        -p '{"imagePullSecrets": [{"name": "docker-config"}], "secrets": [{"name": "docker-config"}]}'
    echo_success "Configured Tekton Chains with registry credentials"

    # Restart Chains controller to pick up the new credentials
    kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
    kubectl rollout status deployment tekton-chains-controller -n tekton-chains --timeout=60s
    echo_success "Tekton Chains controller restarted"
}

# Install tasks
install_tasks() {
    echo_step "Installing Tekton tasks"

    echo_info "Installing git-clone task..."
    kubectl apply -f "${ROOT}/pipelines/git-clone.yaml" -n "${NAMESPACE}"

    echo_info "Installing buildah task..."
    kubectl apply -f "https://raw.githubusercontent.com/tektoncd/catalog/main/task/buildah/0.8/buildah.yaml" -n "${NAMESPACE}"

    echo_info "Installing integration-test task..."
    kubectl apply -f "${ROOT}/pipelines/integration-test-task.yaml" -n "${NAMESPACE}"

    echo_success "Tasks installed"
}

# Install pipelines
install_pipelines() {
    echo_step "Installing pipelines"

    echo_info "Installing build pipeline..."
    kubectl apply -f "${ROOT}/pipelines/pipeline.yaml" -n "${NAMESPACE}"

    echo_info "Installing integration test pipeline..."
    kubectl apply -f "${ROOT}/pipelines/integration-test-pipeline.yaml" -n "${NAMESPACE}"

    echo_success "Pipelines installed"
}

# Print summary
print_summary() {
    echo_step "Setup Complete!"
    echo ""
    echo "Namespace:  ${NAMESPACE}"
    echo ""
    echo "Installed tasks:"
    kubectl get tasks -n "${NAMESPACE}" -o custom-columns=NAME:.metadata.name --no-headers | sed 's/^/  - /'
    echo ""
    echo "Installed pipelines:"
    kubectl get pipelines -n "${NAMESPACE}" -o custom-columns=NAME:.metadata.name --no-headers | sed 's/^/  - /'
    echo ""
    echo "Next step:"
    echo "  ./scripts/run-build.sh"
}

main() {
    setup_namespace
    setup_credentials
    install_tasks
    install_pipelines
    print_summary
}

main "$@"
