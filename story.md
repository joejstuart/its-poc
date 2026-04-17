# Stories for In-Toto Statement Verification via OCI Referrers

## Background

Test tasks can create in-toto statements (e.g., test-result attestations) and attach them to images using `oras attach`. These statements are **unsigned** - trust is established by verifying the SLSA provenance that Tekton Chains creates for the statement itself.

The chain of trust:
1. Image has SLSA provenance (proves build origin)
2. Image has in-toto statement attached (contains test results)
3. The in-toto statement has its own SLSA provenance (proves statement origin)

Verification requires checking that the statement's provenance shows it was created by a trusted pipeline.

---

## Story 1: Fetch In-Toto Statements from OCI Referrers

### Summary

Add capability to discover and fetch unsigned in-toto statements attached to an image as OCI referrers.

### Status

**Partially implemented** - PR #3169 adds `ec.oci.image_referrers()` which provides referrer discovery. Additional helper function may be useful for fetching statement content.

### Existing Capability (PR #3169)

The `ec.oci.image_referrers(ref)` builtin discovers all OCI referrers attached to an image:

```rego
# Discover all referrers
referrers := ec.oci.image_referrers(input.image.ref)

# Each referrer has:
# - artifactType: "application/vnd.in-toto+json"
# - digest: "sha256:abc..."
# - mediaType: media type of the artifact
# - ref: full reference to fetch the artifact (e.g., "registry/repo@sha256:...")
# - size: size in bytes
```

### Usage Example

```rego
# Fetch all in-toto statements attached to the image
referrers := ec.oci.image_referrers(input.image.ref)

# Filter by artifact type
intoto_referrers := [r |
    some r in referrers
    r.artifactType == "application/vnd.in-toto+json"
]

# Fetch statement content for each referrer
statements := [s |
    some r in intoto_referrers

    # Get the manifest to find the blob layer
    manifest := ec.oci.image_manifest(r.ref)
    blob_digest := manifest.layers[0].digest

    # Extract repo from ref (remove @digest)
    parts := split(r.ref, "@")
    repo := parts[0]

    # Fetch and parse the statement
    blob_ref := sprintf("%s@%s", [repo, blob_digest])
    statement_raw := ec.oci.blob(blob_ref)
    statement := json.unmarshal(statement_raw)

    s := {
        "statement": statement,
        "digest": r.digest,
        "ref": r.ref
    }
]

# Filter by predicate type
test_results := [s |
    some s in statements
    s.statement.predicateType == "https://in-toto.io/attestation/test-result/v0.1"
]
```

### Potential Enhancement

A convenience function `ec.oci.fetch_intoto_statements(ref)` could simplify the above pattern by combining referrer discovery with statement fetching.

### Acceptance Criteria

- [x] `ec.oci.image_referrers(ref)` discovers OCI referrers (PR #3169)
- [x] Returns artifact type for filtering
- [x] Returns ref for fetching content
- [ ] Documentation for fetching in-toto statement pattern
- [ ] Example policy for statement discovery

---

## Story 2: Verify In-Toto Statement Provenance (Chain of Trust)

### Summary

Verify the SLSA provenance attached to an in-toto statement, proving it was created by a trusted pipeline.

### Details

When a Tekton task outputs an `*_ARTIFACT_OUTPUTS` result pointing to an attached statement, Tekton Chains creates SLSA provenance for that statement. This provenance:
- Is signed by Chains
- Has the statement's digest as its subject
- Contains the pipeline/task identity that created it
- Is stored as a `.att` tag on the statement artifact

Verification uses existing `ec.sigstore.verify_attestation` on the statement's artifact reference.

### Usage Example

```rego
# Fetch test-result statements (using pattern from Story 1)
statements := fetch_intoto_statements(input.image.ref, "https://in-toto.io/attestation/test-result/v0.1")

# Verify provenance for each statement
verified_results := [result |
    some s in statements

    # Verify the statement's SLSA provenance (signed by Chains)
    provenance := ec.sigstore.verify_attestation(s.ref, {
        "public_key": chains_public_key,
        "ignore_rekor": true
    })

    # Ensure verification succeeded
    provenance.success

    # Extract pipeline identity from provenance
    some p in provenance.attestations
    pipeline := p.statement.predicate.invocation.environment.labels["tekton.dev/pipeline"]

    # Policy check: statement must come from trusted pipeline
    pipeline == "integration-test-pipeline"

    result := {
        "statement": s.statement,
        "provenance": p.statement,
        "pipeline": pipeline
    }
]
```

### Acceptance Criteria

- [x] `ec.sigstore.verify_attestation` works on statement artifact references (existing)
- [ ] Verify Chains-generated provenance on attached statements works end-to-end
- [ ] Provenance contains pipeline/task identity for policy decisions
- [ ] Documentation explains the chain of trust verification pattern
- [ ] Integration test verifies end-to-end chain of trust

---

## Story 3: Policy Rules for Chain of Trust Verification

### Summary

Create reusable policy rules that enforce chain of trust verification for in-toto statements.

### Details

Provide policy building blocks that:
1. Require test-result statements to exist
2. Require statements to have valid SLSA provenance
3. Require provenance to show trusted pipeline origin
4. Fail if any statement lacks provenance (prevents forged statements)

### Usage Example

```rego
package policy.release.test_results

import rego.v1

# Helper to fetch in-toto statements
fetch_statements(image_ref, predicate_type) := statements if {
    referrers := ec.oci.image_referrers(image_ref)
    statements := [s |
        some r in referrers
        r.artifactType == "application/vnd.in-toto+json"
        manifest := ec.oci.image_manifest(r.ref)
        blob_digest := manifest.layers[0].digest
        parts := split(r.ref, "@")
        blob_ref := sprintf("%s@%s", [parts[0], blob_digest])
        statement := json.unmarshal(ec.oci.blob(blob_ref))
        statement.predicateType == predicate_type
        s := {"statement": statement, "digest": r.digest, "ref": r.ref}
    ]
}

# Deny if no test results found
deny contains msg if {
    test_results := fetch_statements(input.image.ref, "https://in-toto.io/attestation/test-result/v0.1")
    count(test_results) == 0
    msg := "No test-result attestations found"
}

# Deny if test results lack provenance
deny contains msg if {
    test_results := fetch_statements(input.image.ref, "https://in-toto.io/attestation/test-result/v0.1")
    some s in test_results
    provenance := ec.sigstore.verify_attestation(s.ref, {
        "public_key": data.config.chains_public_key,
        "ignore_rekor": true
    })
    not provenance.success
    msg := sprintf("Test-result statement %s has no valid provenance", [s.digest])
}

# Deny if provenance shows untrusted pipeline
deny contains msg if {
    test_results := fetch_statements(input.image.ref, "https://in-toto.io/attestation/test-result/v0.1")
    some s in test_results
    provenance := ec.sigstore.verify_attestation(s.ref, {
        "public_key": data.config.chains_public_key,
        "ignore_rekor": true
    })
    provenance.success
    some p in provenance.attestations
    pipeline := p.statement.predicate.invocation.environment.labels["tekton.dev/pipeline"]
    not pipeline in data.config.trusted_pipelines
    msg := sprintf("Test-result from untrusted pipeline: %s", [pipeline])
}

# Deny if tests failed
deny contains msg if {
    test_results := fetch_statements(input.image.ref, "https://in-toto.io/attestation/test-result/v0.1")
    some s in test_results
    s.statement.predicate.result != "PASSED"
    msg := sprintf("Test %s did not pass", [s.statement.predicate.configuration[0].name])
}
```

### Acceptance Criteria

- [ ] Example policies for test-result verification
- [ ] Policies enforce provenance requirement (no unsigned statements accepted)
- [ ] Policies check pipeline identity against allowlist
- [ ] Documentation explains policy patterns
- [ ] Sample policy bundle for common use cases

---

## Dependencies

- **PR #3169**: Adds `ec.oci.image_referrers()` - required for Story 1
- **Existing**: `ec.sigstore.verify_attestation()` - used for Story 2
- **Existing**: `ec.oci.blob()`, `ec.oci.image_manifest()` - used for fetching statement content
