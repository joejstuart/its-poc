#!/usr/bin/env bash
# Attestation helper functions
# Source this file: source scripts/attestation-functions.sh

# Download all attestations for an image (both legacy .att and OCI referrers)
# Usage: download-all-attestations <image@digest>
download-all-attestations() {
  local image="$1"

  if [[ -z "$image" ]]; then
    echo "Usage: download-all-attestations <image@digest>" >&2
    return 1
  fi

  echo "# Legacy attestations (.att tag)" >&2
  cosign download attestation "$image" 2>/dev/null | while read -r line; do
    echo "$line" | jq -r '.payload' | base64 -d | jq -c '{
      source: "chains",
      predicateType: .predicateType,
      statement: .
    }'
  done

  echo "# OCI Referrers (sigstore bundles)" >&2
  oras discover -o json "$image" 2>/dev/null | jq -r '.manifests[]? | select(.artifactType | contains("sigstore")) | .digest' | while read -r digest; do
    local layer_digest
    layer_digest=$(oras manifest fetch "${image%%@*}@${digest}" 2>/dev/null | jq -r '.layers[0].digest')
    oras blob fetch "${image%%@*}@${layer_digest}" --output - 2>/dev/null | jq -c '{
      source: "bundle",
      predicateType: (.dsseEnvelope.payload | @base64d | fromjson | .predicateType),
      statement: (.dsseEnvelope.payload | @base64d | fromjson)
    }'
  done
}

# List attestation types attached to an image
# Usage: list-attestation-types <image@digest>
list-attestation-types() {
  local image="$1"

  if [[ -z "$image" ]]; then
    echo "Usage: list-attestation-types <image@digest>" >&2
    return 1
  fi

  echo "Attestation types for: $image"
  echo ""

  echo "Legacy (.att tag):"
  cosign download attestation "$image" 2>/dev/null | while read -r line; do
    local ptype
    ptype=$(echo "$line" | jq -r '.payload' | base64 -d | jq -r '.predicateType')
    echo "  - $ptype"
  done | sort | uniq -c

  echo ""
  echo "OCI Referrers (bundles):"
  oras discover -o json "$image" 2>/dev/null | jq -r '.manifests[]? | select(.artifactType | contains("sigstore")) | .digest' | while read -r digest; do
    local ptype
    ptype=$(oras manifest fetch "${image%%@*}@${digest}" 2>/dev/null | jq -r '.annotations["dev.sigstore.bundle.predicateType"] // "unknown"')
    echo "  - $ptype"
  done | sort | uniq -c
}

# Download only sigstore bundle attestations (OCI Referrers)
# Usage: download-bundle-attestations <image@digest>
download-bundle-attestations() {
  local image="$1"

  if [[ -z "$image" ]]; then
    echo "Usage: download-bundle-attestations <image@digest>" >&2
    return 1
  fi

  oras discover -o json "$image" 2>/dev/null | jq -r '.manifests[]? | select(.artifactType | contains("sigstore")) | .digest' | while read -r digest; do
    local layer_digest
    layer_digest=$(oras manifest fetch "${image%%@*}@${digest}" 2>/dev/null | jq -r '.layers[0].digest')
    oras blob fetch "${image%%@*}@${layer_digest}" --output - 2>/dev/null | jq '.'
  done
}
