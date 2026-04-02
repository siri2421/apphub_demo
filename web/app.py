import os
import google.auth.transport.requests
import google.oauth2.id_token
import requests as http_client
from flask import Flask, request, Response, abort

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

# ── OTel setup ──────────────────────────────────────────────────────────────
# W3C TraceContext (traceparent) is the default propagator; Cloud Trace
# understands it, so spans from this service and user-location are linked.
provider = TracerProvider()
provider.add_span_processor(
    BatchSpanProcessor(CloudTraceSpanExporter())
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
