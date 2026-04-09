import os
import redis
import atexit
from flask import Flask, request, jsonify

# 1. Module-level patching (Must happen first)
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor

# Patch redis early so the client is wrapped upon creation
RedisInstrumentor().instrument()

from opentelemetry import trace
from opentelemetry.trace import SpanKind, StatusCode
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.resourcedetector.gcp_resource_detector import GoogleCloudResourceDetector

# 2. GLOBAL INITIALIZATION (Outside the route)
# This detects GCP metadata once when the worker process starts
resource = GoogleCloudResourceDetector(raise_on_error=False).detect().merge(
    Resource.create({
        "service.name": "user-location",
        "gcp.apphub.application.id": "apphub-demo",
        "gcp.apphub.service.id": "user-location",
    })
)

provider = TracerProvider(resource=resource)
# SimpleSpanProcessor sends spans immediately to the sidecar
exporter = OTLPSpanExporter(endpoint="localhost:4317", insecure=True)
provider.add_span_processor(SimpleSpanProcessor(exporter))
trace.set_tracer_provider(provider)

app = Flask(__name__)

# CRITICAL: instrument_app MUST be called here, in the global scope, 
# BEFORE the first request is handled.
FlaskInstrumentor().instrument_app(app)
tracer = trace.get_tracer(__name__)

# 3. Redis Config
redis_client = redis.Redis(
    host=os.environ.get("REDIS_HOST", "10.105.161.131"), 
    port=6379, 
    decode_responses=True
)

@app.route("/user")
def get_user():
    user_id = request.args.get("user_id")
    if not user_id:
        return jsonify({"error": "user_id required"}), 400

    # Nest the Redis span under the auto-generated Flask span
    with tracer.start_as_current_span(
        "redis.get", 
        kind=SpanKind.CLIENT,
        attributes={
            "gcp.resource.name": f"//redis.googleapis.com/projects/{os.environ.get('GOOGLE_CLOUD_PROJECT')}/locations/us-central1/instances/apphub-redis",
            "db.system": "redis",
            "peer.service": "apphub-redis"
        }
    ) as span:
        try:
            cached = redis_client.get(user_id)
            
            # Flush manually to ensure the leaf span clears the process 
            # before the HTTP response is sent.
            provider.force_flush()
            
            if cached:
                return jsonify({"result": cached, "source": "cache"})
            return jsonify({"error": "not found"}), 404
            
        except Exception as e:
            span.set_status(StatusCode.ERROR, str(e))
            return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)