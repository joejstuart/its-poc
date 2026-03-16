#!/usr/bin/env bash
# Run the integration test pipeline

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Configuration
NAMESPACE="${NAMESPACE:-work}"
TIMEOUT="${TIMEOUT:-300}"

# Results file from build
RESULTS_FILE="${ROOT}/.build-results"

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

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --image-url URL        Image URL (reads from build results if not specified)"
    echo "  --image-digest DIGEST  Image digest (reads from build results if not specified)"
    echo "  --timeout SECONDS      Timeout in seconds (default: ${TIMEOUT})"
    echo "  -h, --help             Show this help"
    echo ""
    echo "If --image-url and --image-digest are not provided, the script reads"
    echo "from the results of the last build (${RESULTS_FILE})"
}

# Parse arguments
IMAGE_URL=""
IMAGE_DIGEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-url)
            IMAGE_URL="$2"
            shift 2
            ;;
        --image-digest)
            IMAGE_DIGEST="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
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

# Load build results if not provided
load_build_results() {
    if [[ -n "${IMAGE_URL}" ]] && [[ -n "${IMAGE_DIGEST}" ]]; then
        return
    fi

    if [[ ! -f "${RESULTS_FILE}" ]]; then
        echo_error "No build results found and --image-url/--image-digest not provided"
        echo_info "Run ./scripts/run-build.sh first, or provide image details manually"
        exit 1
    fi

    echo_info "Loading build results from ${RESULTS_FILE}"
    source "${RESULTS_FILE}"

    if [[ -z "${IMAGE_URL:-}" ]] || [[ -z "${IMAGE_DIGEST:-}" ]]; then
        echo_error "Build results file is incomplete"
        exit 1
    fi
}

# Wait for a PipelineRun to complete
wait_for_pipelinerun() {
    local name="$1"
    local timeout="$2"
    local start_time=$(date +%s)

    echo_info "Waiting for PipelineRun to complete (timeout: ${timeout}s)..."

    while true; do
        local status
        status=$(kubectl get pipelinerun "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "Unknown")
        local reason
        reason=$(kubectl get pipelinerun "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")

        if [[ "${status}" == "True" ]]; then
            echo ""
            echo_success "PipelineRun completed successfully"
            return 0
        elif [[ "${status}" == "False" ]]; then
            echo ""
            echo_error "PipelineRun failed: ${reason}"
            kubectl get pipelinerun "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[0].message}'
            echo ""
            return 1
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ ${elapsed} -ge ${timeout} ]]; then
            echo ""
            echo_error "Timeout waiting for PipelineRun"
            return 1
        fi

        echo -n "."
        sleep 5
    done
}

# Wait for Chains to sign
wait_for_chains() {
    local name="$1"
    local timeout=120
    local start_time=$(date +%s)

    echo_info "Waiting for Tekton Chains to sign..."

    while true; do
        local signed
        signed=$(kubectl get pipelinerun "${name}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null || echo "")

        if [[ "${signed}" == "true" ]]; then
            echo ""
            echo_success "Signed by Tekton Chains"
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ ${elapsed} -ge ${timeout} ]]; then
            echo ""
            echo_info "Chains signing timeout (may still be processing)"
            return 0
        fi

        echo -n "."
        sleep 5
    done
}

# Setup cosign keys secret for attestation signing
setup_cosign_keys() {
    local keys_dir="${ROOT}/setup/keys"

    if [[ ! -f "${keys_dir}/cosign.key" ]]; then
        echo_error "Cosign keys not found at ${keys_dir}"
        echo_info "Run ./setup/setup-cluster.sh to generate signing keys"
        exit 1
    fi

    # Create or update the cosign-keys secret
    kubectl create secret generic cosign-keys \
        --from-file=cosign.key="${keys_dir}/cosign.key" \
        --from-file=cosign.pub="${keys_dir}/cosign.pub" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo_success "Cosign keys secret configured"
}

# Run the integration test
run_integration_test() {
    echo_step "Running integration test pipeline"
    echo_info "IMAGE_URL:    ${IMAGE_URL}"
    echo_info "IMAGE_DIGEST: ${IMAGE_DIGEST}"

    # Setup cosign keys for attestation signing (required)
    setup_cosign_keys

    local pipelinerun_name
    pipelinerun_name=$(kubectl create -f - -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: integration-test-
spec:
  pipelineRef:
    name: integration-test-pipeline
  params:
    - name: IMAGE_URL
      value: "${IMAGE_URL}"
    - name: IMAGE_DIGEST
      value: "${IMAGE_DIGEST}"
  workspaces:
    - name: cosign-keys
      secret:
        secretName: cosign-keys
    - name: dockerconfig
      secret:
        secretName: docker-credentials
EOF
)

    echo_info "Created PipelineRun: ${pipelinerun_name}"
    echo_info "Watch logs: kubectl logs -f -l tekton.dev/pipelineRun=${pipelinerun_name} -n ${NAMESPACE}"

    wait_for_pipelinerun "${pipelinerun_name}" "${TIMEOUT}"

    # Extract results
    TEST_OUTPUT=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="TEST_OUTPUT")].value}')
    PASSED=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="PASSED")].value}')
    ARTIFACT_OUTPUT=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="TEST_OUTPUT_ARTIFACT_OUTPUTS")].value}')

    echo_step "Test Results"
    echo "PipelineRun: ${pipelinerun_name}"
    echo "PASSED:      ${PASSED}"
    if [[ -n "${ARTIFACT_OUTPUT}" ]]; then
        echo "ATTESTATION: ${ARTIFACT_OUTPUT}"
    fi
    echo ""
    echo "TEST_OUTPUT:"
    echo "${TEST_OUTPUT}" | jq '.' 2>/dev/null || echo "${TEST_OUTPUT}"

    # Wait for Chains
    wait_for_chains "${pipelinerun_name}"

    echo_step "Integration Test Complete!"
    echo ""
    echo "The integration test pipeline has run and Tekton Chains has"
    echo "generated an attestation for it."
    echo ""
    echo "Verify attestations:"
    echo "  ./scripts/verify-attestations.sh ${IMAGE_URL}@${IMAGE_DIGEST}"
}

main() {
    load_build_results
    run_integration_test
}

main "$@"
