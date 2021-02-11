# Snowplow Deployment

## Changelog

| Version | Date       | Notes                                                                  |
| ------- | ---------- | ---------------------------------------------------------------------- |
| v1.2    | 2021-01-26 | Remove creating the events table from TF and add a one-off kube job    |
| v1.1    | 2021-01-18 | Clarify documentation around setting compute region and observing pods |
| v1.0    | 2021-01-10 | Initial release                                                        |

## Overview

This is an example deployment of the Snowplow data collection and processing pipeline running in GCP. Two tools are used to manage the setup:

### Terraform

[Terraform](https://www.terraform.io/) is an Infrastructure-as-Code (IaC) tool which allows for the setup and configuration of infrastructure provided a cloud providers via code. The biggest advantage here is that everything is version controlled in a ropo meaning you can change/rollback your infrastructure just as easily as you can your application code.

For this project, Terraform is used to setup all the resources in GCP required to run Snowplow (GKE, PubSub, BigQuery).

### Flux

[Flux](https://docs.fluxcd.io/) is a git-ops tool which brings the same benefits of IaC tools, but to kubernetes. It works by running an agent in the cluster which pulls manifests from a git repo on a regular basis and applies them to the cluster, meaning that the repo is the source of truth of what is running in the cluster. This brings version control to kubernetes deployments.

For this project, flux is used to deploy the different snowplow components inside the GKE cluster created by Terraform.

## Dependencies

An engineer deploying or managing the deployment will require the following tools:

- `gcloud` CLI installed and authenticated with your google account and the defailt compute region set to where you will run your cluster
- `terraform` CLI
- `kubectl` CLI

## Deployment

### Step 0 - Fork this repo

This repo is designed to be the template for each deployment as the kubernetes manifests will be pulled directly from the repo. As such, you should fork this repo and have a repo per-deployment.

### Step 1 - Setup GCP Project

This deployment is designed to start from scratch, as such, the first setup is to create an empty GCP project. You can do this through the UI or the following command:

```
> gcloud projects create [PROJECT_ID]
```

A number of services need to be enabled which will be used by this deployment:

```
> gcloud --project [PROJECT_ID] services enable compute.googleapis.com container.googleapis.com bigquery.googleapis.com monitoring.googleapis.com pubsub.googleapis.com
```

Finally, create the GCS bucket which will hold the terraform state. By this being in a bucket rather than on someones machine, it means multiple people can modify the deployment as the state is held centrally:

```
> gsutil mb -p [PROJECT_ID] -l europe-west1 -b on gs://[PROJECT_ID]-infra
```

### Step 2 - Configure and apply `terraform` to deploy infrastructure

> If not already setup, `gcloud` Application Default Credentials need to be available on this system as terraform uses these to access the bucket which holds the state. Run `gcloud auth application-default login` to do this.

1. Set the GCP bucket created in Step 1 in the `terraform.backend.bucket` key - this is where the state will be stored.
2. In the `terraform` directory run `terraform init` to pull the dependencies required to deploy the infrastructure
3. Modify the `terraform.tfvars` files with the values relevant to this project - the documentation for each is in the file.
4. Run `terraform plan` which will list out all the changes that will be made to the infrastructure. If there are no errors and the plan looks sensible, then run `terraform apply`. This will take a few minutes the first time as there is a lot of infrastructure to setup.
5. Grab the credentials to access the newly created GKE cluster via the following which will setup `kubectl` locally:

```
> gcloud --project [PROJECT_ID] container clusters get-credentials snowplow-gke
```

#### Deployed Resources

The resources deployed are as follows:

- GKE Cluster called `snowplow-gke` which for now is empty besides a copy of flux which will be configured in the next step
- A number of PubSub resources which will be used by Snowplow for each step of the processing:

- Topics

  - `collector_good` - the raw events received by the collection endpoint
  - `collector_bad` - any broken raw events (likely due to a bad HTTP request or connection issue)
  - `enriched_good` - successfully validated and enriched events
  - `enriched_bad` - events which resulted in an error when validating/enriching
  - `loader_bad_rows` - events which could not be converted to a BigQuery row
  - `loader_bad_inserts` - BigQuery rows which failed to insert into BigQuery
  - `loader_bq_types` - New Snowplow schemas

- Subscriptions

  - `collector_enricher_sub` - link between the `collector` and the `enricher`
  - `enricher_loader_sub` - link between the `enricher` and the `loader`
  - `loader_bq_types_sub` - used by the `mutator` to handle any schema evolution required on the BQ tables.

- BigQuery

- `snowplow` BigQuery Dataset
- Empty `events` BigQuery table which will be used by snowplow loader (the schema will be applied by snowplow later)

- Static IP `collector-ingress-ip-static` which will be assigned to the load balancer created by the ingress to the collector service in the GKE cluster.

Everything else is now deployed in the GKE cluster (which will create more GCP resources automatically and manage their lifecycle)

### Step 4 - Configure Kubernetes resources

The `flux/` folder contains a folder of manifests for each component which need configuring before applying to the cluster:

#### collector

This is the where events are sent and is exposed as an HTTP service from the cluster. The following configuration is required:

##### `collector/config-map.yaml`

This contains the configuration file used by snowplow collectors. The documentation is directly from snowplow's example configuration. The required parts to change are:

- `cookie.name` the name of the cookie to store data in
- `cookie.domains` is the list of domains for the tracker to set cookies on
- `cookie.fallbackDomain` the fallback domain should the origin not match
- `streams.sinks.googleProjectId` the GCP Project ID from Step 1 - this is so it knows where the PubSub topics are

##### `collector/certs.yaml`

This tells GCP to create an SSL certificate for the domain you will use (see DNS section also). Add the domain(s) to the list under `spec.domains`

##### `collector/ingress.yaml`

This tells which hostname the load balancer should reroute traffic from to the collector service. Set the domain under `spec.rules[0].host`.

#### enricher

The enricher applies the validation and enrichments to be run on the collected events. The following configuration is required:

##### `enricher/config-map.yaml`

Under the `config.hocon` blob, set the correct project name `input.subscription` value, leaving the rest as is eg `projects/[PROJECT_ID]/subscriptions/collector-enricher-sub`.

Do the same for the topics `good.topic` and `bad.topic` leaving the rest as is.

`resolver.json` is set up to use the standard repo of schemas provided by snowplow.

##### `enricher/config-map-enrichments.yaml`

Contains a list of JSON files which define the enrichments from Snowplow. `ua-parser.json` is provided as an example. Add more enrichments in here if you need them.

#### loader + mutator

The loader component takes the enriched events and writes them off to BigQuery. The loader that Snowplow provides requires configuration to be passed in as a base64 encoded JSON object. The follow is the sample JSONs which need to be base64 encoded (`cat some.json | base64` does the trick on mac/linux) and then pasted into the `deployment.yaml`. Thankfully it is the same config for both the `loader` and `mutator` and also in `mutator/init-events-table.yaml` so this only needs to be done once then copied into both in the `args` section of the manifest:

> Note that the `init-events-table` is a one-off job that will create the base schema of the `events` table. Once this job is complete the table should be visible in BQ.

##### `config.json`

```json
{
  "schema": "iglu:com.snowplowanalytics.snowplow.storage/bigquery_config/jsonschema/1-0-0",
  "data": {
    "name": "BigQuery",
    "id": "31b1559d-d319-4023-aaae-97698238d808",
    "projectId": "[PROJECT_ID]",
    "datasetId": "snowplow",
    "tableId": "events",
    "input": "enricher-loader-sub",
    "typesTopic": "loader-bq-types",
    "typesSubscription": "loader-bq-types-sub",
    "badRows": "loader-bad-rows",
    "failedInserts": "loader-bad-inserts",
    "load": {
      "mode": "STREAMING_INSERTS",
      "retry": false
    },
    "purpose": "ENRICHED_EVENTS"
  }
}
```

##### `resolver.josn`

```json
{
  "schema": "iglu:com.snowplowanalytics.iglu/resolver-config/jsonschema/1-0-1",
  "data": {
    "cacheSize": 500,
    "repositories": [
      {
        "name": "Iglu Central",
        "priority": 0,
        "vendorPrefixes": ["com.snowplowanalytics"],
        "connection": {
          "http": {
            "uri": "http://iglucentral.com"
          }
        }
      }
    ]
  }
}
```

> Note: The common way to run the load is via a Cloud Dataflow job which is designed for streaming data processing in a managed environment. This comes at a cost, so Snowplow also provides a standalone version which you can run anywhere - in this case GKE. For larger scale deployments, it is recommended to switch to Dataflow.

Once all the configuration changes are made, make sure to commit and then `git push` any changes back to GitHub so they can be pulled down by `flux`.

### Step 3 - Setup `flux` in Kubernetes cluster

`Flux` itself is deployed into the cluster by Terraform into a namespace called `flux`. When flux is deployed it generates an SSH key which needs to be added to the git repo's Deploy Keys section in the repo settings to allow the `flux` instance in the cluster to access the repo and grab the manifests.

Run the following command to get the key:

`kubectl -n flux logs deployment/flux | grep identity.pub | cut -d '"' -f2`

This needs to be added as a deploy key to the repo - this needs write access.

Once complete, `flux` will deploy the manifests, you can run `kubectl get pods --all-namespaces` to see all the running pods. By default `flux` runs every 5 minutes.

> You can install the `fluxctl` tool which will allow you to trigger a sync rather than wait the 5 minutes. If you have this, the command is `fluxctl --k8s-fwd-ns flux sync`. Note that your repo should use `master` rather than `main` as the primary branch for flux to pull it.

### Step 4 - DNS

Once everything is deployed, the final piece is to create a DNS record in your DNS provider pointing at the load balancer created by the deployment. The load balancer will use the IP created earlier called `collector-ingress-ip-static`

To get the IP address run:

```
> gcloud --project [PROJECT_ID] compute addresses list
```

and the IP will be listed next to `collector-ingress-ip-static`, eg in this example it is `123.123.123.123`

```
> gcloud --project [PROJECT_ID] compute addresses list
NAME                         ADDRESS/RANGE  TYPE      PURPOSE  NETWORK  REGION  SUBNET  STATUS
collector-ingress-ip-static  123.123.123.123   EXTERNAL                                    IN_USE
```

Create an A record in the DNS provider pointing to the listed IP address.

> Note: The SSL certificate will only be generated by GCP when the DNS record has been set as it needs to check you own the domain before applying it. You can check the status of the SSL certificate via `kubectl describe managedcertificate`

## Teardown

If at any stage you want to remove the whole deployment just run `terraform destroy`. All resources will be removed and you will be left with an empty GCP project except for the GCS bucket holding the terraform state in it.

## Logging & Monitoring

Logging is centralised in StackDriver by GCP as a managed service. The sections to look at are:

- Logging for the output from the components running in the cluster
- Network Load balancers for stats on the amount of traffic coming into the cluster
- You can setup alerts on these to flag when traffic has dropped off
- PubSub to see how many messages are being processed through the system
- You can setup alerts on these to identity when something is stuck

## Scaling

There are two areas where the deployment can be scaled:

### GKE Cluster (via Terraform)

You can scale up the deployment by modifying the following variables in the `terraform.tfvars` file for the deployment:

- `gke_instance_size` defines how beefy the nodes are. You can pick any [machine type](https://cloud.google.com/compute/docs/machine-types) that GCP provides e.g. 'n2-standard-4` gives you 4 VCPUs and 16GB of memory per-node.
- `gke_node_count` defines the number of nodes that are in the cluster's node-pool to distribute the workload across

Once you have modified these values you will need to run `terraform plan` and `terraform apply` again from the `terraform` directory.

### Kubernetes Deployments

Each of the components `deployment.yaml` files define the number of replicas to be created and the amount of resources each one can use. The defaults are kept low for cost reasons, but to scale, increase the `replicas` and `request` / `limits` fields to larger values. As you increase the resources each component can use, you will also need to scale the cluster (see above) in order for them to fit into the nodes. Change the values in this repo, then push the changes which will be picked up by `flux` and applied to the cluster.

Alternative, horizontal pod auto-scaling (HPA) can be set up for the deployment if the load varies overtime.

## Future Work

- [ ] Create example HPA
- [ ] Add snowplow replayer
- [ ] Deploy Prometheus for metrics
- [ ] Deploy Grafana
- [ ] Scaling based on PubSub queue size
- [ ] Upgrade helm
- [ ] Migrate to flux2 down
