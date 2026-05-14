# syntax=docker/dockerfile:1
# Multi-stage build: compiles the better-ccflare binary from source.
# Cross-compiles via Bun's --target so buildx multi-arch works without QEMU
# emulating the whole build toolchain.
# Supports: linux/amd64, linux/arm64

ARG BUN_VERSION=1

# ---- Builder ----
FROM --platform=$BUILDPLATFORM oven/bun:${BUN_VERSION} AS builder

# apps/cli build script invokes `node -p`; install a minimal node.
RUN apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY . .

RUN bun install --frozen-lockfile

# Pick the Bun compile target from Docker's TARGETARCH.
# amd64 uses the baseline target: no AVX2 requirement, runs on all x86_64
# CPUs/VMs (the default bun-linux-x64 runtime SIGILLs on non-AVX2 hosts).
ARG TARGETARCH
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) BUN_TARGET=bun-linux-x64-baseline ;; \
      arm64) BUN_TARGET=bun-linux-arm64 ;; \
      *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    cd apps/cli; \
    # Worker-embedding prep (also does a throwaway native compile).
    bun run build; \
    VERSION="$(bun -e "console.log(require('./package.json').version)")"; \
    mkdir -p /out; \
    bun build src/main.ts --compile \
      --outfile /out/better-ccflare \
      --target="$BUN_TARGET" --minify \
      --define __BETTER_CCFLARE_VERSION__="\"$VERSION\""

# ---- Runtime ----
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      sqlite3 \
      ca-certificates \
      curl \
      && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /out/better-ccflare /usr/local/bin/better-ccflare
RUN chmod +x /usr/local/bin/better-ccflare && \
    /usr/local/bin/better-ccflare --version

# Create a non-root user to run the application
RUN useradd -r -u 1000 -m -s /bin/bash ccflare && \
    mkdir -p /data /app/logs && \
    chown -R ccflare:ccflare /data /app

# Set environment variables
ENV NODE_ENV=production
ENV BETTER_CCFLARE_DB_PATH=/data/better-ccflare.db
ENV XDG_CONFIG_HOME=/data
ENV BETTER_CCFLARE_LOG_DIR=/app/logs

# Expose default port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Labels for version tracking (overridden by GitHub Actions metadata)
ARG VERSION=latest
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.title="better-ccflare"
LABEL org.opencontainers.image.description="Load balancer proxy for Claude API with intelligent distribution across multiple OAuth accounts"
LABEL org.opencontainers.image.source="https://github.com/nelsliu9121/better-ccflare"

# Startup script that shows version
RUN printf '%s\n' \
  '#!/bin/bash' \
  'echo "================================="' \
  'echo "better-ccflare Docker Container"' \
  'echo "================================="' \
  'echo "Architecture: $(uname -m)"' \
  'echo ""' \
  '/usr/local/bin/better-ccflare --version' \
  'echo "================================="' \
  'echo ""' \
  'exec /usr/local/bin/better-ccflare "$@"' \
  > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

# Switch to non-root user
USER ccflare

# Add volume mount for persistent data only
VOLUME ["/data"]

# Use the startup script as entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--serve", "--port", "8080"]
