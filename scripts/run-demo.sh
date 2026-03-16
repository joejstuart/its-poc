#!/usr/bin/env bash
# Run the full demo: build pipeline -> integration test pipeline

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Configuration
NAMESPACE="${NAMESPACE:-work}"
TIMEOUT="${TIMEOUT:-600}"

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

# Wait for a PipelineRun to complete
wait_for_pipelinerun() {
    local name="$1"
    local timeout="$2"
    local start_time=$(date +%s)

    echo_info "Waiting for PipelineRun ${name} to complete (timeout: ${timeout}s)..."

    while true; do
        local status
        status=$(kubectl get pipelinerun "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "Unknown")
        local reason
        reason=$(kubectl get pipelinerun "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || echo "Unknown")

        if [[ "${status}" == "True" ]]; then
            echo_success "PipelineRun ${name} completed successfully"
            return 0
        elif [[ "${status}" == "False" ]]; then
            echo_error "PipelineRun ${name} failed: ${reason}"
            kubectl get pipelinerun "${name}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[0].message}'
            echo ""
            return 1
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ ${elapsed} -ge ${timeout} ]]; then
            echo_error "Timeout waiting for PipelineRun ${name}"
            return 1
        fi

        echo -n "."
        sleep 5
    done
}

# Install pipeline resources
setup_pipelines() {
    echo_step "Setting up pipeline resources"

    # Ensure namespace exists
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

    # Apply tasks and pipelines
    kubectl apply -f "${ROOT}/pipelines/git-clone.yaml" -n "${NAMESPACE}"
    kubectl apply -f "https://api.hub.tekton.dev/v1/resource/tekton/task/buildah/0.8/raw" -n "${NAMESPACE}"
    kubectl apply -f "${ROOT}/pipelines/pipeline.yaml" -n "${NAMESPACE}"
    kubectl apply -f "${ROOT}/pipelines/integration-test-task.yaml" -n "${NAMESPACE}"
    kubectl apply -f "${ROOT}/pipelines/integration-test-pipeline.yaml" -n "${NAMESPACE}"

    echo_success "Pipeline resources installed"
}

# Check if registry credentials exist
check_credentials() {
    echo_step "Checking registry credentials"

    if ! kubectl get secret docker-credentials -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo_error "Secret 'docker-credentials' not found in namespace '${NAMESPACE}'"
        echo_info "Create it with:"
        echo_info "  kubectl create secret generic docker-credentials \\"
        echo_info "    --from-file=config.json=<path-to-docker-config> \\"
        echo_info "    -n ${NAMESPACE}"
        exit 1
    fi

    echo_success "Registry credentials found"
}

# Run the build pipeline
run_build_pipeline() {
    echo_step "Running build pipeline"

    local pipelinerun_name
    pipelinerun_name=$(kubectl create -f - -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: demo-build-
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
      value: "https://github.com/joejstuart/hacbs-docker-build.git"
    - name: image-reference
      value: "quay.io/jstuart/hacbs-docker-build"
    - name: DOCKERFILE
      value: "./image_with_labels/Dockerfile"
EOF
)

    echo_info "Created PipelineRun: ${pipelinerun_name}"
    wait_for_pipelinerun "${pipelinerun_name}" "${TIMEOUT}"

    # Extract results
    IMAGE_URL=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="IMAGE_URL")].value}')
    IMAGE_DIGEST=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="IMAGE_DIGEST")].value}')

    echo_success "Build completed"
    echo_info "IMAGE_URL: ${IMAGE_URL}"
    echo_info "IMAGE_DIGEST: ${IMAGE_DIGEST}"

    # Export for next step
    export BUILD_PIPELINERUN="${pipelinerun_name}"
    export IMAGE_URL
    export IMAGE_DIGEST
}

# Wait for Chains to sign the build
wait_for_chains_signature() {
    echo_step "Waiting for Tekton Chains to sign the build"

    local pipelinerun_name="$1"
    local timeout=120
    local start_time=$(date +%s)

    while true; do
        local signed
        signed=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}' 2>/dev/null || echo "")

        if [[ "${signed}" == "true" ]]; then
            echo_success "PipelineRun signed by Tekton Chains"
            return 0
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [[ ${elapsed} -ge ${timeout} ]]; then
            echo_info "Timeout waiting for Chains signature (this may be normal if Chains is still processing)"
            return 0
        fi

        echo -n "."
        sleep 5
    done
}

# Run the integration test pipeline
run_integration_test_pipeline() {
    echo_step "Running integration test pipeline"

    if [[ -z "${IMAGE_URL:-}" ]] || [[ -z "${IMAGE_DIGEST:-}" ]]; then
        echo_error "IMAGE_URL and IMAGE_DIGEST must be set"
        exit 1
    fi

    local pipelinerun_name
    pipelinerun_name=$(kubectl create -f - -n "${NAMESPACE}" -o jsonpath='{.metadata.name}' <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: demo-integration-test-
spec:
  pipelineRef:
    name: integration-test-pipeline
  params:
    - name: IMAGE_URL
      value: "${IMAGE_URL}"
    - name: IMAGE_DIGEST
      value: "${IMAGE_DIGEST}"
EOF
)

    echo_info "Created PipelineRun: ${pipelinerun_name}"
    wait_for_pipelinerun "${pipelinerun_name}" "${TIMEOUT}"

    # Show test results
    TEST_OUTPUT=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="TEST_OUTPUT")].value}')
    PASSED=$(kubectl get pipelinerun "${pipelinerun_name}" -n "${NAMESPACE}" -o jsonpath='{.status.results[?(@.name=="PASSED")].value}')

    echo_success "Integration test completed"
    echo_info "PASSED: ${PASSED}"
    echo_info "TEST_OUTPUT: ${TEST_OUTPUT}"

    export INTEGRATION_PIPELINERUN="${pipelinerun_name}"
}

# Print summary
print_summary() {
    echo_step "Demo Complete!"
    echo ""
    echo "Build PipelineRun:       ${BUILD_PIPELINERUN}"
    echo "Integration PipelineRun: ${INTEGRATION_PIPELINERUN}"
    echo "Image:                   ${IMAGE_URL}@${IMAGE_DIGEST}"
    echo ""
    echo "Next steps:"
    echo "  1. Verify attestations: ./scripts/verify-attestations.sh ${IMAGE_URL}@${IMAGE_DIGEST}"
    echo "  2. View PipelineRun:    kubectl get pipelinerun -n ${NAMESPACE}"
    echo "  3. Cleanup:             ./scripts/cleanup.sh"
    echo ""
}

# Main
main() {
    echo_step "Starting Demo: Attestable Build-Time Tests"

    setup_pipelines
    check_credentials
    run_build_pipeline
    wait_for_chains_signature "${BUILD_PIPELINERUN}"
    run_integration_test_pipeline
    wait_for_chains_signature "${INTEGRATION_PIPELINERUN}"
    print_summary
}

main "$@"
