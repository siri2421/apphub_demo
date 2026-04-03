import os
import grpc
import google.auth
import google.auth.transport.requests
import google.auth.transport.grpc
import redis
import pg8000.dbapi
from flask import Flask, request, jsonify

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.resourcedetector.gcp_resource_detector import GoogleCloudResourceDetector

# ── OTel setup ──────────────────────────────────────────────────────────────
# The GCP resource detector populates cloud.platform, cloud.region, faas.name
# etc. for Cloud Run — required by the AppHub topology viewer to identify this
# component. Explicit attributes (service.name, gcp.project_id) take priority.
_project_id = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
resource = GoogleCloudResourceDetector(raise_on_error=False).detect().merge(
    Resource.create({
        "service.name": "user-location",
        "gcp.project_id": _project_id,
    })
)

# Authenticate OTLP gRPC channel with Google Cloud ADC
_gcp_creds, _ = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"]
)
_grpc_creds = grpc.composite_channel_credentials(
    grpc.ssl_channel_credentials(),
    grpc.metadata_call_credentials(
        google.auth.transport.grpc.AuthMetadataPlugin(
            _gcp_creds, google.auth.transport.requests.Request()
        )
    ),
)

provider = TracerProvider(resource=resource)
# SimpleSpanProcessor exports each span immediately (synchronous).
# BatchSpanProcessor buffers spans and loses them when Cloud Run scales to zero
# before flushing — SimpleSpanProcessor avoids that data loss.
provider.add_span_processor(
    SimpleSpanProcessor(OTLPSpanExporter(
        endpoint="telemetry.googleapis.com:443",
        credentials=_grpc_creds,
    ))
)
trace.set_tracer_provider(provider)

RedisInstrumentor().instrument()

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
