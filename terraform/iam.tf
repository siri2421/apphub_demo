# ── GKE node service account ──────────────────────────────────────────────────
resource "google_service_account" "gke_sa" {
  account_id   = "apphub-gke-sa"
  display_name = "AppHub GKE Node Service Account"
}

resource "google_project_iam_member" "gke_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

resource "google_project_iam_member" "gke_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

resource "google_project_iam_member" "gke_trace" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

# Allow GKE pods (via Workload Identity) to invoke Cloud Run
resource "google_project_iam_member" "gke_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

# ── Kubernetes Service Account → Workload Identity binding ────────────────────
# The KSA "web-sa" in namespace "default" will impersonate apphub-gke-sa
resource "google_service_account_iam_member" "gke_workload_identity" {
  service_account_id = google_service_account.gke_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/web-sa]"
}

# ── Cloud Run service account ─────────────────────────────────────────────────
resource "google_service_account" "cloudrun_sa" {
  account_id   = "apphub-cloudrun-sa"
  display_name = "AppHub Cloud Run Service Account"
}

resource "google_project_iam_member" "cloudrun_alloydb_client" {
  project = var.project_id
  role    = "roles/alloydb.client"
  member  = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

resource "google_project_iam_member" "cloudrun_alloydb_db_user" {
  project = var.project_id
  role    = "roles/alloydb.databaseUser"
  member  = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

resource "google_project_iam_member" "cloudrun_trace" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

resource "google_project_iam_member" "cloudrun_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
resource "google_artifact_registry_repository" "apphub_repo" {
  location      = var.region
  repository_id = "apphub"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}
