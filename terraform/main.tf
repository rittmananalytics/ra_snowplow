variable "gcp_project_id" {
  type        = string
  description = "The GCP project id (note: note project name)"
}

variable "gcp_region" {
  type        = string
  description = "The GCP region to use for resources eg europe-west1"
}

variable "gcp_zone" {
  type        = string
  description = "The GCP zone to use for resources eg europe-west1-b"
}

variable "gke_regional_cluster" {
  type        = bool
  description = "Create a regional cluster or else a zonal cluster will be created"
}

variable "gke_instance_size" {
  type        = string
  description = "The size of the instances to use in the GKE cluster eg n1-standard-1"
}

variable "gke_preemptible_nodes" {
  type        = bool
  description = "Use preemptiable GKE nodes"
}

variable "gke_node_count" {
  type        = number
  description = "Use number of nodes to create in the node pool"
}

variable "flux_giturl" {
  type        = string
  description = "git repo containing the kuberntes manifests consumed by flux"
}

variable "flux_path" {
  type        = string
  description = "Path within the git repo for the kubernetes manifests"
}


terraform {
  backend "gcs" {
    bucket = "ao-dev-ra-snowplow-infra"
    prefix = "terraform"
  }
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "1.2.4"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

data "google_client_config" "provider" {}


# GKE Cluster
## Cluster
resource "google_container_cluster" "snowplow_gke" {
  name                     = "snowplow-gke"
  location                 = var.gke_regional_cluster ? var.gcp_region : var.gcp_zone
  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = "default"
  subnetwork               = "default"

  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "/16"
    services_ipv4_cidr_block = "/22"
  }
}
## Node Pool
resource "google_container_node_pool" "snowplow_gke_nodes" {
  name       = "snowplow-gke-nodes"
  location   = var.gke_regional_cluster ? var.gcp_region : var.gcp_zone
  cluster    = google_container_cluster.snowplow_gke.name
  node_count = var.gke_node_count

  node_config {
    preemptible  = var.gke_preemptible_nodes
    machine_type = var.gke_instance_size
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/pubsub",
      "https://www.googleapis.com/auth/bigquery",
      "https://www.googleapis.com/auth/devstorage.read_only"
    ]
  }
}

# PubSub topics
resource "google_pubsub_topic" "collector_good" {
  name = "collector-good"
}

resource "google_pubsub_topic" "collector_bad" {
  name = "collector-bad"
}

resource "google_pubsub_subscription" "collector_enricher_sub" {
  name  = "collector-enricher-sub"
  topic = google_pubsub_topic.collector_good.name
}

resource "google_pubsub_topic" "enriched_good" {
  name = "enriched-good"
}

resource "google_pubsub_topic" "enriched_bad" {
  name = "enriched-bad"
}

resource "google_pubsub_subscription" "enricher_loader_sub" {
  name  = "enricher-loader-sub"
  topic = google_pubsub_topic.enriched_good.name
}

resource "google_pubsub_topic" "loader_bad_rows" {
  name = "loader-bad-rows"
}

resource "google_pubsub_topic" "loader_bad_inserts" {
  name = "loader-bad-inserts"
}

resource "google_pubsub_topic" "loader_bq_types" {
  name = "loader-bq-types"
}

resource "google_pubsub_subscription" "loader_bq_types_sub" {
  name  = "loader-bq-types-sub"
  topic = google_pubsub_topic.loader_bq_types.name
}

# BigQuery
## Create the snowplow dataset in BQ which the loader will load into
resource "google_bigquery_dataset" "dataset" {
  dataset_id                 = "snowplow"
  friendly_name              = "snowplow"
  location                   = "EU"
  delete_contents_on_destroy = false #Safety-net
}

# Create an IP which will be assigned to the load balancer by the ingress in GKE
resource "google_compute_global_address" "ip" {
  name = "collector-ingress-ip-static"
}


# Setup Flux
## Conenct to the newly created GKE cluster
provider "kubernetes" {
  load_config_file = false
  host             = "https://${google_container_cluster.snowplow_gke.endpoint}"
  token            = data.google_client_config.provider.access_token
  cluster_ca_certificate = base64decode(
    google_container_cluster.snowplow_gke.master_auth[0].cluster_ca_certificate,
  )
}


## Setup Flux
resource "kubernetes_namespace" "flux_ns" {
  metadata {
    name = "flux"
  }
}

resource "helm_release" "helm-flux" {
  name       = "flux"
  chart      = "flux"
  repository = "https://charts.fluxcd.io"
  namespace  = kubernetes_namespace.flux_ns.metadata[0].name

  set {
    name  = "registry.disableScanning"
    value = true
  }

  set {
    name  = "syncGarbageCollection.enabled"
    value = true
  }

  set {
    name  = "git.url"
    type  = "string"
    value = var.flux_giturl
  }

  set {
    name  = "git.path"
    type  = "string"
    value = var.flux_path
  }
}
