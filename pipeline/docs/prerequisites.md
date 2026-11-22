# Prerequisites

What each machine needs installed, and what the cluster needs before the first `deploy.sh`. Cluster setup is done once per cluster, usually by a cluster admin. `deploy.sh` preflight checks most of it and stops with the fix when something is missing.

- [1. Tools](#1-tools)
- [2. Cluster checklist](#2-cluster-checklist)
- [3. GPU node pools](#3-gpu-node-pools)
- [4. Gateway API and InferencePool CRD](#4-gateway-api-and-inferencepool-crd)
- [5. A Gateway](#5-a-gateway)
- [6. LeaderWorkerSet (P/D and wide-EP only)](#6-leaderworkerset-pd-and-wide-ep-only)
- [7. Namespace, ServiceAccount and bucket access](#7-namespace-serviceaccount-and-bucket-access)
- [8. Optional add-ons](#8-optional-add-ons)

## 1. Tools

| Tool | Version | Deploy machine | Bundle machine (air gap only) | Used for |
| --- | --- | --- | --- | --- |
| `kubectl` | ≥ 1.27 (kustomize v5 built in) | yes | yes | render overlays, apply, wait |
| `helm` | ≥ 3.8 (OCI support) | yes | yes | render the router chart, pull charts |
| `yq` | v4 (mikefarah) | yes | yes | every YAML edit (`lib/yq/*.yq`) |
| `git` | any | yes, unless `.cache/` is unpacked | yes | fetch the pinned llm-d guides |
| `python3` | ≥ 3.8 | yes | yes | helpers, env-file checks |
| `curl` | any | — | yes | CRDs, registry digests |
| `docker buildx` | optional | — | optional | resolves image digests (falls back to `curl`) |
| `gcloud` | any | for checks only | — | IAM bindings, `gcloud storage ls` |

The deploy machine needs network access to the **cluster API only** when it has a `.cache/` (from a previous run or a bundle). Without one, the first render also needs GitHub and `ghcr.io`.

`yq` must be mikefarah's v4: `yq --version` prints `yq (https://github.com/mikefarah/yq/) version v4.x`. The Python `yq` wrapper does not work.

## 2. Cluster checklist

| Need | For | Check | Set up |
| --- | --- | --- | --- |
| GPU nodes with local SSD | every profile | `kubectl get nodes -L cloud.google.com/gke-accelerator` | [3](#3-gpu-node-pools) |
| `InferencePool` CRD | every profile | `kubectl get crd inferencepools.inference.networking.k8s.io` | [4](#4-gateway-api-and-inferencepool-crd) |
| A Gateway that accepts routes from `NAMESPACE` | `router.mode: gateway` | `kubectl get gateway -A` | [5](#5-a-gateway) |
| LWS ≥ 0.11.1 with `DisaggregatedSet` | P/D, wide-EP | `kubectl get crd disaggregatedsets.disaggregatedset.x-k8s.io` | [6](#6-leaderworkerset-pd-and-wide-ep-only) |
| Namespace + ServiceAccount | every profile | `kubectl get sa -n llm-d llm-d-modelserver` | [7](#7-namespace-serviceaccount-and-bucket-access) |
| SA can read the weights bucket | every profile | `fetch-model` logs | [7](#7-namespace-serviceaccount-and-bucket-access) |
| Nodes can pull from your registry | private registry | `kubectl describe pod` | [7](#7-namespace-serviceaccount-and-bucket-access) |
| Weights in GCS | every model | `gcloud storage ls gs://models_registry/<folder>/config.json` | garuda repo |
| RDMA between GPU nodes | P/D at full speed, wide-EP | — | your platform |
| IPP | several models on one Gateway | `kubectl get deploy -n llm-d` | [8](#8-optional-add-ons) |
| Managed Prometheus | `MONITORING=gmp` | `kubectl get crd podmonitorings.monitoring.googleapis.com` | [8](#8-optional-add-ons) |

## 3. GPU node pools

- GPU node pools with the NVIDIA driver installed by GKE (H100, H200, B200, RTX PRO 6000, ...).
- **Local SSD as ephemeral storage** (`--ephemeral-storage-local-ssd count=<n>`). Weights are cached at `/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models`; set `MODEL_CACHE_PATH` for another path.
- Each node's local SSD must hold every model scheduled on it (DeepSeek-R1 ≈ 700 GB, Qwen3.8-27B ≈ 56 GB, Gemma 4 31B ≈ 63 GB). The cache is never evicted.
- P/D and wide-EP use RDMA (GPUDirect-RDMA / InfiniBand) between nodes. Wide-EP needs a **full-mesh** fabric. P/D without RDMA works over TCP, but the upstream `gke` overlays request RDMA NICs: see [guide 07](guides/07-gemma-pd-tiered-g4.md) for the non-RDMA variant.

## 4. Gateway API and InferencePool CRD

GKE ≥ 1.34.0-gke.1626000 with the Gateway API enabled (`--gateway-api=standard`) manages the `InferencePool` CRD. On any other cluster, apply the copy `bundle.sh` downloads into `.cache/crds/` (or the [upstream release](https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases)):

```bash
kubectl apply -f .cache/crds/inference-extension-v1.yaml
kubectl get crd inferencepools.inference.networking.k8s.io
```

## 5. A Gateway

Pick one. Its listeners must accept routes from the deployment namespace.

**agentgateway** (self-installed; upstream's preferred option):

```bash
AGENTGATEWAY_VERSION=v1.1.0
helm upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace --version ${AGENTGATEWAY_VERSION}
helm upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --create-namespace --version ${AGENTGATEWAY_VERSION} \
  --set inferenceExtension.enabled=true          # required for InferencePool routing
```

```yaml
# gateway-agentgateway.yaml  →  kubectl apply -n agentgateway-system -f gateway-agentgateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llm-d-inference-gateway
spec:
  gatewayClassName: agentgateway
  listeners:
    - name: default
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All            # model routes live in the llm-d namespace
```

Profiles: `gateway: {provider: agentgateway, name: llm-d-inference-gateway, namespace: agentgateway-system}`.

**GKE Gateway** (Google-managed load balancer). Needs the Gateway API on the cluster and a proxy-only subnet in the region:

```yaml
# gateway-gke.yaml  →  kubectl apply -n gateway-infra -f gateway-gke.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llm-d-inference-gateway
spec:
  gatewayClassName: gke-l7-rilb          # internal; gke-l7-regional-external-managed for external
  listeners:
    - name: default
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
```

Profiles: `gateway: {provider: gke, name: llm-d-inference-gateway, namespace: gateway-infra}`. `provider: gke` is not optional: without it every request returns 503.

Upstream ships more Gateway manifests under `.cache/llm-d-<sha>/guides/recipes/gateway/` (Istio, kgateway, Envoy AI Gateway, NGINX Gateway Fabric).

```bash
kubectl get gateway -A        # PROGRAMMED=True and an ADDRESS
```

## 6. LeaderWorkerSet (P/D and wide-EP only)

P/D overlays create a `DisaggregatedSet`, which LWS provides only when installed with `enableDisaggregatedSet=true`:

```bash
LWS_VERSION=1.0.0                                    # needs >= v0.11.1
helm pull oci://registry.k8s.io/lws/charts/lws --version=${LWS_VERSION} --untar
kubectl apply --server-side --force-conflicts -f lws/crds
helm upgrade --install lws oci://registry.k8s.io/lws/charts/lws --version=${LWS_VERSION} \
  --namespace lws-system --create-namespace \
  --set enableDisaggregatedSet=true \
  --wait --timeout 300s
kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io disaggregatedsets.disaggregatedset.x-k8s.io
```

Air-gapped: `LWS_CHART=1 ./bundle.sh ...` on the connected side, then `./install-lws.sh -e <env>` inside. See [air-gapped.md](air-gapped.md#5-leaderworkerset).

## 7. Namespace, ServiceAccount and bucket access

All models share one namespace and one ServiceAccount. Model-server pods run as it, and `fetch-model` reads the bucket with it through Workload Identity.

```yaml
# llm-d-namespace.yaml  →  kubectl apply -f llm-d-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: llm-d
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: llm-d-modelserver
  namespace: llm-d
```

```bash
PROJECT_ID=<project>
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

# model servers read weights from GCS (Workload Identity, no keys)
gcloud storage buckets add-iam-policy-binding gs://models_registry --role=roles/storage.objectViewer \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/llm-d/sa/llm-d-modelserver"

# nodes pull images from your Artifact Registry (private registry only)
gcloud artifacts repositories add-iam-policy-binding <repo> --location=<location> \
  --role=roles/artifactregistry.reader --member="serviceAccount:<node-service-account>"
```

Air-gapped nodes also need **Private Google Access** on their subnet to reach `storage.googleapis.com` and Artifact Registry.

The ServiceAccount needs no Kubernetes RBAC. The EPP gets its own (`<name>-epp`, created by the router chart) unless you set `ROUTER_SERVICE_ACCOUNT`.

Other names: set `NAMESPACE` and `SERVICE_ACCOUNT` in the env file.

## 8. Optional add-ons

| Add-on | Needed for | Install |
| --- | --- | --- |
| **Inference Payload Processor (IPP)** | several models on one Gateway (`gateway.baseModel`) | [guide 06](guides/06-multi-model-gateway.md#2-install-ipp-once-per-gateway) |
| **GKE Managed Prometheus** | `MONITORING=gmp` | `gcloud container clusters update <cluster> --enable-managed-prometheus` |
| **`InferenceObjective` CRD** | flow-control priorities (`router.inferenceObjectives`) | `ROUTER_CRDS=1 ./bundle.sh`, then `kubectl apply -f .cache/crds/llm-d-router.yaml` |
| Guide-specific services (Mooncake master, Postgres, ModelExpress, FMA, KEDA) | the guides marked ➕ in [configuration.md §5](configuration.md#5-catalog-model-server-overlays) | apply them yourself before `deploy.sh` |
