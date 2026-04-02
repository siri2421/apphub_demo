import os
import redis
import pg8000.dbapi
from google.cloud.alloydb.connector import Connector, IPTypes
from flask import Flask, request, jsonify

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor

# ── OTel setup ──────────────────────────────────────────────────────────────
# W3C TraceContext propagation is the default; the incoming traceparent header
# from the web service is automatically extracted so spans are linked in Cloud Trace.
provider = TracerProvider()
provider.add_span_processor(
    BatchSpanProcessor(CloudTraceSpanExporter())
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

# ── AlloyDB connector (reused across requests) ───────────────────────────────
_connector = Connector()

ALLOYDB_INSTANCE = os.environ["ALLOYDB_INSTANCE"]
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_NAME = os.environ.get("DB_NAME", "postgres")


def _get_db_conn():
    return _connector.connect(
        ALLOYDB_INSTANCE,
        "pg8000",
        user=DB_USER,
        password=DB_PASSWORD,
        db=DB_NAME,
        ip_type=IPTypes.PRIVATE,
    )


@app.route("/user")
def get_user():
    user_id = request.args.get("user_id")
    if not user_id:
        return jsonify({"error": "user_id query parameter is required"}), 400

    # ── 1. Check Redis cache ─────────────────────────────────────────────────
    with tracer.start_as_current_span("redis.get"):
        cached = redis_client.get(user_id)

    if cached:
        return jsonify({"result": cached, "source": "cache"}), 200

    # ── 2. Fall back to AlloyDB ──────────────────────────────────────────────
    with tracer.start_as_current_span("alloydb.query"):
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
