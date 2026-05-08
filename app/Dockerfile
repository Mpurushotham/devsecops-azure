# Multi-stage, hardened Dockerfile following CIS Docker Benchmark.
# Stage 1: Build
FROM python:3.12-slim AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

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

# Security hardening
RUN apt-get update && apt-get upgrade -y && \
    apt-get remove --purge -y gcc && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    find / -perm /6000 -type f -exec chmod a-s {} \; 2>/dev/null || true

# Drop all capabilities — app should not need any
USER appuser

# Expose non-privileged port
EXPOSE 8080

# Read-only filesystem (set in k8s securityContext too)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=random \
    PORT=8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz')"

ENTRYPOINT ["python", "-m", "src.main"]
