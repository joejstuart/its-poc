#!/usr/bin/env bash
# Setup Kind cluster with Tekton Pipelines and Tekton Chains

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Configuration
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-its-demo}"
TEKTON_PIPELINES_VERSION="${TEKTON_PIPELINES_VERSION:-v1.10.0}"
TEKTON_CHAINS_VERSION="${TEKTON_CHAINS_VERSION:-v0.26.2}"
WORK_NAMESPACE="${WORK_NAMESPACE:-work}"

echo_step() {
    echo -e "\n\033[1;34m==>\033[0m \033[1m$1\033[0m"
}

echo_success() {
    echo -e "\033[1;32m✓\033[0m $1"
}

echo_info() {
    echo -e "\033[0;36m$1\033[0m"
}

# Check prerequisites
check_prerequisites() {
    echo_step "Checking prerequisites"

    local missing=()

    command -v kind >/dev/null 2>&1 || missing+=("kind")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
    command -v cosign >/dev/null 2>&1 || missing+=("cosign")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing required tools: ${missing[*]}"
        echo "Please install them before running this script."
        exit 1
    fi

    echo_success "All prerequisites found"
}

# Create Kind cluster
create_cluster() {
    echo_step "Creating Kind cluster: ${KIND_CLUSTER_NAME}"

    if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        echo_info "Cluster '${KIND_CLUSTER_NAME}' already exists, skipping creation"
        kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
        return
    fi

    cat <<EOF | kind create cluster --name="${KIND_CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        "service-node-port-range": "1-65535"
EOF

    echo_success "Kind cluster created"
}

# Install Tekton Pipelines
install_tekton_pipelines() {
    echo_step "Installing Tekton Pipelines ${TEKTON_PIPELINES_VERSION}"

    if kubectl get namespace tekton-pipelines >/dev/null 2>&1; then
        echo_info "Tekton Pipelines namespace exists, checking if already installed..."
        if kubectl -n tekton-pipelines get deployment tekton-pipelines-controller >/dev/null 2>&1; then
            echo_info "Tekton Pipelines already installed, skipping"
            return
        fi
    fi

    kubectl apply -f "https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_PIPELINES_VERSION}/release.yaml"

    echo_info "Waiting for Tekton Pipelines to be ready..."
    kubectl -n tekton-pipelines wait deployment \
        -l "app.kubernetes.io/part-of=tekton-pipelines" \
        --for=condition=Available \
        --timeout=180s

    echo_success "Tekton Pipelines installed"
}

# Enable Tekton features
configure_tekton_features() {
    echo_step "Configuring Tekton feature flags"

    kubectl patch configmap feature-flags -n tekton-pipelines \
        --type merge \
        -p '{"data":{"enable-tekton-oci-bundles":"true"}}'

    echo_success "Tekton features configured"
}

# Install Tekton Chains
install_tekton_chains() {
    echo_step "Installing Tekton Chains ${TEKTON_CHAINS_VERSION}"

    if kubectl get namespace tekton-chains >/dev/null 2>&1; then
        echo_info "Tekton Chains namespace exists, checking if already installed..."
        if kubectl -n tekton-chains get deployment tekton-chains-controller >/dev/null 2>&1; then
            echo_info "Tekton Chains already installed, skipping"
            return
        fi
    fi

    kubectl apply -f "https://infra.tekton.dev/tekton-releases/chains/previous/${TEKTON_CHAINS_VERSION}/release.yaml"

    echo_info "Waiting for Tekton Chains to be ready..."
    kubectl -n tekton-chains wait deployment \
        -l "app.kubernetes.io/part-of=tekton-chains" \
        --for=condition=Available \
        --timeout=180s

    echo_success "Tekton Chains installed"
}

# Configure Tekton Chains for OCI storage
configure_chains() {
    echo_step "Configuring Tekton Chains for OCI storage"

    kubectl patch configmap chains-config -n tekton-chains \
        --type merge \
        -p '{
            "data": {
                "artifacts.oci.storage": "oci",
                "artifacts.pipelinerun.format": "in-toto",
                "artifacts.pipelinerun.storage": "oci",
                "artifacts.taskrun.storage": ""
            }
        }'

    echo_success "Chains configured for OCI storage"
}

# Generate signing keys
setup_signing_keys() {
    echo_step "Setting up signing keys"

    local keys_dir="${ROOT}/setup/keys"
    mkdir -p "${keys_dir}"

    # Check if signing-secrets already exists with keys
    if kubectl -n tekton-chains get secret signing-secrets >/dev/null 2>&1; then
        local existing_key
        existing_key=$(kubectl -n tekton-chains get secret signing-secrets -o jsonpath='{.data.cosign\.key}' 2>/dev/null || echo "")
        if [[ -n "${existing_key}" ]]; then
            echo_info "Signing secrets already exist, skipping key generation"
            return
        fi
    fi

    # Generate cosign keypair if not exists
    if [[ ! -f "${keys_dir}/cosign.key" ]]; then
        echo_info "Generating cosign keypair..."
        COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix="${keys_dir}/cosign"
    else
        echo_info "Using existing cosign keypair from ${keys_dir}"
    fi

    # Delete existing secret if it exists (it might be empty)
    kubectl -n tekton-chains delete secret signing-secrets --ignore-not-found

    # Create signing-secrets secret
    kubectl -n tekton-chains create secret generic signing-secrets \
        --from-file=cosign.key="${keys_dir}/cosign.key" \
        --from-file=cosign.pub="${keys_dir}/cosign.pub" \
        --from-literal=cosign.password=""

    # Restart chains controller to pick up the new keys
    kubectl -n tekton-chains rollout restart deployment tekton-chains-controller
    kubectl -n tekton-chains rollout status deployment tekton-chains-controller --timeout=60s

    echo_success "Signing keys configured"
    echo_info "Public key saved to: ${keys_dir}/cosign.pub"
}

# Create work namespace
setup_work_namespace() {
    echo_step "Setting up work namespace"

    if ! kubectl get namespace "${WORK_NAMESPACE}" >/dev/null 2>&1; then
        kubectl create namespace "${WORK_NAMESPACE}"
    fi

    kubectl config set-context --current --namespace="${WORK_NAMESPACE}"

    echo_success "Work namespace '${WORK_NAMESPACE}' ready"
}

# Print summary
print_summary() {
    echo_step "Setup Complete!"
    echo ""
    echo_info "Cluster:          kind-${KIND_CLUSTER_NAME}"
    echo_info "Tekton Pipelines: ${TEKTON_PIPELINES_VERSION}"
    echo_info "Tekton Chains:    ${TEKTON_CHAINS_VERSION}"
    echo_info "Namespace:        ${WORK_NAMESPACE}"
    echo ""
    echo "Next step:"
    echo "  ./scripts/setup-pipelines.sh"
    echo ""
}

# Main
main() {
    check_prerequisites
    create_cluster
    install_tekton_pipelines
    configure_tekton_features
    install_tekton_chains
    configure_chains
    setup_signing_keys
    setup_work_namespace
    print_summary
}

main "$@"
