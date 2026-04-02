resource "google_container_cluster" "apphub_cluster" {
  name     = "apphub-cluster"
  location = var.zone

  deletion_protection = false

  # Use separately managed node pool
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.apphub_vpc.name
  subnetwork = google_compute_subnetwork.apphub_subnet.name

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  # Enable Workload Identity so pods can authenticate to GCP APIs
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "primary-node-pool"
  location   = var.zone
  cluster    = google_container_cluster.apphub_cluster.name
  node_count = 2

  node_config {
    machine_type = "e2-standard-2"

    service_account = google_service_account.gke_sa.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}
