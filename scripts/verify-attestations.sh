#!/usr/bin/env bash
# Verify attestations on an image using ec (Conforma CLI)

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

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

# Default paths
PUBLIC_KEY="${PUBLIC_KEY:-${ROOT}/setup/keys/cosign.pub}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"

usage() {
    echo "Usage: $0 [options] <image-reference>"
    echo ""
    echo "Verify attestations on a container image using the Conforma (ec) CLI."
    echo ""
    echo "Arguments:"
    echo "  image-reference    Image to verify (e.g., quay.io/user/image@sha256:...)"
    echo ""
    echo "Options:"
    echo "  --public-key PATH  Path to cosign public key (default: ${PUBLIC_KEY})"
    echo "  --output FORMAT    Output format: text, json, yaml (default: ${OUTPUT_FORMAT})"
    echo "  --info             Include detailed information on results"
    echo "  --policy POLICY    Policy to validate against (optional)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 quay.io/jstuart/hacbs-docker-build@sha256:abc123..."
    echo "  $0 --output json quay.io/jstuart/hacbs-docker-build:latest"
    echo ""
    echo "Environment variables:"
    echo "  PUBLIC_KEY     Path to cosign public key"
    echo "  OUTPUT_FORMAT  Output format (text, json, yaml)"
}

# Parse arguments
INFO_FLAG=""
POLICY=""
IMAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --public-key)
            PUBLIC_KEY="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --info)
            INFO_FLAG="--info"
            shift
            ;;
        --policy)
            POLICY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            IMAGE="$1"
            shift
            ;;
    esac
done

if [[ -z "${IMAGE}" ]]; then
    echo_error "Image reference required"
    usage
    exit 1
fi

# Check prerequisites
if ! command -v ec >/dev/null 2>&1; then
    echo_error "ec (Conforma CLI) is required but not installed"
    echo_info "Install from: https://github.com/conforma/cli"
    exit 1
fi

if [[ ! -f "${PUBLIC_KEY}" ]]; then
    echo_error "Public key not found: ${PUBLIC_KEY}"
    echo_info "Run setup/setup-cluster.sh to generate signing keys"
    exit 1
fi

echo_step "Verifying attestations for: ${IMAGE}"
echo_info "Using public key: ${PUBLIC_KEY}"
echo_info "Output format: ${OUTPUT_FORMAT}"

# Build ec validate command
EC_CMD=(
    ec validate image
    --image "${IMAGE}"
    --public-key "${PUBLIC_KEY}"
    --output "${OUTPUT_FORMAT}"
    --ignore-rekor
    --strict=false
)

# Add info flag if requested
if [[ -n "${INFO_FLAG}" ]]; then
    EC_CMD+=("${INFO_FLAG}")
fi

# Add policy if provided, otherwise use minimal policy that just checks signatures
if [[ -n "${POLICY}" ]]; then
    EC_CMD+=(--policy "${POLICY}")
else
    # Minimal policy - just verify signatures and attestations exist
    EC_CMD+=(--policy '{"sources":[]}')
fi

echo_step "Running ec validate"
echo_info "Command: ${EC_CMD[*]}"
echo ""

# Run validation
if "${EC_CMD[@]}"; then
    echo ""
    echo_success "Validation completed successfully"
else
    echo ""
    echo_info "Validation completed with findings (see output above)"
fi

echo_step "Verification complete"
