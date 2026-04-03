# AppHub Demo — GKE + Cloud Run + AlloyDB + Memorystore

A traditional application demonstrating end-to-end OTel tracing across GKE and Cloud Run, backed by AlloyDB (Postgres) and Memorystore (Redis), with AppHub topology visibility.

## Architecture

```
Internet
   │
   ▼
[GCP Forwarding Rule / K8s LoadBalancer Service :80]
   │
   ▼
[web Pod — GKE Deployment]
  Flask + OTel (HTTP exporter)
  spans → managed OTel Collector (gke-managed-otel)
        → Cloud Trace / Cloud Monitoring
   │
   │  traceparent header (W3C)
   ▼
[Cloud Run: user-location]
  Flask + OTel (gRPC exporter → telemetry.googleapis.com)
  peer.service=apphub-redis    peer.service=apphub-alloydb
   │                                  │
   ▼                                  ▼
[Memorystore Redis]           [AlloyDB for Postgres]
 span: redis.get               span: alloydb.query
```

### Components

| Component | Runtime | Role |
|---|---|---|
| `web` | GKE Deployment | Receives HTTP, proxies `/user` to `user-location` |
| `user-location` | Cloud Run | Checks Redis cache, falls back to AlloyDB |
| Memorystore Redis 7.0 | Managed | Cache layer |
| AlloyDB for Postgres | Managed | Source of truth for user records |
| OTel Collector | GKE managed (`gke-managed-otel`) | Receives OTLP from web pods, exports to Google Cloud |
| AppHub (`apphub-demo`) | AppHub | Topology and component registry |

### OTel Trace Export

| Service | Exporter | Endpoint |
|---|---|---|
| `web` (GKE) | HTTP OTLP | `http://opentelemetry-collector.gke-managed-otel.svc.cluster.local:4318` |
| `user-location` (Cloud Run) | gRPC OTLP | `telemetry.googleapis.com:443` (Google-managed) |

Cloud Run cannot reach the in-cluster collector, so it exports directly to Google's OTLP endpoint using ADC credentials.

---

## Repository Layout

```
apphub_demo/
├── cloudbuild.yaml             # Cloud Build — builds and pushes both images
├── terraform/
│   ├── main.tf                 # Provider config, API enablement (incl. apphub.googleapis.com)
│   ├── variables.tf            # project_id, region, zone, alloydb_password
│   ├── network.tf              # VPC, subnet, private services access, VPC connector
│   ├── gke.tf                  # GKE cluster + node pool (Workload Identity enabled)
│   ├── alloydb.tf              # AlloyDB cluster + PRIMARY instance
│   ├── redis.tf                # Memorystore Redis instance
│   ├── iam.tf                  # Service accounts, IAM bindings, Artifact Registry
│   ├── secrets.tf              # Secret Manager secret for DB password
│   ├── cloudrun.tf             # Cloud Run service + IAM invoke binding
│   ├── kubernetes.tf           # K8s service account, deployment, LB service (via TF)
│   ├── apphub.tf               # AppHub application + all component registrations
│   └── outputs.tf              # Useful resource references
├── web/                        # GKE web service
│   ├── app.py                  # Flask + OTel (HTTP exporter, GCP resource detector)
│   ├── requirements.txt
│   └── Dockerfile
├── user-location/              # Cloud Run user-location service
│   ├── app.py                  # Flask + OTel (gRPC exporter, GCP resource detector)
│   ├── requirements.txt
│   └── Dockerfile
├── k8s/                        # Kubernetes manifests
│   ├── serviceaccount.yaml     # web-sa with Workload Identity annotation
│   ├── deployment.yaml         # web deployment (OTEL_EXPORTER_OTLP_ENDPOINT set)
│   ├── service.yaml            # LoadBalancer service
│   └── otel-collector.yaml     # Instrumentation CR (telemetry.googleapis.com/v1alpha1)
└── scripts/
    └── seed_db.sql             # Creates users table and inserts sample rows
```

---

## Prerequisites

```bash
gcloud --version      # Google Cloud SDK >= 450
terraform --version   # >= 1.5
kubectl version       # any recent
```

> **No Docker required.** Images are built and pushed to Artifact Registry using **Cloud Build**.

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

# Preview
terraform plan -var="project_id=${PROJECT_ID}" -var="alloydb_password=YOUR_STRONG_PASSWORD"

# Apply (takes ~15–20 min; AlloyDB and GKE are the slow resources)
terraform apply -var="project_id=${PROJECT_ID}" -var="alloydb_password=YOUR_STRONG_PASSWORD"

# Capture outputs for later steps
export CLOUD_RUN_URL=$(terraform output -raw cloudrun_url)
export GKE_CLUSTER=$(terraform output -raw gke_cluster_name)
export GKE_ZONE=$(terraform output -raw gke_cluster_zone)
export AR_REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/apphub"
```

**What Terraform creates:**

| Resource | Description |
|---|---|
| `apphub-vpc` | Custom VPC with GKE secondary ranges |
| `apphub-connector` | Serverless VPC Access connector for Cloud Run → Redis/AlloyDB |
| `apphub-cluster` | GKE cluster (zone `us-central1-a`, 2× e2-standard-2, Workload Identity enabled) |
| `apphub-alloydb` | AlloyDB cluster + PRIMARY instance |
| `apphub-redis` | Memorystore Redis 7.0, BASIC tier, 1 GB |
| `apphub` | Artifact Registry Docker repo |
| `user-location` | Cloud Run v2 service |
| IAM | Two SAs (`apphub-gke-sa`, `apphub-cloudrun-sa`) with least-privilege roles |
| Secret Manager | `apphub-db-password` secret |
| AppHub `apphub-demo` | Application with web, user-location, Redis, AlloyDB, and LB components registered |

---

## Step 3 — Enable GKE Managed Telemetry

Enable the managed OpenTelemetry Operator on the cluster. This deploys the collector in the `gke-managed-otel` namespace automatically.

```bash
gcloud container clusters update apphub-cluster \
  --location=${ZONE} \
  --project=${PROJECT_ID} \
  --enable-managed-prometheus

# Verify the collector is running
kubectl get pods -n gke-managed-otel
# NAME                                       READY   STATUS    RESTARTS   AGE
# opentelemetry-collector-xxxxx-xxxxx        1/1     Running   0          ...
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

Cloud Build builds both images in parallel and pushes them to:
- `us-central1-docker.pkg.dev/${PROJECT_ID}/apphub/web:latest`
- `us-central1-docker.pkg.dev/${PROJECT_ID}/apphub/user-location:latest`

---

## Step 5 — Deploy Cloud Run with the built image

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

# Apply Kubernetes manifests
kubectl apply -f k8s/serviceaccount.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Apply the managed OTel Instrumentation CR
# (configures SDK env vars for pods with app=web, pointing to the managed collector)
kubectl apply -f k8s/otel-collector.yaml

# Wait for rollout
kubectl rollout status deployment/web

# Get the external IP (takes 1–2 min for the LB to provision)
export LB_IP=$(kubectl get service web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "LoadBalancer IP: ${LB_IP}"
```

---

## Step 7 — Seed AlloyDB

AlloyDB has no public IP; connect from inside the VPC using a one-shot pod in GKE:

```bash
ALLOYDB_IP=$(gcloud alloydb instances describe apphub-primary \
  --cluster=apphub-alloydb --region=${REGION} --project=${PROJECT_ID} \
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
CREATE TABLE users (user_id VARCHAR(64) PRIMARY KEY, user_name VARCHAR(255) NOT NULL);
-- Inserts: u1 → Alice Smith, u2 → Bob Jones, u3 → Carol Williams
```

---

## Step 8 — Test end-to-end

```bash
LB_IP=$(kubectl get service web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Health check
curl "http://${LB_IP}/healthz"
# → {"status":"ok"}

# AlloyDB path (first request — cache cold)
curl "http://${LB_IP}/user?user_id=u1"
# → {"result":"Alice Smith","source":"database"}

# Repeat (Redis still cold — no write path in demo)
curl "http://${LB_IP}/user?user_id=u2"
# → {"result":"Bob Jones","source":"database"}

# Unknown user
curl "http://${LB_IP}/user?user_id=u999"
# → {"error":"user not found"}

# Missing param
curl "http://${LB_IP}/user"
# → {"error":"user_id query parameter is required"}

# Generate load for AppHub topology
for i in {1..10}; do
  for uid in u1 u2 u3; do
    curl -s "http://${LB_IP}/user?user_id=${uid}" > /dev/null
  done
done
echo "Done"
```

---

## Step 9 — Rebuild and redeploy after code changes

Use Cloud Build — no Docker needed locally:

```bash
cd apphub_demo

# Rebuild both images and push
gcloud builds submit \
  --config cloudbuild.yaml \
  --project=${PROJECT_ID} \
  .

# Redeploy Cloud Run
gcloud run services update user-location \
  --image "${AR_REPO}/user-location:latest" \
  --region ${REGION} \
  --project ${PROJECT_ID}

# Redeploy GKE web (rolling restart picks up new :latest image)
kubectl rollout restart deployment/web
kubectl rollout status deployment/web
```

---

## Observability

### Cloud Trace
View distributed traces at [Cloud Trace](https://console.cloud.google.com/traces). Each request spans `web → user-location → alloydb.query` (and `redis.get`), linked by the W3C `traceparent` header.

### AppHub Topology Viewer
The `apphub-demo` application in [AppHub](https://console.cloud.google.com/apphub) shows the topology built from traces:

```
web (GKE Workload)
  └─► user-location (Cloud Run Service)    [via peer.service]
        ├─► apphub-redis (Memorystore)     [via peer.service + db.system=redis]
        └─► apphub-alloydb (AlloyDB)       [via peer.service + db.system=postgresql]
```

Registered AppHub components:

| Component | AppHub Kind | Trace attribute |
|---|---|---|
| `web-forwarding-rule` | Service | GCP Forwarding Rule |
| `web-lb-service` | Service | K8s LoadBalancer Service |
| `web` | Workload | `service.name=web` |
| `user-location` | Service | `service.name=user-location` |
| `apphub-redis` | Service | `peer.service=apphub-redis` |
| `apphub-alloydb` | Service | `peer.service=apphub-alloydb` |

> Allow 5–10 minutes after generating traffic for the topology viewer to reflect new trace data.

---

## IAM Summary

| Service Account | Roles |
|---|---|
| `apphub-gke-sa` | `logging.logWriter`, `monitoring.metricWriter`, `cloudtrace.agent`, `artifactregistry.reader`, `run.invoker` |
| `apphub-cloudrun-sa` | `alloydb.client`, `alloydb.databaseUser`, `cloudtrace.agent`, `logging.logWriter` |

GKE pods authenticate to GCP APIs via **Workload Identity**: the Kubernetes service account `web-sa` is bound to `apphub-gke-sa`, allowing pods to obtain OIDC tokens to call Cloud Run without storing any key files.
