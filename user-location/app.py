import os
import redis
import pg8000.dbapi
from flask import Flask, request, jsonify

from opentelemetry import trace
from opentelemetry.propagate import set_global_textmap
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.resourcedetector.gcp_resource_detector import GoogleCloudResourceDetector

# Force W3C Trace Context (traceparent header) for cross-service trace propagation
set_global_textmap(TraceContextTextMapPropagator())

# ── OTel setup ──────────────────────────────────────────────────────────────
# Use the GCP-detected resource as the base so cloud.platform, cloud.region,
# faas.name etc. for Cloud Run are populated for AppHub topology.
# Merge service-specific attributes on top; they take priority.
_project_id = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
detected_resource = GoogleCloudResourceDetector(raise_on_error=False).detect()
resource = detected_resource.merge(
    Resource.create({
        "service.name": "user-location",
        "service.namespace": "default",
        "gcp.project_id": _project_id,
        # Required for AppHub to link these spans to the registered Cloud Run
        # infrastructure — without these, topology viewer treats the data-tier
        # spans as ungrounded orphans.
        "gcp.resource_type": "cloud_run_revision",
        "cloud.platform": "gcp_cloud_run",
    })
)

provider = TracerProvider(resource=resource)
# SimpleSpanProcessor sends each span to the local OTel Collector sidecar
# synchronously (no buffering). This ensures spans are delivered before Cloud
# Run scales the instance to zero; the sidecar then batches and forwards to
# Cloud Trace using the service account credentials (no manual auth needed here).
provider.add_span_processor(
    SimpleSpanProcessor(OTLPSpanExporter(
        endpoint="localhost:4317",
        insecure=True,
    ))
)
trace.set_tracer_provider(provider)

# RedisInstrumentor removed — the manual redis.get span already carries
# peer.service=apphub-redis and db.system=redis for AppHub topology.
# Auto-instrumentation added a redundant GET span alongside it.

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

tracer = trace.get_tracer(__name__)

# ── Redis client ─────────────────────────────────────────────────────────────
redis_client = redis.Redis(
    host=os.environ["REDIS_HOST"],
    port=int(os.environ.get("REDIS_PORT", 6379)),
    decode_responses=True,
)

# ── AlloyDB direct connection (private IP + SSL) ──────────────────────────────
ALLOYDB_HOST = os.environ["ALLOYDB_HOST"]
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_NAME = os.environ.get("DB_NAME", "postgres")


def _get_db_conn():
    return pg8000.dbapi.connect(
        host=ALLOYDB_HOST,
        port=5432,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        ssl_context=True,
    )


@app.route("/user")
def get_user():
    user_id = request.args.get("user_id")
    if not user_id:
        return jsonify({"error": "user_id query parameter is required"}), 400

    # ── 1. Check Redis cache ─────────────────────────────────────────────────
    # peer.service + db.system let the AppHub topology viewer draw an edge to
    # the Redis node and identify it as a cache dependency.
    with tracer.start_as_current_span("redis.get", attributes={
        "peer.service": "apphub-redis",
        "db.system": "redis",
        "net.peer.name": os.environ.get("REDIS_HOST", ""),
    }):
        cached = redis_client.get(user_id)

    if cached:
        return jsonify({"result": cached, "source": "cache"}), 200

    # ── 2. Fall back to AlloyDB ──────────────────────────────────────────────
    # peer.service + db.* let the topology viewer draw an edge to the AlloyDB
    # node and identify it as a PostgreSQL-compatible database dependency.
    with tracer.start_as_current_span("alloydb.query", attributes={
        "peer.service": "apphub-alloydb",
        "db.system": "postgresql",
        "db.name": DB_NAME,
        "db.user": DB_USER,
        "net.peer.name": ALLOYDB_HOST,
    }):
        conn = _get_db_conn()
        cursor = conn.cursor()
        cursor.execute(
            "SELECT user_name FROM users WHERE user_id = %s", (user_id,)
        )
        row = cursor.fetchone()
        cursor.close()
        conn.close()

    if row:
        return jsonify({"result": row[0], "source": "database"}), 200

    return jsonify({"error": "user not found"}), 404


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
