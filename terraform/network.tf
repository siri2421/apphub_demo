resource "google_compute_network" "apphub_vpc" {
  name                    = "apphub-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "apphub_subnet" {
  name          = "apphub-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.apphub_vpc.id

  # Secondary ranges for GKE pods and services
  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.1.0.0/16"
  }
  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.2.0.0/16"
  }
}

# Private services access — required for Memorystore and AlloyDB
resource "google_compute_global_address" "private_ip_range" {
  name          = "apphub-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.apphub_vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.apphub_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
  depends_on              = [google_project_service.apis]
}

# VPC Access Connector — allows Cloud Run to reach VPC resources (Redis, AlloyDB)
resource "google_vpc_access_connector" "connector" {
  name          = "apphub-connector"
  region        = var.region
  network       = google_compute_network.apphub_vpc.name
  ip_cidr_range = "10.8.0.0/28"
  depends_on    = [google_project_service.apis]
}
