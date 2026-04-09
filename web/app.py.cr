import os
import redis # Ensure 'redis' is in your requirements.txt
import google.auth.transport.requests
import google.oauth2.id_token
import requests as http_client
from flask import Flask, request, Response, abort

from opentelemetry import trace
from opentelemetry.trace import SpanKind, StatusCode
from opentelemetry.propagate import set_global_textmap
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.propagators.cloud_trace_propagator import CloudTraceFormatPropagator
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.resourcedetector.gcp_resource_detector import GoogleCloudResourceDetector

# ── OTel Setup ──────────────────────────────────────────────────────────────
set_global_textmap(CompositePropagator([
    TraceContextTextMapPropagator(),
    CloudTraceFormatPropagator(),
]))

_project_id = os.environ.get("GOOGLE_CLOUD_PROJECT", "agentic-marketing-demo")
_region = os.environ.get("GOOGLE_CLOUD_REGION", "us-central1")

resource = GoogleCloudResourceDetector(raise_on_error=False).detect().merge(
    Resource.create({
        "service.name": "web",
        "service.namespace": "default",
        "gcp.apphub.application.id": "apphub-demo",
        "gcp.apphub.workload.id": "web",
    })
)

provider = TracerProvider(resource=resource)
_otlp_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")
if _otlp_endpoint:
    provider.add_span_processor(SimpleSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)
tracer = trace.get_tracer(__name__)

# ── Redis Config ──
# You will need to add REDIS_HOST to your GKE Deployment env vars
REDIS_HOST = os.environ.get("REDIS_HOST", "10.105.161.131") 
REDIS_URI = f"//redis.googleapis.com/projects/{_project_id}/locations/{_region}/instances/apphub-redis"
redis_client = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True)

@app.route("/user")
def user():
    user_id = request.args.get("user_id")
    if not user_id:
        return {"error": "user_id required"}, 400

    # Direct Redis call from GKE
    with tracer.start_as_current_span(
        "web.redis_check",
        kind=SpanKind.CLIENT,
        attributes={
            "gcp.resource.name": REDIS_URI,
            "db.system": "redis"
        }
    ) as span:
        try:
            cached_val = redis_client.get(user_id)
            if cached_val:
                return {"result": cached_val, "source": "gke-direct-cache"}
        except Exception as e:
            span.set_status(StatusCode.ERROR, str(e))
            # Fallback to existing Cloud Run logic if Redis fails or misses
    
    # Fallback logic (your original Cloud Run call)
    return {"status": "miss", "detail": "Proceeding to downstream..."}, 200

@app.route("/healthz")
def healthz():
    return {"status": "ok"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)