#!/usr/bin/env bash
# Demonstrate how attestations are stored and signed on an OCI image

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PUBLIC_KEY="${ROOT}/setup/keys/cosign.pub"

# Colors
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

section() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

subsection() {
    echo ""
    echo -e "${YELLOW}>>> $1${NC}"
    echo ""
}

info() {
    echo -e "${CYAN}$1${NC}"
}

# Default image or use argument
IMAGE="${1:-quay.io/jstuart/hacbs-docker-build@sha256:638b87bf8efa450ca83e63191243bfb3c6a87294a53effc36706ed60882e47ea}"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     ATTESTATION STORAGE AND SIGNING DEMONSTRATION             ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Image: ${IMAGE}"
info "Public Key: ${PUBLIC_KEY}"

# ============================================================================
section "1. ATTESTATION TREE STRUCTURE"
# ============================================================================

info "Attestations are stored as OCI artifacts attached to the image using"
info "the OCI Referrers API. Each attestation is a separate artifact."
echo ""

echo "$ cosign tree ${IMAGE}"
echo ""
cosign tree "${IMAGE}" 2>/dev/null || true

subsection "Explanation"
cat << 'EOF'
- 💾 Attestations are stored at: <image>:sha256-<digest>.att
- 🔐 Signatures are stored at: <image>:sha256-<digest>.sig
- Each 🍒 is a separate attestation with its own digest
- Attestations and signatures are linked to the image via OCI referrers
EOF

# ============================================================================
section "2. LIST ATTESTATION TYPES"
# ============================================================================

info "Each attestation has a predicateType that identifies what it contains."
echo ""

echo "$ cosign download attestation ${IMAGE} | jq -r '.payload' | base64 -d | jq '{predicateType}'"
echo ""

cosign download attestation "${IMAGE}" 2>/dev/null | while read -r line; do
    predicate_type=$(echo "${line}" | jq -r '.payload' | base64 -d | jq -r '.predicateType' 2>/dev/null || echo "unknown")
    echo "  - ${predicate_type}"
done | sort | uniq -c

subsection "Common predicate types"
cat << 'EOF'
- https://slsa.dev/provenance/v0.2     - SLSA Provenance (build info)
- https://in-toto.io/attestation/test-result/v0.1 - Test results
- https://in-toto.io/attestation/vuln/v0.1        - Vulnerability scans
EOF

# ============================================================================
section "3. ATTESTATION ENVELOPE STRUCTURE (DSSE)"
# ============================================================================

info "Each attestation is wrapped in a DSSE (Dead Simple Signing Envelope)."
info "The envelope contains the payload and its signature(s)."
echo ""

echo "$ cosign download attestation ${IMAGE} | head -1 | jq 'keys'"
echo ""
cosign download attestation "${IMAGE}" 2>/dev/null | head -1 | jq 'keys'

echo ""
echo "Structure:"
cosign download attestation "${IMAGE}" 2>/dev/null | head -1 | jq '{
  payloadType: .payloadType,
  payload: (.payload | length | tostring + " bytes (base64 encoded)"),
  signatures: [.signatures[] | {keyid, sig: (.sig | .[0:20] + "...")}]
}'

subsection "Explanation"
cat << 'EOF'
- payloadType: "application/vnd.in-toto+json" (in-toto statement)
- payload: Base64-encoded in-toto statement (the actual attestation)
- signatures: Array of signatures over the payload
  - keyid: Identifier for the signing key (may be empty)
  - sig: The cryptographic signature (base64 encoded)
EOF

# ============================================================================
section "4. DECODED ATTESTATION PAYLOAD"
# ============================================================================

info "The payload is an in-toto Statement with subject and predicate."
echo ""

echo "$ cosign download attestation ${IMAGE} | head -1 | jq -r '.payload' | base64 -d | jq"
echo ""
cosign download attestation "${IMAGE}" 2>/dev/null | head -1 | jq -r '.payload' | base64 -d | jq '{
  _type,
  subject: .subject,
  predicateType,
  "predicate (truncated)": (.predicate | keys)
}'

subsection "Explanation"
cat << 'EOF'
- _type: "https://in-toto.io/Statement/v0.1" (in-toto statement version)
- subject: The artifact(s) this attestation is about (image + digest)
- predicateType: What kind of attestation this is
- predicate: The actual attestation content (varies by type)
EOF

# ============================================================================
section "5. SIGNATURE VERIFICATION"
# ============================================================================

info "Cosign verifies each attestation's signature against the public key."
info "Each attestation is verified independently."
echo ""

subsection "Verify SLSA Provenance attestations"
echo "$ cosign verify-attestation --key cosign.pub --type slsaprovenance --insecure-ignore-tlog ${IMAGE}"
echo ""
if cosign verify-attestation --key "${PUBLIC_KEY}" --type slsaprovenance --insecure-ignore-tlog "${IMAGE}" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ SLSA Provenance attestations verified successfully${NC}"
    count=$(cosign verify-attestation --key "${PUBLIC_KEY}" --type slsaprovenance --insecure-ignore-tlog "${IMAGE}" 2>/dev/null | wc -l)
    echo "  (${count} attestations verified)"
else
    echo "✗ Verification failed"
fi

subsection "Verify Test Result attestations"
echo "$ cosign verify-attestation --key cosign.pub --type 'https://in-toto.io/attestation/test-result/v0.1' --insecure-ignore-tlog ${IMAGE}"
echo ""
if cosign verify-attestation --key "${PUBLIC_KEY}" --type "https://in-toto.io/attestation/test-result/v0.1" --insecure-ignore-tlog "${IMAGE}" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Test Result attestations verified successfully${NC}"
    count=$(cosign verify-attestation --key "${PUBLIC_KEY}" --type "https://in-toto.io/attestation/test-result/v0.1" --insecure-ignore-tlog "${IMAGE}" 2>/dev/null | wc -l)
    echo "  (${count} attestations verified)"
else
    echo "✗ Verification failed"
fi

subsection "Explanation"
cat << 'EOF'
- --key: Public key to verify signatures against
- --type: Filter attestations by predicate type
- --insecure-ignore-tlog: Skip transparency log check (for local keys)

Verification checks:
1. Signature is valid for the payload
2. Payload subject matches the image digest
3. (If using Rekor) Entry exists in transparency log
EOF

# ============================================================================
section "6. WHO SIGNED WHAT?"
# ============================================================================

info "In this demo, there are two signers:"
echo ""

cat << EOF
┌─────────────────────────────────────────────────────────────────┐
│  SIGNER                 │  ATTESTATION TYPE                    │
├─────────────────────────────────────────────────────────────────┤
│  Integration Test Task  │  test-result/v0.1 (cosign attest)    │
│  (using cosign)         │  - Pushed by the task itself         │
│                         │  - Signed with setup/keys/cosign.key │
├─────────────────────────────────────────────────────────────────┤
│  Tekton Chains          │  slsa provenance/v0.2                │
│  (automatic)            │  - TaskRun provenance                │
│                         │  - PipelineRun provenance            │
│                         │  - Signed with Chains signing key    │
└─────────────────────────────────────────────────────────────────┘
EOF

# ============================================================================
section "7. SUMMARY"
# ============================================================================

cat << 'EOF'
KEY CONCEPTS:

1. STORAGE: Attestations are OCI artifacts attached to images via referrers
   - Each attestation has its own digest
   - Stored at <image>:sha256-<digest>.att

2. ENVELOPE: Each attestation is wrapped in DSSE format
   - payloadType + payload + signatures
   - Multiple signatures possible per attestation

3. PAYLOAD: In-toto Statement format
   - subject: what artifact this is about
   - predicateType: what kind of attestation
   - predicate: the actual content

4. VERIFICATION: Each attestation verified independently
   - Signature must match public key
   - Subject must match image digest
   - Can filter by predicate type

5. MULTIPLE ATTESTATIONS: Same image can have many attestations
   - Different types (provenance, test results, vulnerabilities)
   - Different signers (Chains, tasks, external tools)
   - All coexist as separate OCI artifacts
EOF

echo ""
echo -e "${GREEN}Demo complete!${NC}"
