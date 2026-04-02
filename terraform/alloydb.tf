resource "google_alloydb_cluster" "apphub_cluster" {
  cluster_id = "apphub-alloydb"
  location   = var.region

  network_config {
    network = google_compute_network.apphub_vpc.id
  }

  initial_user {
    password = var.alloydb_password
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_alloydb_instance" "apphub_primary" {
  cluster       = google_alloydb_cluster.apphub_cluster.name
  instance_id   = "apphub-primary"
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = 2
  }

  depends_on = [google_alloydb_cluster.apphub_cluster]
}
