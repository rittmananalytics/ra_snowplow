# The GCP project ID that will be deployed to
gcp_project_id = "ao-dev-ra-snowplow"

# The region that all resouces will be deploeyed into
gcp_region = "europe-west1"

# The primary zone for the resouces. In the case of gke_regional_cluster being false, GKE will be deployed into this zone.
gcp_zone = "europe-west1-b"

# The size of the nodes to use in the GKE cluster - can be any GCP machine type
gke_instance_size = "n1-standard-1"

# Whether to use pre-emptiale VMs. These are much cheaper but can lead to downtime if deployments are not spread accross nodes in the cluster
gke_preemptible_nodes = true

# Whether to deploy GKE across a region or just one zone. The first zonal cluster is free, then you have to pay a cluster fee all for clusters
gke_regional_cluster = false

# The number of nodes in the GKE pool. 3 is the recommended minimum for high avaliablity.
gke_node_count = 3

# The repo used for this deployment which will be used by flux to sync the config
flux_giturl = "git@github.com:alexolivier/ra-snowplow.git"

# The path within the repo holding the kubernetes manifest
flux_path = "flux/"
