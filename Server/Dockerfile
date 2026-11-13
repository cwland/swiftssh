# Build context must be the repository root (the server depends on Packages/CoreSSH):
#   docker build -f Server/Dockerfile .
# docker compose (see docker-compose.yml) does this for you.

# ---- Build stage ----
FROM swift:6.0-jammy AS build

WORKDIR /build

# Resolve dependencies in a cached layer: manifests first, sources later.
COPY Packages/CoreSSH/Package.swift ./Packages/CoreSSH/
COPY Server/Package.swift Server/Package.resolved ./Server/
WORKDIR /build/Server
RUN swift package resolve

# Now the real sources.
WORKDIR /build
COPY Packages/CoreSSH ./Packages/CoreSSH
COPY Server ./Server
WORKDIR /build/Server
RUN swift build -c release --static-swift-stdlib

# Collect the binary.
RUN mkdir /staging && cp "$(swift build -c release --show-bin-path)/Run" /staging/Run

# ---- Runtime stage ----
FROM ubuntu:jammy

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates tzdata curl libcurl4 libxml2 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --user-group --create-home --home-dir /app --shell /usr/sbin/nologin vapor \
    && mkdir /data \
    && chown vapor:vapor /data

WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging/Run ./Run

USER vapor:vapor
ENV DATABASE_PATH=/data/sync.sqlite
VOLUME /data
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://localhost:8080/health || exit 1

ENTRYPOINT ["./Run", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
