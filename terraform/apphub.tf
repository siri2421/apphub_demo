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

# ── Discover & register the Global External ALB (Gateway) ───────────────────
# The gke-l7-global-external-managed Gateway creates a global forwarding rule.
# AppHub discovers it via the GKE Gateway resource URI, enabling the
# LB → web topology edge to appear in the viewer.
data "google_apphub_discovered_service" "web_l7_lb" {
  project     = var.project_id
  location    = var.region
  service_uri = "//container.googleapis.com/projects/${data.google_project.project.number}/zones/${var.zone}/clusters/${google_container_cluster.apphub_cluster.name}/k8s/namespaces/default/apis/gateway.networking.k8s.io/gateways/web"
  depends_on  = [google_apphub_application.apphub_demo]
}

resource "google_apphub_service" "web_l7_lb" {
  project            = var.project_id
  location           = var.region
  application_id     = google_apphub_application.apphub_demo.application_id
  service_id         = "web-l7-lb"
  display_name       = "web-l7-lb"
  discovered_service = data.google_apphub_discovered_service.web_l7_lb.name

  attributes {
    environment { type = "PRODUCTION" }
    criticality  { type = "MISSION_CRITICAL" }
  }
}

# ── Discover & register GKE web NEG ──────────────────────────────────────────
# The NEG "web-neg" is created by the cloud.google.com/neg annotation on the
# web Service and is the backend for the L7 LB.
data "google_apphub_discovered_service" "web_neg" {
  project     = var.project_id
  location    = var.region
  service_uri = "//compute.googleapis.com/projects/${data.google_project.project.number}/zones/${var.zone}/networkEndpointGroups/web-neg"
  depends_on  = [google_apphub_application.apphub_demo]
}

resource "google_apphub_service" "web_neg" {
  project            = var.project_id
  location           = var.region
  application_id     = google_apphub_application.apphub_demo.application_id
  service_id         = "web-neg"
  display_name       = "web-neg"
  discovered_service = data.google_apphub_discovered_service.web_neg.name

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
