# Add-on 03 — Golden Template  [Security]

**Goal**: Show a hardened org image that bakes in the enterprise security baseline — every agent that uses it starts identical, compliant, and with no internet-fetched toolchain.

**Audience**: Platform engineering, security engineers, anyone responsible for standardizing the agent runtime environment across the organization.

---

## Prerequisites

- Docker installed and running locally
- `docker login docker.io` completed for the `nicksdemoorg` namespace (or your org's equivalent)
- `sbx` CLI installed and authenticated on your host machine
- The `sbx-enterprise-demo` repo checked out locally
- For production builds: replace `templates/golden/corp-ca.crt` with your organization's real CA certificate

---

## Background

By default, each sbx sandbox starts from a standard `docker/sandbox-templates:claude-code` image. That image has the Claude Code agent pre-installed but contains no org-specific tooling, no corporate CA cert, and no pinned software versions.

A **golden template** is a Docker image you build, push to your registry, and reference in `sbx run --template`. It extends the standard base image with:

- Your corporate CA certificate baked in at the OS trust store level
- Approved tools at pinned versions (no `apt-get install latest` at runtime)
- Pre-installed Python tooling via `uv` (no PyPI fetches at agent startup)
- Image labels for provenance tracking

Every agent that uses the golden template starts from the same immutable layer. A security fix becomes a one-line Dockerfile change, a new image push, and a tag update — all reviewable in git.

---

## Step 1: Show the Dockerfile

```bash
cat templates/golden/Dockerfile
```

Walk through each section with the audience:

**Root layer (system packages and CA trust):**

```dockerfile
USER root
COPY corp-ca.crt /usr/local/share/ca-certificates/corp-ca.crt
RUN update-ca-certificates
```

**SAY**: "This Dockerfile extends the official sandbox template. The root layer installs our corporate CA certificate and approved tools at pinned versions. Then we drop to the agent user for home-directory tooling. The result: every agent that uses this image starts identical and compliant."

Point out the explicit version pins:

- `GH_VERSION=2.50.0` — GitHub CLI, pinned, no silent updates
- `UV_VERSION=0.4.18` — uv package manager, pinned
- `ruff==0.4.10` — Python linter, pinned

**SAY**: "Pinned versions mean you know exactly what tool is running in every sandbox. When CVE-2025-XXXX drops for gh 2.50.0, you update one ARG, rebuild, push a new tag, and all new sandboxes pick it up. You are never guessing what version an agent ran."

---

## Step 2: Build the Image (Self-Validate)

Verify the Dockerfile builds correctly before pushing to the registry:

```bash
# Self-validate: docker build works locally
DRY_RUN=1 bash templates/golden/build.sh
```

**EXPECT**: Docker build output ending with `Build complete: docker.io/nicksdemoorg/sbx-golden:v1` and `DRY_RUN=1 — skipping push.`

**Note**: If your organization has a real CA certificate, replace the placeholder before running this step:

```bash
# Replace the placeholder cert with your real corporate CA
cp /path/to/your/corp-ca.crt templates/golden/corp-ca.crt
```

The placeholder `corp-ca.crt` in this repo is a self-signed certificate for demonstration purposes. It satisfies the `COPY` instruction in the Dockerfile but does not add meaningful trust in a production environment.

---

## Step 3: Push to Registry

Push the built image to the `nicksdemoorg` registry namespace:

```bash
# ▶ host-validate — requires docker login docker.io/nicksdemoorg
bash templates/golden/build.sh
```

**EXPECT**: Build output followed by `Pushed. Use with: sbx run claude --template docker.io/nicksdemoorg/sbx-golden:v1`

The `build.sh` script builds for `linux/arm64`. To build for `linux/amd64` (or multi-arch), set the `TAG` variable and adjust the `--platform` flag in `build.sh`:

```bash
# Override tag for a versioned release
TAG=v1.1 bash templates/golden/build.sh
```

---

## Step 4: Run an Agent from the Golden Template

Launch a sandbox using the image you just pushed:

```bash
# ▶ host-validate
sbx run claude --template docker.io/nicksdemoorg/sbx-golden:v1 \
  -- --dangerously-skip-permissions \
  "Run: gh --version && ruff --version && openssl s_client -connect api.example.com:443 -showcerts 2>&1 | head -5"
```

**EXPECT**:
- `gh version 2.50.0 (...)` — pinned GitHub CLI
- `ruff 0.4.10` — pinned linter
- TLS handshake output including your corporate CA cert in the certificate chain

**SAY**: "Change the Dockerfile once, push a new tag, every agent in the org picks it up. One place to update approved tools, one place to rotate the CA cert. No agent is running an unreviewed version of anything."

If the CA cert test is not representative in the demo environment (because `api.example.com` is not a real host), substitute with an internal domain that uses your corporate CA, or show just the `gh --version` and `ruff --version` outputs as proof of the pinned toolchain.

---

## Gov Aside

**▸ Gov aside**: "Combine this with kit-level credential injection (add-on 02) and org governance and you have defense in depth: the image is the compliance baseline, the kit injects credentials the agent never sees, org policy is the network/filesystem enforcement boundary."

| Layer | Mechanism | Who owns it |
|-------|-----------|-------------|
| Golden template | Docker image in registry | Platform engineering |
| Kit credential injection | `spec.yaml` in git repo | Team or project |
| Org governance (network + filesystem) | Org-level sbx policy | Security / IT |

Each layer can be updated independently. Updating the org policy does not require rebuilding the image. Updating the image does not require changing kit files. They compose without coupling.

---

## Additional Notes

**Image provenance**: The Dockerfile includes `LABEL` instructions with OCI image metadata. Your container scanning tool (Snyk, Trivy, Grype) can pick these up and tie scan results back to the specific image version.

**Multi-arch builds**: The `build.sh` currently targets `linux/arm64` (Apple Silicon / ARM hosts). If your sbx environment runs on `linux/amd64` hosts, change the `--platform` flag. For a universal image, use `--platform linux/amd64,linux/arm64` with `docker buildx`.

**Image scanning before push**: Insert a scan step between build and push in `build.sh`:

```bash
# Add before the docker push line:
docker scout cves "${FULL_IMAGE}" --exit-code --only-severity critical
```

This blocks the push if critical CVEs are found.

---

## Validation Status

| Step | Validation method | Notes |
|------|-------------------|-------|
| Step 1 — Show Dockerfile | Self-validated (file read) | No docker or sbx required |
| Step 2 — `DRY_RUN=1 bash build.sh` | Self-validated (docker build local) | Requires Docker daemon; replace CA cert for production |
| Step 3 — `bash build.sh` (push) | **host-validate** | Requires `docker login docker.io/nicksdemoorg` |
| Step 4 — `sbx run --template` | **host-validate** | Requires sbx CLI and the image to exist in registry |
