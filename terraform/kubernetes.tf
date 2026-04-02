resource "kubernetes_service_account_v1" "web_sa" {
  metadata {
    name      = "web-sa"
    namespace = "default"
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.gke_sa.email
    }
  }
}

resource "kubernetes_deployment_v1" "web" {
  metadata {
    name = "web"
    labels = { app = "web" }
  }
  wait_for_rollout = false
  spec {
    replicas = 2
    selector { match_labels = { app = "web" } }
    template {
      metadata { labels = { app = "web" } }
      spec {
        service_account_name = kubernetes_service_account_v1.web_sa.metadata[0].name
        container {
          name  = "web"
          image = "${var.region}-docker.pkg.dev/${var.project_id}/apphub/web:latest"
          port { container_port = 8080 }
          env {
            name  = "USER_SERVICE_URL"
            value = google_cloud_run_v2_service.user_location.uri
          }
          env {
            name  = "GOOGLE_CLOUD_PROJECT"
            value = var.project_id
          }
        }
      }
    }
  }
  lifecycle {
    # Correct path for GKE deployment image ignoring
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image
    ]
  } 
}

resource "kubernetes_service_v1" "web_lb" {
  metadata { name = "web" }
  spec {
    selector = { app = "web" }
    port {
      port        = 80
      target_port = 8080
    }
    type = "LoadBalancer"
  }
}
