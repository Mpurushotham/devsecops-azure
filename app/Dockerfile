# Multi-stage, hardened Dockerfile following CIS Docker Benchmark.
# Stage 1: Build
FROM python:3.12-slim AS builder

WORKDIR /build

# No build toolchain: every pinned dependency publishes a manylinux wheel, so
# gcc and libffi-dev are unnecessary. Dropping them removes an unpinned
# apt-get install (hadolint DL3008), shrinks the builder stage and eliminates a
# class of build-time supply-chain exposure.
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Stage 2: Runtime (distroless-like minimal image)
FROM python:3.12-slim AS runtime

# Security: create non-root user
RUN groupadd --gid 10001 appgroup && \
    useradd --uid 10001 --gid appgroup --no-create-home --shell /sbin/nologin appuser

WORKDIR /app

# Copy only necessary files from builder
COPY --from=builder /install /usr/local
COPY --chown=appuser:appgroup src/ ./src/

# Security hardening: strip setuid/setgid bits so a compromised process cannot
# escalate through a stray privileged binary.
#
# Deliberately no `apt-get upgrade` here. It makes the build non-reproducible —
# the same Dockerfile and the same pins produce different packages depending on
# when it ran — and it silently masks a stale base image. Base-image CVEs are
# addressed by rebuilding on a newer python:3.12-slim digest, which Trivy
# catches in the image scan.
RUN find / -perm /6000 -type f -exec chmod a-s {} \; 2>/dev/null || true

# Drop all capabilities — app should not need any
USER appuser

# Expose non-privileged port
EXPOSE 8080

# Read-only filesystem (set in k8s securityContext too)
#
# HOME=/tmp because appuser is created with --no-create-home: gunicorn's control
# server writes under $HOME at startup and logged a permission error on every
# boot otherwise. /tmp is the one writable mount when the root filesystem is
# read-only, so this works unchanged under the Kubernetes securityContext.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=random \
    HOME=/tmp \
    PORT=8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz')"

ENTRYPOINT ["python", "-m", "src.main"]
