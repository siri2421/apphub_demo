import os
import google.auth.transport.requests
import google.oauth2.id_token
import requests as http_client
from flask import Flask, request, Response, abort

from opentelemetry import trace
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

# Accept both W3C traceparent (service-to-service) and X-Cloud-Trace-Context
# (injected by any upstream Google LB) so the very first hop is visible in
# Cloud Trace. W3C is checked first; GCP header is the fallback.
set_global_textmap(CompositePropagator([
    TraceContextTextMapPropagator(),
    CloudTraceFormatPropagator(),
]))

# ── OTel setup ──────────────────────────────────────────────────────────────
# Use the GCP-detected resource as the base so cloud.platform, k8s.cluster.name,
# k8s.namespace.name, k8s.pod.name etc. are populated for AppHub topology.
# Merge service-specific attributes on top; they take priority.
_project_id = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
_region = os.environ.get("GOOGLE_CLOUD_REGION", "us-central1")
detected_resource = GoogleCloudResourceDetector(raise_on_error=False).detect()
resource = detected_resource.merge(
    Resource.create({
        "service.name": "web",
        "service.namespace": "default",
        "gcp.project_id": _project_id,
        # AppHub identity labels — GKE metadata server does not expose AppHub
        # context automatically, so we set these explicitly.
        # They must match the application_id and workload_id registered in apphub.tf.
        "gcp.apphub.application.container": f"projects/{_project_id}",
        "gcp.apphub.application.location": _region,
        "gcp.apphub.application.id": "apphub-demo",
        "gcp.apphub.workload.id": "web",
        "gcp.apphub.workload.criticality_type": "MISSION_CRITICAL",
        "gcp.apphub.workload.environment_type": "PRODUCTION",
    })
)

_otlp_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")

provider = TracerProvider(resource=resource)
if _otlp_endpoint:
    # SimpleSpanProcessor exports each span synchronously in the request thread.
    # BatchSpanProcessor starts a background thread that does NOT survive gunicorn's
    # pre-fork model — forked workers inherit the object but the export thread is dead,
    # so spans buffer forever and are never sent.
    provider.add_span_processor(SimpleSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)

# Instrument Flask (incoming requests) and requests (outgoing call to Cloud Run).
# RequestsInstrumentor automatically injects traceparent into outgoing headers.
# Exclude GKE metadata server endpoints — token fetch calls are internal noise.
RequestsInstrumentor().instrument(
    excluded_urls="metadata.google.internal,169.254.169.254,oauth2.googleapis.com"
)

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

tracer = trace.get_tracer(__name__)

USER_SERVICE_URL = os.environ["USER_SERVICE_URL"].rstrip("/")
_auth_req = google.auth.transport.requests.Request()


def _id_token() -> str:
    """Fetch a short-lived OIDC token for calling the Cloud Run service."""
    return google.oauth2.id_token.fetch_id_token(_auth_req, USER_SERVICE_URL)


@app.route("/user")
def user():
    user_id = request.args.get("user_id")
    if not user_id:
        return {"error": "user_id query parameter is required"}, 400

    downstream = f"{USER_SERVICE_URL}/user"
    headers = {"Authorization": f"Bearer {_id_token()}"}

    # AppHub topology: a client span emitted by the CALLING service (web) with
    # peer.service pointing to the CALLED service's AppHub service_id creates the
    # web → user-location edge in the topology graph.
    with tracer.start_as_current_span(
        "user-location.get_user",
        attributes={"peer.service": "user-location"},
    ):
        resp = http_client.get(downstream, params={"user_id": user_id}, headers=headers)
    return Response(
        resp.content,
        status=resp.status_code,
        content_type=resp.headers.get("Content-Type", "application/json"),
    )


@app.route("/healthz")
def healthz():
    return {"status": "ok"}, 200


@app.route("/", defaults={"path": ""})
@app.route("/<path:path>")
def catch_all(path):
    abort(404)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
