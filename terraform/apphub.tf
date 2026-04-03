# Project number is required in AppHub workload/service URIs
data "google_project" "project" {
  project_id = var.project_id
}

# ── AppHub Application ────────────────────────────────────────────────────────
# Creates the apphub_demo application and registers all four service components
# so the topology viewer can render the web → user-location → Redis/AlloyDB graph
# using peer.service attributes from distributed traces.
resource "google_apphub_application" "apphub_demo" {
  project        = var.project_id
  location       = var.region
  application_id = "apphub-demo"
  display_name   = "AppHub Demo"
  description    = "Demo app: GKE web → Cloud Run user-location → Memorystore Redis + AlloyDB"

  scope {
    type = "REGIONAL"
  }

  depends_on = [google_project_service.apis]
}

# ── Discover & register Cloud Run user-location ───────────────────────────────
data "google_apphub_discovered_service" "user_location" {
  project      = var.project_id
  location     = var.region
  service_uri  = "//run.googleapis.com/projects/${var.project_id}/locations/${var.region}/services/${google_cloud_run_v2_service.user_location.name}"
  depends_on   = [google_apphub_application.apphub_demo]
}

resource "google_apphub_service" "user_location" {
  project          = var.project_id
  location         = var.region
  application_id   = google_apphub_application.apphub_demo.application_id
  service_id       = "user-location"
  display_name     = "user-location"
  discovered_service = data.google_apphub_discovered_service.user_location.name

  attributes {
    environment {
      type = "PRODUCTION"
    }
    criticality {
      type = "MISSION_CRITICAL"
    }
  }
}

# ── Discover & register Memorystore Redis ─────────────────────────────────────
data "google_apphub_discovered_service" "redis" {
  project      = var.project_id
  location     = var.region
  service_uri  = "//redis.googleapis.com/projects/${var.project_id}/locations/${var.region}/instances/${google_redis_instance.apphub_redis.name}"
  depends_on   = [google_apphub_application.apphub_demo]
}

resource "google_apphub_service" "redis" {
  project          = var.project_id
  location         = var.region
  application_id   = google_apphub_application.apphub_demo.application_id
  service_id       = "apphub-redis"
  display_name     = "apphub-redis"
  discovered_service = data.google_apphub_discovered_service.redis.name

  attributes {
    environment {
      type = "PRODUCTION"
    }
    criticality {
      type = "HIGH"
    }
  }
}

# ── Discover & register AlloyDB instance ──────────────────────────────────────
data "google_apphub_discovered_service" "alloydb" {
  project      = var.project_id
  location     = var.region
  service_uri  = "//alloydb.googleapis.com/projects/${var.project_id}/locations/${var.region}/clusters/${google_alloydb_cluster.apphub_cluster.cluster_id}/instances/${google_alloydb_instance.apphub_primary.instance_id}"
  depends_on   = [google_apphub_application.apphub_demo]
}

resource "google_apphub_service" "alloydb" {
  project          = var.project_id
  location         = var.region
  application_id   = google_apphub_application.apphub_demo.application_id
  service_id       = "apphub-alloydb"
  display_name     = "apphub-alloydb"
  discovered_service = data.google_apphub_discovered_service.alloydb.name

  attributes {
    environment {
      type = "PRODUCTION"
    }
    criticality {
      type = "MISSION_CRITICAL"
    }
  }
}

# ── Discover & register GKE LoadBalancer Service ─────────────────────────────
# The K8s web Service (type=LoadBalancer) is the external entry point.
# Its backing GCP forwarding rule name = "a" + first 31 chars of service UID
# (hyphens removed) — derived deterministically by GKE.
locals {
  web_svc_uid_no_hyphens = replace(kubernetes_service_v1.web_lb.metadata[0].uid, "-", "")
  forwarding_rule_name   = "a${substr(local.web_svc_uid_no_hyphens, 0, 31)}"
}

data "google_apphub_discovered_service" "web_k8s_svc" {
  project     = var.project_id
  location    = var.region
  service_uri = "//container.googleapis.com/projects/${data.google_project.project.number}/zones/${var.zone}/clusters/${google_container_cluster.apphub_cluster.name}/k8s/namespaces/default/services/web"
  depends_on  = [google_apphub_application.apphub_demo]
}

resource "google_apphub_service" "web_k8s_svc" {
  project            = var.project_id
  location           = var.region
  application_id     = google_apphub_application.apphub_demo.application_id
  service_id         = "web-lb-service"
  display_name       = "web-lb-service"
  discovered_service = data.google_apphub_discovered_service.web_k8s_svc.name

  attributes {
    environment {
      type = "PRODUCTION"
    }
    criticality {
      type = "MISSION_CRITICAL"
    }
  }
}

data "google_apphub_discovered_service" "web_forwarding_rule" {
  project     = var.project_id
  location    = var.region
  service_uri = "//compute.googleapis.com/projects/${data.google_project.project.number}/regions/${var.region}/forwardingRules/${local.forwarding_rule_name}"
  depends_on  = [google_apphub_application.apphub_demo]
}

resource "google_apphub_service" "web_forwarding_rule" {
  project            = var.project_id
  location           = var.region
  application_id     = google_apphub_application.apphub_demo.application_id
  service_id         = "web-forwarding-rule"
  display_name       = "web-forwarding-rule"
  discovered_service = data.google_apphub_discovered_service.web_forwarding_rule.name

  attributes {
    environment {
      type = "PRODUCTION"
    }
    criticality {
      type = "MISSION_CRITICAL"
    }
  }
}

# ── Discover & register GKE web deployment (Workload) ────────────────────────
data "google_apphub_discovered_workload" "web" {
  project      = var.project_id
  location     = var.region
  # AppHub URIs use project number (not ID) and "zones" (not "locations") for GKE
  workload_uri = "//container.googleapis.com/projects/${data.google_project.project.number}/zones/${var.zone}/clusters/${google_container_cluster.apphub_cluster.name}/k8s/namespaces/default/apps/deployments/web"
  depends_on   = [google_apphub_application.apphub_demo]
}

resource "google_apphub_workload" "web" {
  project             = var.project_id
  location            = var.region
  application_id      = google_apphub_application.apphub_demo.application_id
  workload_id         = "web"
  display_name        = "web"
  discovered_workload = data.google_apphub_discovered_workload.web.name

  attributes {
    environment {
      type = "PRODUCTION"
    }
    criticality {
      type = "MISSION_CRITICAL"
    }
  }
}
