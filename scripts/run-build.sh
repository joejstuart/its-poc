#!/usr/bin/env bash
# Run the build pipeline

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Configuration
NAMESPACE="${NAMESPACE:-work}"
TIMEOUT="${TIMEOUT:-600}"
REPO_URL="${REPO_URL:-https://github.com/joejstuart/hacbs-docker-build.git}"
IMAGE_REF="${IMAGE_REF:-quay.io/jstuart/hacbs-docker-build}"
DOCKERFILE="${DOCKERFILE:-./image_with_labels/Dockerfile}"

# Output file to store results for integration test
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
    echo "  --repo-url URL       Git repository URL (default: ${REPO_URL})"
    echo "  --image-ref REF      Image reference to push to (default: ${IMAGE_REF})"
    echo "  --dockerfile PATH    Dockerfile path (default: ${DOCKERFILE})"
    echo "  --timeout SECONDS    Timeout in seconds (default: ${TIMEOUT})"
    echo "  -h, --help           Show this help"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-url)
            REPO_URL="$2"
            shift 2
            ;;
        --image-ref)
            IMAGE_REF="$2"
            shift 2
            ;;
        --dockerfile)
            DOCKERFILE="$2"
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

# Run the build
run_build() {
    echo_step "Running build pipeline"
    echo_info "Repository: ${REPO_URL}"
    echo_info "Image:      ${IMAGE_REF}"
    echo_info "Dockerfile: ${DOCKERFILE}"

    local pipelinerun_name
    pipelinerun_name=$(kubectl create -f - -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: build-
spec:
  pipelineRef:
    name: clone-build-push
  workspaces:
    - name: shared-data
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1Gi
    - name: docker-credentials
      secret:
        secretName: docker-credentials
  params:
    - name: repo-url
      value: "${REPO_URL}"
    - name: image-reference
      value: "${IMAGE_REF}"
    - name: DOCKERFILE
      value: "${DOCKERFILE}"
EOF
)

    echo_info "Created PipelineRun: ${pipelinerun_name}"
    echo_info "Watch logs: kubectl logs -f -l tekton.dev/pipelineRun=${pipelinerun_name} -n ${NAMESPACE}"

    wait_for_pipelinerun "${pipelinerun_name}" "${TIMEOUT}"

    # Extract results
    IMAGE_URL=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
    IMAGE_DIGEST=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

    echo_step "Build Results"
    echo "PipelineRun: ${pipelinerun_name}"
    echo "IMAGE_URL:   ${IMAGE_URL}"
    echo "IMAGE_DIGEST: ${IMAGE_DIGEST}"

    # Save results for integration test
    cat > "${RESULTS_FILE}" <<EOF
PIPELINERUN_NAME=${pipelinerun_name}
IMAGE_URL=${IMAGE_URL}
IMAGE_DIGEST=${IMAGE_DIGEST}
EOF

    echo_info "Results saved to ${RESULTS_FILE}"

    # Wait for Chains
    wait_for_chains "${pipelinerun_name}"

    echo_step "Build Complete!"
    echo ""
    echo "Image: ${IMAGE_URL}@${IMAGE_DIGEST}"
    echo ""
    echo "Next step:"
    echo "  ./scripts/run-integration-test.sh"
}

main() {
    run_build
}

main "$@"
