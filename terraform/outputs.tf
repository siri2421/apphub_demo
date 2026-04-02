output "gke_cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.apphub_cluster.name
}

output "gke_cluster_zone" {
  description = "GKE cluster zone"
  value       = google_container_cluster.apphub_cluster.location
}

output "redis_host" {
  description = "Memorystore Redis host IP"
  value       = google_redis_instance.apphub_redis.host
}

output "redis_port" {
  description = "Memorystore Redis port"
  value       = google_redis_instance.apphub_redis.port
}

output "alloydb_instance_name" {
  description = "AlloyDB instance full resource name (used by the connector)"
  value       = google_alloydb_instance.apphub_primary.name
}

output "cloudrun_url" {
  description = "Cloud Run user-location service URL"
  value       = google_cloud_run_v2_service.user_location.uri
}

output "artifact_registry" {
  description = "Artifact Registry repository URL"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/apphub"
}
