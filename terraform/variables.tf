variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "agentic-marketing-demo"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "alloydb_password" {
  description = "Password for AlloyDB postgres user"
  type        = string
  sensitive   = true
  default     = "password"
}
