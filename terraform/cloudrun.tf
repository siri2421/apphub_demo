resource "google_cloud_run_v2_service" "user_location" {
  name     = "user-location"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.cloudrun_sa.email

    vpc_access {
      connector = google_vpc_access_connector.connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/apphub/user-location:latest"

      env {
        name  = "REDIS_HOST"
        value = google_redis_instance.apphub_redis.host
      }
      env {
        name  = "REDIS_PORT"
        value = tostring(google_redis_instance.apphub_redis.port)
      }
      env {
        name  = "ALLOYDB_HOST"
        value = google_alloydb_instance.apphub_primary.ip_address
      }
      env {
        name  = "DB_USER"
        value = "postgres"
      }
      env {
        name  = "DB_NAME"
        value = "postgres"
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
    }

    # OTel Collector sidecar — receives OTLP from the app on localhost and
    # exports to Cloud Trace using the service account credentials via ADC.
    containers {
      name  = "otel-collector"
      image = "${var.region}-docker.pkg.dev/${var.project_id}/apphub/otel-collector:latest"

      resources {
        limits = {
          cpu    = "0.5"
          memory = "256Mi"
        }
      }
    }
  }

  depends_on = [
    google_vpc_access_connector.connector,
    google_alloydb_instance.apphub_primary,
    google_redis_instance.apphub_redis,
    google_secret_manager_secret_version.db_password,
    google_project_service.apis,
  ]
}

# Allow the GKE service account to invoke the Cloud Run service
resource "google_cloud_run_v2_service_iam_member" "gke_invoker" {
  location = google_cloud_run_v2_service.user_location.location
  name     = google_cloud_run_v2_service.user_location.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.gke_sa.email}"
}
