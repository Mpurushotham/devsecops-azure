"""
DevSecOps sample application — Flask API with:
- OpenTelemetry tracing
- Prometheus metrics
- Structured logging
- Security headers middleware
"""

import os
import time

import structlog
from flask import Flask, g, jsonify, request
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# ── Logging setup ─────────────────────────────────────────────────────────────
structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    logger_factory=structlog.stdlib.LoggerFactory(),
    cache_logger_on_first_use=True,
)
log = structlog.get_logger()


# ── OpenTelemetry setup ───────────────────────────────────────────────────────
def setup_tracing():
    provider = TracerProvider()
    otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
    exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    return trace.get_tracer(__name__)


tracer = setup_tracing()

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["method", "endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)

# ── Flask app ─────────────────────────────────────────────────────────────────
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)


@app.before_request
def before_request():
    g.start_time = time.time()


@app.after_request
def after_request(response):
    # Security headers
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["Content-Security-Policy"] = "default-src 'self'"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"

    # Remove server header to avoid version disclosure
    response.headers.pop("Server", None)

    # Metrics
    duration = time.time() - g.start_time
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.endpoint or "unknown",
        status=response.status_code,
    ).inc()
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=request.endpoint or "unknown",
    ).observe(duration)

    return response


# ── Routes ────────────────────────────────────────────────────────────────────
@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200


@app.route("/readyz")
def readyz():
    return jsonify({"status": "ready"}), 200


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.route("/api/v1/info")
def info():
    with tracer.start_as_current_span("get-info"):
        log.info("info endpoint called", remote_addr=request.remote_addr)
        return (
            jsonify(
                {
                    "service": "devsecops-app",
                    "version": os.getenv("APP_VERSION", "dev"),
                    "environment": os.getenv("ENVIRONMENT", "unknown"),
                }
            ),
            200,
        )


@app.route("/api/v1/items", methods=["GET"])
def list_items():
    with tracer.start_as_current_span("list-items"):
        items = [{"id": i, "name": f"item-{i}"} for i in range(1, 6)]
        return jsonify({"items": items, "count": len(items)}), 200


# Served so the ZAP API scan in .github/workflows/dast.yml has a real contract
# to drive against — it previously pointed at Spring's /v3/api-docs, which this
# service never exposed.
@app.route("/api/v1/openapi.json")
def openapi_spec():
    ok_json = {
        "200": {
            "description": "Successful response",
            "content": {"application/json": {"schema": {"type": "object"}}},
        }
    }
    return (
        jsonify(
            {
                "openapi": "3.0.3",
                "info": {
                    "title": "devsecops-app",
                    "version": os.getenv("APP_VERSION", "dev"),
                    "description": "Azure DevSecOps reference application",
                },
                "paths": {
                    "/healthz": {"get": {"summary": "Liveness probe", "responses": ok_json}},
                    "/readyz": {"get": {"summary": "Readiness probe", "responses": ok_json}},
                    "/api/v1/info": {"get": {"summary": "Service metadata", "responses": ok_json}},
                    "/api/v1/items": {"get": {"summary": "List items", "responses": ok_json}},
                },
            }
        ),
        200,
    )


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    log.info("starting server", port=port)

    import gunicorn
    from gunicorn.app.base import BaseApplication

    # Flask's after_request cannot strip the Server header: gunicorn writes it
    # onto the response after the WSGI app has returned, so `headers.pop` only
    # ever removed a header the test client never set. Overriding the banner
    # here is what actually stops version disclosure in production.
    gunicorn.SERVER = "undisclosed"
    gunicorn.SERVER_SOFTWARE = "undisclosed"

    class StandaloneApplication(BaseApplication):
        def __init__(self, application, options=None):
            self.options = options or {}
            self.application = application
            super().__init__()

        def load_config(self):
            for key, value in self.options.items():
                self.cfg.set(key.lower(), value)

        def load(self):
            return self.application

    options = {
        "bind": f"0.0.0.0:{port}",
        "workers": int(os.getenv("GUNICORN_WORKERS", 2)),
        "worker_class": "sync",
        "timeout": 30,
        "keepalive": 5,
        "max_requests": 1000,
        "max_requests_jitter": 100,
        "accesslog": "-",
        "errorlog": "-",
        "loglevel": "info",
        "forwarded_allow_ips": "*",
    }
    StandaloneApplication(app, options).run()
