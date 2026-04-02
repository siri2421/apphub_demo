# AppHub Demo — GKE + Cloud Run + AlloyDB + Memorystore

A traditional application demonstrating end-to-end OTel tracing across GKE and Cloud Run, backed by AlloyDB (Postgres) and Memorystore (Redis).

## Architecture

```
Internet
   │
   ▼
[GKE LoadBalancer :80]
   │
   ▼
[web pod] ──── traceparent header ────► [Cloud Run: user-location]
  (Flask + OTel)                              (Flask + OTel)
  spans → Cloud Trace                           │         │
                                             [Redis]  [AlloyDB]
                                         (span: redis.get) (span: alloydb.query)
```

### Components

| Component | Runtime | Role |
|---|---|---|
| `web` | GKE Deployment | Receives HTTP requests, routes `/user` to `user-location`, returns 404 otherwise |
| `user-location` | Cloud Run | Checks Redis cache, falls back to AlloyDB, returns user data |
| Memorystore Redis 7.0 | Managed | Caches `user_id → "(city, state)"` strings |
| AlloyDB for Postgres | Managed | Source of truth for user records |

### OTel Trace Propagation

1. `FlaskInstrumentor` on `web` creates a root span for each inbound request.
2. `RequestsInstrumentor` on `web` injects the W3C `traceparent` header into the outgoing call to Cloud Run.
3. `FlaskInstrumentor` on `user-location` extracts `traceparent`, creating a child span under the same trace.
4. Manual spans (`redis.get`, `alloydb.query`) are created as children of that span.
5. Both services export to **Cloud Trace** via `CloudTraceSpanExporter`. The shared trace ID links them in the topology view.

---

## Repository Layout

```
apphub_demo/
├── terraform/              # All GCP infrastructure
│   ├── main.tf             # Provider config + API enablement
│   ├── variables.tf        # project_id, region, zone, alloydb_password
│   ├── network.tf          # VPC, subnet, private services access, VPC connector
│   ├── gke.tf              # GKE cluster + node pool
│   ├── alloydb.tf          # AlloyDB cluster + PRIMARY instance
│   ├── redis.tf            # Memorystore Redis instance
│   ├── iam.tf              # Service accounts, IAM bindings, Artifact Registry
│   ├── secrets.tf          # Secret Manager secret for DB password
│   ├── cloudrun.tf         # Cloud Run service + IAM invoke binding
│   └── outputs.tf          # Useful resource references
├── web/                    # GKE web service
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── user-location/          # Cloud Run user-location service
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── k8s/                    # Kubernetes manifests
│   ├── serviceaccount.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── scripts/
    └── seed_db.sql         # Creates users table and inserts sample rows
```

---

## Prerequisites

```bash
gcloud --version      # Google Cloud SDK >= 450
terraform --version   # >= 1.5
kubectl version       # any recent
docker --version      # any recent
```

---

## Step 1 — Authenticate and set your project

```bash
export PROJECT_ID="siri-infra"
export REGION="us-central1"
export ZONE="us-central1-a"
export AR_HOST="${REGION}-docker.pkg.dev"

gcloud auth login
gcloud config set project $PROJECT_ID
gcloud auth configure-docker ${AR_HOST}
```

---

## Step 2 — Provision infrastructure with Terraform

```bash
cd apphub_demo/terraform

# Initialize providers
terraform init

# Preview what will be created
terraform plan -var="alloydb_password=YOUR_STRONG_PASSWORD"

# Apply (takes ~15–20 min; AlloyDB and GKE are the slow resources)
terraform apply -var="alloydb_password=YOUR_STRONG_PASSWORD"

# Capture outputs for later steps
export REDIS_HOST=$(terraform output -raw redis_host)
export ALLOYDB_INSTANCE=$(terraform output -raw alloydb_instance_name)
export CLOUD_RUN_URL=$(terraform output -raw cloudrun_url)
export AR_REPO=$(terraform output -raw artifact_registry)
export GKE_CLUSTER=$(terraform output -raw gke_cluster_name)
export GKE_ZONE=$(terraform output -raw gke_cluster_zone)
```

**What Terraform creates:**

| Resource | Description |
|---|---|
| `apphub-vpc` | Custom VPC with GKE secondary ranges |
| `apphub-connector` | Serverless VPC Access connector for Cloud Run → Redis/AlloyDB |
| `apphub-cluster` | GKE cluster (zone `us-central1-a`, 2× e2-standard-2) |
| `apphub-alloydb` | AlloyDB cluster + PRIMARY instance |
| `apphub-redis` | Memorystore Redis 7.0, BASIC tier, 1 GB |
| `apphub` | Artifact Registry Docker repo |
| `user-location` | Cloud Run v2 service (image built in step 3) |
| IAM | Two SAs (`apphub-gke-sa`, `apphub-cloudrun-sa`) with least-privilege roles |
| Secret Manager | `apphub-db-password` secret |

---

## Step 3 — Build and push Docker images

```bash
cd apphub_demo

# Build and push the web (GKE) image
docker build -t ${AR_REPO}/web:latest ./web
docker push ${AR_REPO}/web:latest

# Build and push the user-location (Cloud Run) image
docker build -t ${AR_REPO}/user-location:latest ./user-location
docker push ${AR_REPO}/user-location:latest
```

---

## Step 4 — Redeploy Cloud Run with the built image

Terraform deployed Cloud Run referencing `:latest`; after pushing the real image, trigger a new revision:

```bash
gcloud run deploy user-location \
  --image "${AR_REPO}/user-location:latest" \
  --region $REGION \
  --project $PROJECT_ID

# Confirm it is healthy
TOKEN=$(gcloud auth print-identity-token --audiences=$CLOUD_RUN_URL)
curl -H "Authorization: Bearer $TOKEN" "${CLOUD_RUN_URL}/healthz"
# → {"status": "ok"}
```

---

## Step 5 — Deploy the web service to GKE

```bash
# Get cluster credentials
gcloud container clusters get-credentials $GKE_CLUSTER \
  --zone $GKE_ZONE --project $PROJECT_ID

# Substitute placeholders in manifests
sed -i "s|PROJECT_ID|${PROJECT_ID}|g" k8s/serviceaccount.yaml k8s/deployment.yaml
sed -i "s|REGION|${REGION}|g"         k8s/deployment.yaml
sed -i "s|CLOUD_RUN_URL|${CLOUD_RUN_URL}|g" k8s/deployment.yaml

# Apply all manifests
kubectl apply -f k8s/serviceaccount.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Wait for pods to be ready
kubectl rollout status deployment/web

# Get the external IP (takes 1–2 min for the LB to provision)
kubectl get service web
```

---

## Step 6 — Seed AlloyDB

AlloyDB has no public IP; connect from inside the VPC. Use a one-shot pod in GKE or Cloud Shell if it has VPC access.

**Option A — kubectl run (recommended)**

```bash
# Get the AlloyDB private IP
ALLOYDB_IP=$(gcloud alloydb instances describe apphub-primary \
  --cluster=apphub-alloydb --region=$REGION \
  --format="value(ipAddresses[0].ipAddress)")

kubectl run psql-seed --rm -it \
  --image=postgres:16 \
  --restart=Never \
  --env="PGPASSWORD=YOUR_STRONG_PASSWORD" \
  -- psql -h $ALLOYDB_IP -U postgres -d postgres \
     -c "$(cat scripts/seed_db.sql)"
```

**Option B — psql from Cloud Shell**

```bash
ALLOYDB_IP=$(gcloud alloydb instances describe apphub-primary \
  --cluster=apphub-alloydb --region=$REGION \
  --format="value(ipAddresses[0].ipAddress)")

PGPASSWORD=YOUR_STRONG_PASSWORD psql \
  -h $ALLOYDB_IP -U postgres -d postgres \
  -f scripts/seed_db.sql
```

The seed script creates:

```sql
CREATE TABLE users (user_id VARCHAR(64) PRIMARY KEY, user_name VARCHAR(255) NOT NULL);
-- Inserts: u1 → Alice Smith, u2 → Bob Jones, u3 → Carol Williams
```

---

## Step 7 — (Optional) Pre-seed Redis cache

To demonstrate the Redis cache hit path, write a location string for a user:

```bash
kubectl run redis-seed --rm -it \
  --image=redis:7 \
  --restart=Never \
  -- redis-cli -h $REDIS_HOST SET u1 "(San Francisco, CA)"
```

---

## Step 8 — Test end-to-end

```bash
LB_IP=$(kubectl get service web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Cache hit (u1, if step 7 was run)
curl "http://${LB_IP}/user?user_id=u1"
# → {"result": "(San Francisco, CA)", "source": "cache"}

# AlloyDB fallback
curl "http://${LB_IP}/user?user_id=u2"
# → {"result": "Bob Jones", "source": "database"}

# Unknown user
curl -v "http://${LB_IP}/user?user_id=unknown"
# → 404  {"error": "user not found"}

# Non-/user path
curl -v "http://${LB_IP}/other"
# → 404
```

View distributed traces in [Cloud Trace](https://console.cloud.google.com/traces) — each request from `web` to `user-location` appears as a single trace with child spans for the Redis and AlloyDB operations.

---

## IAM Summary

| Service Account | Roles |
|---|---|
| `apphub-gke-sa` | `logging.logWriter`, `monitoring.metricWriter`, `cloudtrace.agent`, `run.invoker` |
| `apphub-cloudrun-sa` | `alloydb.client`, `alloydb.databaseUser`, `cloudtrace.agent`, `logging.logWriter`, `secretmanager.secretAccessor` |

GKE pods authenticate to GCP APIs via **Workload Identity**: the Kubernetes service account `web-sa` is bound to `apphub-gke-sa`, so pods can obtain OIDC tokens to call Cloud Run without storing any key files.
