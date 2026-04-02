import os
import grpc
import google.auth
import google.auth.transport.requests
import google.auth.transport.grpc
import google.oauth2.id_token
import requests as http_client
from flask import Flask, request, Response, abort

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

# ── OTel setup ──────────────────────────────────────────────────────────────
_project_id = os.environ.get("GOOGLE_CLOUD_PROJECT", "")
resource = Resource.create({
    "service.name": "web",
    "gcp.project_id": _project_id,
})

# Authenticate OTLP gRPC channel with Google Cloud ADC (service account in GKE/Cloud Run)
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
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(
        endpoint="telemetry.googleapis.com:443",
        credentials=_grpc_creds,
    ))
)
trace.set_tracer_provider(provider)

# Instrument Flask (incoming requests) and requests (outgoing call to Cloud Run)
# RequestsInstrumentor automatically injects traceparent into outgoing headers.
FlaskInstrumentor().instrument_app  # applied below, after app creation
RequestsInstrumentor().instrument()

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

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

    # peer.service links this outgoing span to the user-location node in AppHub topology
    with trace.get_tracer(__name__).start_as_current_span(
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
