# Attestable Build-Time Tests Demo

This demo shows how to create a chain of trust for container images using Tekton Pipelines and Tekton Chains. It demonstrates:

1. Building a container image with SLSA provenance
2. Running integration tests and creating signed test-result attestations
3. Generating provenance for the attestations themselves (proving test results came from a specific pipeline)

## Prerequisites

- [kind](https://kind.sigs.k8s.io/) - Kubernetes in Docker
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [cosign](https://docs.sigstore.dev/cosign/installation/)
- [oras](https://oras.land/docs/installation) - for viewing OCI artifacts
- Docker or Podman running
- Access to a container registry (e.g., quay.io, ghcr.io, Docker Hub)

## Quick Start

```bash
# 1. Set up the kind cluster with Tekton
./setup/setup-cluster.sh

# 2. Set up pipeline resources and registry credentials
./scripts/setup-pipelines.sh

# 3. Run the build (uses your ~/.docker/config.json for registry auth)
./scripts/run-build.sh --image-ref <your-registry>/<your-repo>

# 4. Run integration tests
./scripts/run-integration-test.sh

# 5. View the chain of trust
./scripts/show-chain-of-trust.sh
```

## Configuration

### Using Your Own Registry

> **Note:** The `run-demo.sh` script has a hardcoded image reference. To use your own registry, run `run-build.sh` and `run-integration-test.sh` separately as shown below.

The demo needs to push images and attestations to a container registry. Configure this by:

1. **Ensure you're logged in** to your registry:
   ```bash
   docker login quay.io
   # or
   podman login ghcr.io
   ```

2. **Specify your image reference** when running the build:
   ```bash
   ./scripts/run-build.sh --image-ref quay.io/yourusername/demo-image
   ```

   Or set the environment variable:
   ```bash
   export IMAGE_REF=ghcr.io/yourusername/demo-image
   ./scripts/run-build.sh
   ```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IMAGE_REF` | `quay.io/jstuart/hacbs-docker-build` | Image to build and push |
| `REPO_URL` | `https://github.com/joejstuart/hacbs-docker-build.git` | Source repository |
| `DOCKERFILE` | `./image_with_labels/Dockerfile` | Dockerfile path in repo |
| `NAMESPACE` | `work` | Kubernetes namespace |
| `TIMEOUT` | `600` | Pipeline timeout in seconds |

## Step-by-Step Walkthrough

### 1. Create the Cluster

```bash
./setup/setup-cluster.sh
```

This creates a kind cluster named `its-demo` and installs:
- Tekton Pipelines v1.10.0
- Tekton Chains v0.26.2 (configured for OCI storage)
- Cosign signing keys

### 2. Set Up Pipelines

```bash
./scripts/setup-pipelines.sh
```

This installs:
- Git clone and buildah tasks
- Build pipeline (`clone-build-push`)
- Integration test pipeline and task
- Registry credentials from `~/.docker/config.json`

### 3. Run the Build

```bash
./scripts/run-build.sh --image-ref quay.io/yourusername/demo-image
```

This:
- Clones the source repository
- Builds the container image
- Pushes to your registry
- Waits for Tekton Chains to sign and create SLSA provenance

Build results are saved to `.build-results` for the next step.

### 4. Run Integration Tests

```bash
./scripts/run-integration-test.sh
```

This:
- Runs integration tests against the built image
- Creates a signed test-result attestation
- Pushes the attestation to the registry as an OCI artifact
- Tekton Chains creates provenance for the attestation itself

### 5. View the Chain of Trust

```bash
./scripts/show-chain-of-trust.sh
```

This displays:
- All attestations attached to the image
- A visual diagram of the trust chain
- Decoded attestation details

### 6. Verify Attestations

```bash
./scripts/verify-attestations.sh <image>@<digest>
```

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                     CONTAINER IMAGE                             │
└─────────────────────────────┬───────────────────────────────────┘
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                           │
        ▼                                           ▼
┌───────────────────────────┐     ┌───────────────────────────┐
│   SLSA PROVENANCE         │     │   TEST-RESULT             │
│   (Build Pipeline)        │     │   ATTESTATION             │
│                           │     │                           │
│   Subject: IMAGE          │     │   Subject: IMAGE          │
│   Signer: Tekton Chains   │     │   Signer: cosign (task)   │
└───────────────────────────┘     └─────────────┬─────────────┘
                                                │
                                                ▼
                                  ┌───────────────────────────┐
                                  │   SLSA PROVENANCE         │
                                  │   (Integration Pipeline)  │
                                  │                           │
                                  │   Subject: ATTESTATION    │
                                  │   Signer: Tekton Chains   │
                                  └───────────────────────────┘
```

The chain proves:
1. **Build provenance**: The image was built by a specific pipeline from known source
2. **Test attestation**: The image passed specific tests
3. **Test provenance**: The test attestation was created by a specific pipeline (not forged)

## Why This Matters

Without provenance on test attestations, an attacker with registry write access could:

1. Push a malicious image
2. Create a fake "tests passed" attestation
3. Sign it with their own key

The signature would be valid, but the attestation would be forged. There's no way to verify *who* created it or *how*.

With the chain of trust, verification policies can require:

- The test attestation has SLSA provenance attached
- That provenance shows it was created by a trusted CI/CD pipeline
- The pipeline identity matches an expected value (e.g., a specific Tekton pipeline in a specific namespace)

This makes forging test results as hard as compromising the CI system itself.

## How ARTIFACT_OUTPUTS Works

The key mechanism that enables provenance on attestations is the `ARTIFACT_OUTPUTS` result.

When a Tekton task or pipeline produces an artifact (like an attestation) and wants Chains to generate provenance for it, it outputs a result in this format:

```json
{
  "uri": "quay.io/user/image",
  "digest": "sha256:abc123..."
}
```

Tekton Chains watches for results named `*_ARTIFACT_OUTPUTS` (or type-hinted results). When it sees one:

1. It treats the digest as a **subject** for provenance generation
2. It creates SLSA provenance with that artifact as the subject
3. It signs and pushes the provenance to the registry

In this demo, the integration test task:
1. Creates a test-result attestation and pushes it to the registry
2. Outputs the attestation's digest as `TEST_OUTPUT_ARTIFACT_OUTPUTS`
3. Chains sees this and generates provenance proving the attestation came from this pipeline

This creates the second layer of the chain - provenance about the provenance.

## Attestation Formats

This demo uses two attestation formats:

### SLSA Provenance (v0.2)

Created automatically by Tekton Chains for builds and artifacts. Contains:

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "subject": [{ "digest": { "sha256": "..." } }],
  "predicate": {
    "buildType": "tekton.dev/v1/PipelineRun",
    "builder": { "id": "https://tekton.dev/chains/v2" },
    "invocation": {
      "configSource": { /* git repo, commit, etc. */ }
    },
    "buildConfig": {
      "tasks": [ /* task details, parameters, results */ ]
    }
  }
}
```

### Test Result Attestation

Created by the integration test task. Uses a custom predicate type:

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://in-toto.io/attestation/test-result/v0.1",
  "subject": [{ "digest": { "sha256": "..." } }],
  "predicate": {
    "result": "PASSED",
    "timestamp": "2024-01-15T10:30:00Z",
    "passedTests": ["image-validation"],
    "test": {
      "name": "image-validation",
      "type": "integration"
    }
  }
}
```

Both formats follow the [in-toto attestation specification](https://github.com/in-toto/attestation), which defines a standard envelope with:
- **Subject**: What the attestation is about (identified by digest)
- **Predicate**: The actual claims being made (build info, test results, etc.)

## Cleanup

```bash
# Delete pipeline runs
./scripts/cleanup.sh

# Delete the kind cluster entirely
kind delete cluster --name its-demo
```

## Scripts Reference

| Script | Description |
|--------|-------------|
| `setup/setup-cluster.sh` | Create kind cluster and install Tekton |
| `scripts/setup-pipelines.sh` | Install tasks, pipelines, and credentials |
| `scripts/run-build.sh` | Run the build pipeline |
| `scripts/run-integration-test.sh` | Run integration tests |
| `scripts/run-demo.sh` | Run build + integration test in one command (hardcoded image) |
| `scripts/show-chain-of-trust.sh` | Visualize the attestation chain |
| `scripts/verify-attestations.sh` | Verify attestation signatures |
| `scripts/cleanup.sh` | Clean up pipeline runs |
