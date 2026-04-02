resource "google_redis_instance" "apphub_redis" {
  name           = "apphub-redis"
  tier           = "BASIC"
  memory_size_gb = 1
  region         = var.region

  # Place Redis inside the VPC so GKE pods and Cloud Run (via connector) can reach it
  authorized_network = google_compute_network.apphub_vpc.id
  connect_mode       = "DIRECT_PEERING"

  redis_version = "REDIS_7_0"

  depends_on = [google_service_networking_connection.private_vpc_connection]
}
