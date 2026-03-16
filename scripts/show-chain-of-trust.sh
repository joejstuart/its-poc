#!/usr/bin/env bash
# Show the chain of trust for an image and its attestations

set -o errexit
set -o pipefail
set -o nounset

# Colors
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

# Default image or use argument
IMAGE="${1:-}"

if [[ -z "${IMAGE}" ]]; then
    # Try to load from build results
    RESULTS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/.build-results"
    if [[ -f "${RESULTS_FILE}" ]]; then
        source "${RESULTS_FILE}"
        IMAGE="${IMAGE_URL}@${IMAGE_DIGEST}"
    else
        echo "Usage: $0 <image@digest>"
        echo ""
        echo "Example: $0 quay.io/myrepo/myimage@sha256:abc123..."
        exit 1
    fi
fi

# Extract components
IMAGE_URL="${IMAGE%%@*}"
IMAGE_DIGEST="${IMAGE##*@}"
SHORT_DIGEST="${IMAGE_DIGEST:7:12}"

header() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  CHAIN OF TRUST VISUALIZATION                                         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Collect all attestation data
collect_attestations() {
    section "1. COLLECTING ATTESTATIONS"

    echo -e "${CYAN}Image:${NC} ${IMAGE}"
    echo ""

    # Get legacy attestations (Chains)
    echo -e "${YELLOW}Fetching legacy attestations (.att tag)...${NC}"
    LEGACY_ATTESTATIONS=$(cosign download attestation "${IMAGE}" 2>/dev/null || echo "")
    LEGACY_COUNT=$(echo "${LEGACY_ATTESTATIONS}" | grep -c "payload" || echo "0")
    echo -e "  Found: ${GREEN}${LEGACY_COUNT}${NC} attestation(s)"

    # Get bundle attestations (OCI Referrers)
    echo ""
    echo -e "${YELLOW}Fetching OCI referrer attestations (bundle format)...${NC}"
    BUNDLE_DIGESTS=$(oras discover -o json "${IMAGE}" 2>/dev/null | \
        jq -r '.manifests[]? | select(.artifactType | contains("sigstore")) | .digest' || echo "")
    BUNDLE_COUNT=$(echo "${BUNDLE_DIGESTS}" | grep -c "sha256" || echo "0")
    echo -e "  Found: ${GREEN}${BUNDLE_COUNT}${NC} attestation(s)"
}

# Show the chain
show_chain() {
    section "2. CHAIN OF TRUST DIAGRAM"

    # Get attestation details
    local att_digest=""
    local att_short=""
    local has_provenance_on_att="no"

    if [[ -n "${BUNDLE_DIGESTS}" ]]; then
        att_digest=$(echo "${BUNDLE_DIGESTS}" | head -1)
        att_short="${att_digest:7:12}"

        # Check if there's a Chains attestation on the bundle attestation
        if cosign download attestation "${IMAGE_URL}@${att_digest}" >/dev/null 2>&1; then
            has_provenance_on_att="yes"
        fi
    fi

    echo -e "${WHITE}"
    cat << EOF
    ┌─────────────────────────────────────────────────────────────────┐
    │                     CONTAINER IMAGE                             │
    │                                                                 │
    │  ${IMAGE_URL}
    │  ${IMAGE_DIGEST}
    │                                                                 │
    └─────────────────────────────┬───────────────────────────────────┘
                                  │
            ┌─────────────────────┴─────────────────────┐
            │                                           │
            ▼                                           ▼
EOF
    echo -e "${NC}"

    # Left side - Build provenance
    echo -e "${CYAN}  ┌───────────────────────────┐     ${MAGENTA}┌───────────────────────────┐${NC}"
    echo -e "${CYAN}  │   SLSA PROVENANCE         │     ${MAGENTA}│   TEST-RESULT             │${NC}"
    echo -e "${CYAN}  │   (Build Pipeline)        │     ${MAGENTA}│   ATTESTATION             │${NC}"
    echo -e "${CYAN}  │                           │     ${MAGENTA}│                           │${NC}"
    if [[ -n "${att_digest}" ]]; then
        echo -e "${CYAN}  │   Subject: IMAGE          │     ${MAGENTA}│   ${att_short}...            │${NC}"
    else
        echo -e "${CYAN}  │   Subject: IMAGE          │     ${MAGENTA}│   (none found)            │${NC}"
    fi
    echo -e "${CYAN}  │   Signer: Tekton Chains   │     ${MAGENTA}│   Subject: IMAGE          │${NC}"
    echo -e "${CYAN}  │   Storage: .att tag       │     ${MAGENTA}│   Signer: cosign (task)   │${NC}"
    echo -e "${CYAN}  │                           │     ${MAGENTA}│   Storage: OCI Referrers  │${NC}"
    echo -e "${CYAN}  └───────────────────────────┘     ${MAGENTA}└─────────────┬─────────────┘${NC}"

    if [[ "${has_provenance_on_att}" == "yes" ]]; then
        echo -e "                                                        │"
        echo -e "                                                        │ ${DIM}ARTIFACT_OUTPUTS${NC}"
        echo -e "                                                        │ ${DIM}pointed here${NC}"
        echo -e "                                                        ▼"
        echo -e "                                      ${YELLOW}┌───────────────────────────┐${NC}"
        echo -e "                                      ${YELLOW}│   SLSA PROVENANCE         │${NC}"
        echo -e "                                      ${YELLOW}│   (Integration Pipeline)  │${NC}"
        echo -e "                                      ${YELLOW}│                           │${NC}"
        echo -e "                                      ${YELLOW}│   Subject: ATTESTATION    │${NC}"
        echo -e "                                      ${YELLOW}│   ${att_short}...            │${NC}"
        echo -e "                                      ${YELLOW}│                           │${NC}"
        echo -e "                                      ${YELLOW}│   Signer: Tekton Chains   │${NC}"
        echo -e "                                      ${YELLOW}│   Storage: .att tag       │${NC}"
        echo -e "                                      ${YELLOW}└───────────────────────────┘${NC}"
    fi
    echo ""
}

# Show detailed attestation info
show_details() {
    section "3. ATTESTATION DETAILS"

    echo -e "${CYAN}A. Build Pipeline Provenance (on image)${NC}"
    echo -e "${DIM}   Subject: ${IMAGE_DIGEST}${NC}"
    echo ""

    if [[ -n "${LEGACY_ATTESTATIONS}" ]]; then
        echo "${LEGACY_ATTESTATIONS}" | head -1 | jq -r '.payload' | base64 -d | jq '{
            predicateType,
            "subject[0].digest": .subject[0].digest,
            "buildType": .predicate.buildType,
            "pipeline": .predicate.invocation.environment.labels["tekton.dev/pipeline"]
        }' 2>/dev/null || echo "  (could not decode)"
    fi

    echo ""
    echo -e "${MAGENTA}B. Test-Result Attestation (on image, via OCI Referrers)${NC}"

    if [[ -n "${BUNDLE_DIGESTS}" ]]; then
        local att_digest=$(echo "${BUNDLE_DIGESTS}" | head -1)
        echo -e "${DIM}   Attestation digest: ${att_digest}${NC}"
        echo ""

        local layer_digest=$(oras manifest fetch "${IMAGE_URL}@${att_digest}" 2>/dev/null | jq -r '.layers[0].digest')
        oras blob fetch "${IMAGE_URL}@${layer_digest}" --output - 2>/dev/null | jq '{
            mediaType,
            "predicateType": (.dsseEnvelope.payload | @base64d | fromjson | .predicateType),
            "subject": (.dsseEnvelope.payload | @base64d | fromjson | .subject[0].digest),
            "result": (.dsseEnvelope.payload | @base64d | fromjson | .predicate.result),
            "passedTests": (.dsseEnvelope.payload | @base64d | fromjson | .predicate.passedTests)
        }' 2>/dev/null || echo "  (could not decode)"

        # Check for provenance on the attestation
        echo ""
        echo -e "${YELLOW}C. Integration Pipeline Provenance (on attestation)${NC}"
        echo -e "${DIM}   Subject: ${att_digest}${NC}"
        echo ""

        local att_provenance=$(cosign download attestation "${IMAGE_URL}@${att_digest}" 2>/dev/null | head -1 || echo "")
        if [[ -n "${att_provenance}" ]]; then
            echo "${att_provenance}" | jq -r '.payload' | base64 -d | jq '{
                predicateType,
                "subject[0].digest": .subject[0].digest,
                "buildType": .predicate.buildType,
                "pipeline": .predicate.invocation.environment.labels["tekton.dev/pipeline"],
                "ARTIFACT_OUTPUTS": .predicate.buildConfig.tasks[0].results[] | select(.name == "TEST_OUTPUT_ARTIFACT_OUTPUTS") | .value
            }' 2>/dev/null || echo "  (could not decode)"

            echo ""
            echo -e "${GREEN}✓ Chain of trust complete!${NC}"
            echo -e "  The attestation has its own SLSA provenance proving it was"
            echo -e "  created by a specific Tekton pipeline run."
        else
            echo -e "  ${DIM}(no provenance found on attestation)${NC}"
        fi
    else
        echo "  (no bundle attestations found)"
    fi
}

# Explain the chain
explain_chain() {
    section "4. HOW THE CHAIN WORKS"

    cat << 'EOF'
The chain of trust works as follows:

1. BUILD PIPELINE runs and produces a container image
   → Tekton Chains generates SLSA Provenance for the image
   → Proves: who built it, from what source, with what tools

2. INTEGRATION TEST PIPELINE runs against the built image
   → Task creates a test-result attestation (in-toto format)
   → Task signs it with cosign and pushes to registry
   → Task outputs ARTIFACT_OUTPUTS with the attestation's digest

3. CHAINS SEES ARTIFACT_OUTPUTS
   → Generates SLSA Provenance with subject = attestation digest
   → This provenance proves the attestation was created by the pipeline
   → Stored as .att tag on the attestation artifact

VERIFICATION:
- To trust the image: verify build provenance signature
- To trust test results: verify test-result attestation signature
- To trust test attestation origin: verify integration provenance signature

All three form a complete chain of trust from source to verified test results.
EOF
}

# Main
header
collect_attestations
show_chain
show_details
explain_chain

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Demo complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════════${NC}"
echo ""
