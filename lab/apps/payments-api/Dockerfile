# =============================================================================
# payments-api — hardened multi-stage build
# =============================================================================
# Build context is lab/apps/payments-api (see the reusable build workflow).
#
# The runtime stage is chiseled: Ubuntu with no shell, no package manager and
# no busybox. If an attacker achieves RCE there is literally no /bin/sh to
# spawn — which also means Falco's "shell in container" rule firing here is
# unambiguous evidence of compromise rather than someone debugging.
# =============================================================================

ARG DOTNET_VERSION=10.0

# ── Stage 1: restore + publish ───────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} AS build

WORKDIR /src

# Restore as its own layer so a code-only change does not re-download packages.
COPY src/PaymentsApi.csproj ./
RUN dotnet restore PaymentsApi.csproj --runtime linux-x64

COPY src/ ./

ARG VERSION=dev
ARG GIT_COMMIT=unknown

RUN dotnet publish PaymentsApi.csproj \
      --configuration Release \
      --runtime linux-x64 \
      --self-contained false \
      --no-restore \
      -p:Version="${VERSION}" \
      -p:SourceRevisionId="${GIT_COMMIT}" \
      --output /app/publish

# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION}-noble-chiseled AS runtime

# UID 64198 (app) is baked into the chiseled image and is non-root by default;
# stating it explicitly is what satisfies the Kyverno require-non-root policy
# and kube-linter's run-as-non-root check.
USER 64198:64198

WORKDIR /app
COPY --from=build --chown=64198:64198 /app/publish ./

ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_DATE

LABEL org.opencontainers.image.title="payments-api" \
      org.opencontainers.image.description="Reference .NET 10 workload for the AKS platform" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.vendor="Platform Engineering"

ENV ASPNETCORE_URLS=http://+:8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_EnableDiagnostics=0 \
    DOTNET_gcServer=1 \
    APP_VERSION=${VERSION}

EXPOSE 8080

# No HEALTHCHECK instruction: the chiseled image has no shell or curl to run
# one, and Kubernetes probes are the authoritative health signal anyway.

ENTRYPOINT ["./PaymentsApi"]
