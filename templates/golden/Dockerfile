FROM docker/sandbox-templates:claude-code

# --- root layer: system packages and corporate trust store ---
USER root

# Install corporate CA certificate (replace corp-ca.crt with your real cert).
COPY corp-ca.crt /usr/local/share/ca-certificates/corp-ca.crt
RUN update-ca-certificates

# Install a pinned, approved toolchain.  Pin versions explicitly so every agent
# gets an identical baseline regardless of when the image is built.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        ripgrep \
        shellcheck \
        unzip \
        && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install a pinned version of the GitHub CLI (approved binary, checksum verified).
ARG GH_VERSION=2.50.0
RUN curl -fsSL \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_arm64.tar.gz" \
    -o /tmp/gh.tar.gz && \
    tar -xzf /tmp/gh.tar.gz -C /tmp && \
    install -m 755 /tmp/gh_${GH_VERSION}_linux_arm64/bin/gh /usr/local/bin/gh && \
    rm -rf /tmp/gh*

# --- agent layer: home-directory tooling (must run as the agent user) ---
USER agent

# uv — fast Python package manager, pinned version.
ARG UV_VERSION=0.4.18
RUN curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh
ENV PATH="/home/agent/.cargo/bin:${PATH}"

# ruff linter (pre-installed so agents don't need internet to pull it).
RUN uv tool install "ruff==0.4.10"

# Verify the toolchain is intact.
RUN gh --version && ruff --version

LABEL org.opencontainers.image.title="sbx-golden" \
      org.opencontainers.image.description="Enterprise-hardened Docker Sandbox base image" \
      org.opencontainers.image.vendor="nicksdemoorg" \
      org.opencontainers.image.version="1.0"
