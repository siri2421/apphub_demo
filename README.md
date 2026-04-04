# AppHub Demo — GKE + Cloud Run + AlloyDB + Memorystore

End-to-end distributed tracing demo across GKE (L7 Gateway API) and Cloud Run, backed by AlloyDB (Postgres) and Memorystore (Redis), with AppHub topology visibility via W3C Trace Context propagation.

---

## Architecture

```
Internet
   │
   ▼
[GKE Gateway API — L7 Global External HTTP LB]
  GatewayClass: gke-l7-global-external-managed
  HTTPRoute: web → Service web:80
   │
   │  HTTP/1.1 (routed via NEG to pod IP)
   ▼
[web Pod — GKE Deployment]
  Flask + OTel (HTTP OTLP exporter)
  W3C traceparent header propagation
  resource: service.name=web, service.namespace=default
  spans → managed OTel Collector (gke-managed-otel:4318)
        → Cloud Trace / Cloud Monitoring
   │
   │  HTTPS + traceparent header (W3C Trace Context)
   │  Authorization: Bearer <OIDC token via Workload Identity>
   ▼
[Cloud Run: user-location]
  Flask + OTel (gRPC OTLP → telemetry.googleapis.com:443)
  W3C traceparent header propagation
  resource: service.name=user-location, service.namespace=default
  peer.service=apphub-redis    peer.service=apphub-alloydb
   │                                  │
   ▼                                  ▼
[Memorystore Redis 7.0]       [AlloyDB for PostgreSQL]
  span: redis.get               span: alloydb.query
  db.system=redis               db.system=postgresql
```

### Components

| Component | Runtime | Role |
|---|---|---|
| `web` | GKE Deployment (2 replicas) | Receives HTTP via L7 LB, authenticates and proxies `/user` to `user-location` via Workload Identity OIDC |
| `user-location` | Cloud Run v2 | Checks Redis cache, falls back to AlloyDB for user lookups |
| GKE Gateway | GKE Gateway API (`gke-l7-global-external-managed`) | L7 HTTP load balancer, NEG-backed, health check on `/healthz` |
| Memorystore Redis 7.0 | Managed | Cache layer — keyed by `user_id` |
| AlloyDB for PostgreSQL | Managed | Source of truth for user records |
| OTel Collector | GKE managed (`gke-managed-otel`) | Receives OTLP/HTTP from `web` pods, exports to Cloud Trace + Cloud Monitoring |
| AppHub (`apphub-demo`) | AppHub | Topology and component registry for all services |

### OTel Trace Export

| Service | Exporter | Endpoint | Why |
|---|---|---|---|
| `web` (GKE) | OTLP HTTP | `http://opentelemetry-collector.gke-managed-otel.svc.cluster.local:4318` | In-cluster collector handles GCP auth |
| `user-location` (Cloud Run) | OTLP gRPC | `telemetry.googleapis.com:443` | Cloud Run cannot reach the in-cluster collector; uses ADC credentials directly |

### OTel Configuration in Code (both services)

- **Propagator**: W3C Trace Context (`TraceContextTextMapPropagator`) — ensures `traceparent` header is read on ingress and injected on egress
- **Resource detection**: `GoogleCloudResourceDetector` provides GCP/GKE attributes (`cloud.platform`, `k8s.cluster.name`, `k8s.namespace.name`, `k8s.pod.name`) as the base resource; `service.name` and `service.namespace` are merged on top
- **`service.namespace`**: Set to `"default"` (matches the Kubernetes namespace) — AppHub uses this to distinguish services within the same project

---

## Repository Layout

```
apphub_demo/
├── cloudbuild.yaml             # Cloud Build — builds and pushes both images
├── terraform/
│   ├── main.tf                 # Provider config, API enablement
│   ├── variables.tf            # project_id, region, zone, alloydb_password
│   ├── network.tf              # VPC, subnet, private services access, VPC connector
│   ├── gke.tf                  # GKE cluster + node pool (Workload Identity, Gateway API enabled)
│   ├── alloydb.tf              # AlloyDB cluster + PRIMARY instance
│   ├── redis.tf                # Memorystore Redis instance
│   ├── iam.tf                  # Service accounts, IAM bindings, Artifact Registry
│   ├── secrets.tf              # Secret Manager secret for DB password
│   ├── cloudrun.tf             # Cloud Run service + IAM invoke binding
│   ├── kubernetes.tf           # K8s service account, deployment, ClusterIP service (via TF)
│   ├── apphub.tf               # AppHub application + all component registrations
│   └── outputs.tf              # Useful resource references
├── web/                        # GKE web service
│   ├── app.py                  # Flask + OTel HTTP exporter, W3C propagator, GCP resource detector
│   ├── requirements.txt        # opentelemetry-exporter-otlp-proto-http
│   └── Dockerfile
├── user-location/              # Cloud Run user-location service
│   ├── app.py                  # Flask + OTel gRPC exporter, W3C propagator, GCP resource detector
│   ├── requirements.txt        # opentelemetry-exporter-otlp-proto-grpc
│   └── Dockerfile
└── k8s/                        # Kubernetes manifests
    ├── serviceaccount.yaml     # web-sa with Workload Identity annotation
    ├── deployment.yaml         # web Deployment (OTEL_EXPORTER_OTLP_ENDPOINT=:4318)
    ├── service.yaml            # ClusterIP Service + Gateway + HTTPRoute + HealthCheckPolicy
    └── otel-collector.yaml     # Instrumentation CR (telemetry.googleapis.com/v1alpha1)
```

---

## Prerequisites

```bash
gcloud --version      # >= 450
terraform --version   # >= 1.5
kubectl version       # any recent
```

> **No Docker required locally.** Images are built and pushed using **Cloud Build**.

---

## Step 1 — Authenticate and set your project

```bash
export PROJECT_ID="agentic-marketing-demo"
export REGION="us-central1"
export ZONE="us-central1-a"

gcloud auth login
gcloud auth application-default login
gcloud config set project $PROJECT_ID
```

---

## Step 2 — Provision infrastructure with Terraform

```bash
cd apphub_demo/terraform

terraform init

# Preview all changes
terraform plan \
  -var="project_id=${PROJECT_ID}" \
  -var="alloydb_password=YOUR_STRONG_PASSWORD"

# Apply (takes ~15–20 min; AlloyDB, GKE, and Gateway API enablement are the slow resources)
terraform apply \
  -var="project_id=${PROJECT_ID}" \
  -var="alloydb_password=YOUR_STRONG_PASSWORD"

# Capture outputs
export CLOUD_RUN_URL=$(terraform output -raw cloudrun_url)
export GKE_CLUSTER=$(terraform output -raw gke_cluster_name)
export GKE_ZONE=$(terraform output -raw gke_cluster_zone)
export AR_REPO=$(terraform output -raw artifact_registry)
```

**What Terraform provisions:**

| Resource | Details |
|---|---|
| `apphub-vpc` | Custom VPC with GKE pod/service secondary ranges |
| `apphub-connector` | Serverless VPC Access connector for Cloud Run → Redis/AlloyDB |
| `apphub-cluster` | GKE cluster — zone `us-central1-a`, 2× e2-standard-2, Workload Identity + **Gateway API (`CHANNEL_STANDARD`)** enabled |
| `apphub-alloydb` | AlloyDB cluster + PRIMARY instance |
| `apphub-redis` | Memorystore Redis 7.0, BASIC tier, 1 GB |
| `apphub` (AR) | Artifact Registry Docker repository |
| `user-location` | Cloud Run v2 service (VPC egress for private networking) |
| IAM | `apphub-gke-sa`, `apphub-cloudrun-sa` with least-privilege roles |
| Secret Manager | `apphub-db-password` |
| AppHub `apphub-demo` | Application with web workload, user-location, Redis, and AlloyDB services registered |

---

## Step 3 — Enable GKE Managed Telemetry

Deploys the OTel Collector in the `gke-managed-otel` namespace automatically.

```bash
gcloud container clusters update apphub-cluster \
  --location=${ZONE} \
  --project=${PROJECT_ID} \
  --enable-managed-prometheus

# Verify the collector is running
kubectl get pods -n gke-managed-otel
# NAME                                    READY   STATUS    RESTARTS   AGE
# opentelemetry-collector-xxxxx-xxxxx     1/1     Running   0          ...
```

---

## Step 4 — Build and push images with Cloud Build

```bash
cd apphub_demo

gcloud builds submit \
  --config cloudbuild.yaml \
  --project=${PROJECT_ID} \
  .
```

Cloud Build builds and pushes:
- `us-central1-docker.pkg.dev/${PROJECT_ID}/apphub/web:latest`
- `us-central1-docker.pkg.dev/${PROJECT_ID}/apphub/user-location:latest`

---

## Step 5 — Deploy Cloud Run

```bash
gcloud run services update user-location \
  --image "${AR_REPO}/user-location:latest" \
  --region ${REGION} \
  --project ${PROJECT_ID}

# Confirm healthy
TOKEN=$(gcloud auth print-identity-token --audiences=${CLOUD_RUN_URL})
curl -H "Authorization: Bearer $TOKEN" "${CLOUD_RUN_URL}/healthz"
# → {"status": "ok"}
```

---

## Step 6 — Deploy the web service to GKE

```bash
# Get cluster credentials
gcloud container clusters get-credentials ${GKE_CLUSTER} \
  --zone ${GKE_ZONE} --project ${PROJECT_ID}

# Apply all manifests (Service, Gateway, HTTPRoute, HealthCheckPolicy, OTel CR)
kubectl apply -f k8s/serviceaccount.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/otel-collector.yaml

# Wait for deployment rollout
kubectl rollout status deployment/web

# Get the L7 Gateway external IP (takes 2–5 min for GCP to fully program the LB)
export GW_IP=$(kubectl get gateway web -n default -o jsonpath='{.status.addresses[0].value}')
echo "Gateway IP: ${GW_IP}"
```

> The `k8s/service.yaml` creates four resources:
> 1. **ClusterIP Service** — with NEG annotation (`cloud.google.com/neg`) so GKE registers pod IPs as network endpoints
> 2. **Gateway** — provisions the global L7 external HTTP LB (`gke-l7-global-external-managed`)
> 3. **HTTPRoute** — routes all traffic to the `web` service on port 80
> 4. **HealthCheckPolicy** — configures the GCP health check to use `/healthz` on port 8080

---

## Step 7 — Seed AlloyDB

AlloyDB has no public IP. Connect via a one-shot pod inside the GKE cluster:

```bash
ALLOYDB_IP=$(gcloud alloydb instances describe apphub-primary \
  --cluster=apphub-alloydb \
  --region=${REGION} \
  --project=${PROJECT_ID} \
  --format="value(ipAddresses[0].ipAddress)")

kubectl run psql-seed --rm -it \
  --image=postgres:16 \
  --restart=Never \
  --env="PGPASSWORD=YOUR_STRONG_PASSWORD" \
  -- psql -h ${ALLOYDB_IP} -U postgres -d postgres \
     -c "$(cat scripts/seed_db.sql)"
```

The seed script creates:

```sql
CREATE TABLE users (
  user_id   VARCHAR(64)  PRIMARY KEY,
  user_name VARCHAR(255) NOT NULL
);
-- Sample rows: u1 → Alice Smith, u2 → Bob Jones, u3 → Carol Williams
```

---

## Step 8 — End-to-end flow test

```bash
export GW_IP=$(kubectl get gateway web -n default -o jsonpath='{.status.addresses[0].value}')

# 1. Health check — verifies L7 LB → web pod
curl "http://${GW_IP}/healthz"
# → {"status":"ok"}

# 2. User lookup — full flow: L7 LB → web → user-location → AlloyDB
curl "http://${GW_IP}/user?user_id=u1"
# → {"result":"Alice Smith","source":"database"}

# 3. Second user — verify routing works across replicas
curl "http://${GW_IP}/user?user_id=u2"
# → {"result":"Bob Jones","source":"database"}

# 4. Unknown user — validates AlloyDB 404 path
curl "http://${GW_IP}/user?user_id=u999"
# → {"error":"user not found"}

# 5. Missing param — validates web-layer input validation
curl "http://${GW_IP}/user"
# → {"error":"user_id query parameter is required"}

# 6. Verify GCP backend health (all should be HEALTHY)
gcloud compute backend-services get-health \
  $(gcloud compute backend-services list --global --project=${PROJECT_ID} \
    --filter="name~gkegw.*default-web" --format="value(name)") \
  --global --project=${PROJECT_ID} \
  --format="yaml(status.healthStatus[].healthState)"

# 7. Generate load to populate AppHub topology
for i in {1..20}; do
  for uid in u1 u2 u3; do
    curl -s "http://${GW_IP}/user?user_id=${uid}" > /dev/null
  done
done
echo "Done — check Cloud Trace and AppHub topology in ~5 minutes"
```

---

## Step 9 — Rebuild and redeploy after code changes

```bash
cd apphub_demo

# Rebuild and push both images
gcloud builds submit \
  --config cloudbuild.yaml \
  --project=${PROJECT_ID} \
  .

# Redeploy Cloud Run (picks up new :latest)
gcloud run services update user-location \
  --image "${AR_REPO}/user-location:latest" \
  --region ${REGION} \
  --project ${PROJECT_ID}

# Rolling restart GKE web pods to pick up new :latest image
kubectl rollout restart deployment/web
kubectl rollout status deployment/web
```

---

## Observability

### Cloud Trace

View distributed traces at [console.cloud.google.com/traces](https://console.cloud.google.com/traces).

Each request produces a trace spanning:
```
web (Flask inbound)
  └─► user-location.get_user (outbound span, peer.service=user-location)
        └─► flask.get_user (Cloud Run inbound)
              ├─► redis.get       (db.system=redis)
              └─► alloydb.query   (db.system=postgresql)
```

All spans are linked by the W3C `traceparent` header injected by `RequestsInstrumentor` in the `web` service and read by `FlaskInstrumentor` in `user-location`.

### AppHub Topology Viewer

The `apphub-demo` application in [console.cloud.google.com/apphub](https://console.cloud.google.com/apphub) renders the dependency graph:

```
web (GKE Workload)
  └─► user-location (Cloud Run Service)   [peer.service=user-location]
        ├─► apphub-redis (Memorystore)    [peer.service=apphub-redis, db.system=redis]
        └─► apphub-alloydb (AlloyDB)      [peer.service=apphub-alloydb, db.system=postgresql]
```

**Registered AppHub components:**

| Component ID | AppHub Kind | Maps to |
|---|---|---|
| `web` | Workload | GKE Deployment `web` in namespace `default` |
| `web-lb-service` | Service | K8s ClusterIP Service `web` (Gateway API L7 LB) |
| `user-location` | Service | Cloud Run service `user-location` |
| `apphub-redis` | Service | Memorystore Redis instance |
| `apphub-alloydb` | Service | AlloyDB instance |

> Allow 5–10 minutes after generating traffic for the topology viewer to reflect new trace data.

---

## IAM Summary

| Service Account | Bound to | Roles |
|---|---|---|
| `apphub-gke-sa` | GKE node pool + K8s SA `web-sa` (Workload Identity) | `logging.logWriter`, `monitoring.metricWriter`, `cloudtrace.agent`, `artifactregistry.reader`, `run.invoker` |
| `apphub-cloudrun-sa` | Cloud Run `user-location` | `alloydb.client`, `alloydb.databaseUser`, `cloudtrace.agent`, `logging.logWriter`, `secretmanager.secretAccessor` |

GKE pods authenticate to Cloud Run via **Workload Identity**: the K8s service account `web-sa` is bound to `apphub-gke-sa`, enabling pods to mint OIDC tokens for Cloud Run invocation without storing any key files.

---

## Troubleshooting

### Gateway returns `no healthy upstream`

The GCP L7 backend may not be ready yet, or the health check path is wrong.

```bash
# Check backend health
gcloud compute backend-services get-health \
  $(gcloud compute backend-services list --global --project=${PROJECT_ID} \
    --filter="name~gkegw.*default-web" --format="value(name)") \
  --global --project=${PROJECT_ID}

# Check HealthCheckPolicy is applied
kubectl get healthcheckpolicy web -n default

# Check Gateway status
kubectl describe gateway web -n default
```

Wait 2–5 minutes after first deploying the Gateway for GCP to fully program the load balancer.

### Pods in CrashLoopBackOff

```bash
kubectl logs -n default -l app=web --tail=50
```

Common causes:
- Missing OTel package — check `web/requirements.txt` matches the import in `web/app.py`
- Missing `USER_SERVICE_URL` env var — verify `k8s/deployment.yaml`

### Traces not appearing in Cloud Trace

```bash
# Verify the managed collector is running
kubectl get pods -n gke-managed-otel

# Check OTLP endpoint in the deployment
kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].env}' | jq .

# Expected: OTEL_EXPORTER_OTLP_ENDPOINT = http://opentelemetry-collector.gke-managed-otel.svc.cluster.local:4318
```

### AlloyDB connection refused

AlloyDB is private-IP only. Ensure:
- Cloud Run has VPC egress via `apphub-connector`
- `ALLOYDB_HOST` env var is the correct private IP
- `DB_PASSWORD` secret version is current in Secret Manager
