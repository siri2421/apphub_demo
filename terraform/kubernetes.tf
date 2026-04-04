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
          env {
            name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
            value = "http://opentelemetry-collector.gke-managed-otel.svc.cluster.local:4318"
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
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
  metadata {
    name      = "web"
    namespace = "default"
    annotations = {
      # Named NEG "web-neg" matches the AppHub service_uri registered in apphub.tf
      "cloud.google.com/neg" = jsonencode({ ingress = true, exposed_ports = { "80" = { name = "web-neg" } } })
    }
  }
  spec {
    selector = { app = "web" }
    port {
      port        = 80
      target_port = 8080
    }
    type = "ClusterIP"
  }
}

# Gateway and HTTPRoute are applied via kubectl (k8s/service.yaml) after
# Gateway API CRDs are installed by the gateway_api_config cluster update.
