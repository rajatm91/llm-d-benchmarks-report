# Deploying models with llm-d: step by step

This guide takes you from an empty GKE cluster to a model serving traffic through an llm-d Gateway. It uses this repo's pipeline (`deploy.sh`, `bundle.sh`, `profiles/*.yaml`). It covers connected and air-gapped clusters, any Hugging Face model, every llm-d strategy and their combinations, and many models behind one Gateway.

Every profile YAML in this guide renders with the pipeline as written. `docs/check-guide.sh` extracts them and runs `./deploy.sh --dry-run` on each.

| Step | Who | How often |
| --- | --- | --- |
| [1. One-time cluster setup](#1-one-time-cluster-setup) | cluster admin | once per cluster |
| [2. Prepare artifacts](#2-prepare-artifacts-connected-machine) | platform team | once per llm-d version, and for each new model |
| [3. Write a profile](#3-write-a-profile) | model owner | once per model deployment |
| [4. Validate offline](#4-validate-offline) | model owner and CI | every change |
| [5. Deploy](#5-deploy) | CI or the model owner | every change |
| [6. Verify and call the model](#6-verify-and-call-the-model) | anyone | after a deploy |
| [7. Day-2 operations](#7-day-2-operations) | model owner | as needed |
| [8. Jenkins](#8-run-it-from-jenkins) | platform team | once |
| [9. Troubleshooting](#9-troubleshooting) | anyone | when something breaks |

---

## 0. How it fits together

```
client ──► Gateway  (agentgateway / GKE L7, shared, pre-existing)          ns: agentgateway-system | gateway-infra
             └─ HTTPRoute <name>          ─┐
                  └─ InferencePool <name>  │  router half: rendered from the llm-d router chart
                       ├─ EPP <name>-epp   │  (endpoint picker: prefix-cache affinity, load, P/D)
                       │                  ─┘
                       └─ selects pods llm-d.ai/deployment=<name>
                            └─ vLLM pods  ─── model-server half: rendered from an llm-d guide overlay
                                 ├─ init: fetch-model  (gs://<bucket>/<org>/<model> → node-local SSD)
                                 └─ vllm serve <model> ...                  ns: llm-d (shared by all models)
```

Each deployment has two halves:

- **Model servers.** These are vLLM pods from an upstream llm-d *overlay* (kustomize). The overlay decides the topology: aggregated, P/D or wide-EP.
- **Router.** This is the EPP, `InferencePool` and `HTTPRoute`, from the llm-d router chart plus the *router values* of the same strategy. The values decide how requests are scheduled.

A **profile** (`profiles/<name>.yaml`) picks one overlay and its router values, sets the model, and names the Gateway. `deploy.sh` renders both halves, rewrites them for a shared namespace, GCS weights and a private registry, applies them, waits, and smoke-tests through the Gateway.

Every resource is named `<model>-<strategy>-<engine>`, for example `qwen3-8-27b-baseline-vllm`.

---

## 1. One-time cluster setup

### 1.1 GPU node pools

- Use H100/H200/B200 node pools with the NVIDIA driver installed by GKE.
- Add **local SSD as ephemeral storage** (`--ephemeral-storage-local-ssd count=<n>`). Model weights are cached on it at `/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models`, the same path the upstream wide-EP guide uses. To use another path, set `MODEL_CACHE_PATH`.
- Each node's local SSD must hold every model scheduled on it. For example, DeepSeek-R1 is about 700 GB and Qwen3.8-27B about 56 GB.
- P/D and wide-EP need RDMA (GPUDirect-RDMA / InfiniBand) between GPU nodes. Wide-EP needs a **full-mesh** fabric.

### 1.2 Gateway API and InferencePool CRDs

GKE 1.34.0-gke.1626000 or later with the Gateway API enabled manages the `InferencePool` CRD for you. On any other cluster, apply the copy `bundle.sh` downloads:

```bash
kubectl apply -f pipeline/.cache/crds/inference-extension-v1.yaml
kubectl get crd inferencepools.inference.networking.k8s.io
```

### 1.3 A Gateway (pick one)

**agentgateway** (self-installed; upstream's preferred option, since kgateway is deprecated):

```bash
AGENTGATEWAY_VERSION=v1.1.0
helm upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace --version ${AGENTGATEWAY_VERSION}
helm upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --create-namespace --version ${AGENTGATEWAY_VERSION} \
  --set inferenceExtension.enabled=true          # required for InferencePool routing
```

```yaml
# gateway-agentgateway.yaml   →  kubectl apply -n agentgateway-system -f gateway-agentgateway.yaml
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
          from: All            # model routes live in the llm-d namespace, not here
```

**GKE Gateway** (managed load balancer). The cluster needs the Gateway API enabled and a proxy-only subnet in the region:

```yaml
# gateway-gke.yaml   →  kubectl apply -n gateway-infra -f gateway-gke.yaml
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

> With GKE, profiles must set `gateway.provider: gke`. That makes the router render a `HealthCheckPolicy` and `GCPBackendPolicy`. Without them the load balancer's health check fails and **every request returns 503**.

### 1.4 LeaderWorkerSet (only for P/D and wide-EP)

```bash
LWS_VERSION=1.0.0                                    # needs >= v0.11.1
helm pull oci://registry.k8s.io/lws/charts/lws --version=${LWS_VERSION} --untar
kubectl apply --server-side --force-conflicts -f lws/crds
helm upgrade --install lws oci://registry.k8s.io/lws/charts/lws --version=${LWS_VERSION} \
  --namespace lws-system --create-namespace \
  --set enableDisaggregatedSet=true \
  --wait --timeout 300s
```

### 1.5 Shared namespace, ServiceAccount and access to the weights bucket

All models share one namespace and one pre-existing ServiceAccount. The model-server pods run as it, and the `fetch-model` init container uses it, through Workload Identity, to read the weights bucket.

```yaml
# llm-d-namespace.yaml   →  kubectl apply -f llm-d-namespace.yaml
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
PROJECT_ID=<project>; PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

# model servers read weights from GCS (Workload Identity, no keys)
gcloud storage buckets add-iam-policy-binding gs://<bucket> --role=roles/storage.objectViewer \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/llm-d/sa/llm-d-modelserver"

# nodes pull images from the private Artifact Registry
gcloud artifacts repositories add-iam-policy-binding llm-d --location=us \
  --role=roles/artifactregistry.reader --member="serviceAccount:<node-service-account>"
```

The nodes also need **Private Google Access** on their subnet, so they can reach `storage.googleapis.com` and Artifact Registry without internet access.

### 1.6 (Several models on one Gateway) Inference Payload Processor

Two models on the same Gateway would both claim `/`. IPP reads `"model"` from the request body and sets an `X-Gateway-Base-Model-Name` header, and each model's route matches on that header. Install it once per Gateway:

```bash
git clone https://github.com/llm-d/llm-d-inference-payload-processor.git /tmp/ipp   # mirror this inside the air gap
helm install ipp /tmp/ipp/config/charts/payload-processor \
  --set provider.name=gke \
  --set inferenceGateway.name=llm-d-inference-gateway \
  -n llm-d
```

For agentgateway or Istio, set `provider.name` accordingly. The mappings are created per model in [step 3, sample H](#sample-h-several-models-on-one-gateway).

---

## 2. Prepare artifacts (connected machine)

Run this once per llm-d version, and again whenever a profile adds a new model or image:

```bash
cd pipeline
IMAGE_REGISTRY=us-docker.pkg.dev/<project>/llm-d \
MODEL_BUCKET=gs://<bucket> \
./bundle.sh                                  # or only some: ./bundle.sh profiles/qwen3.8-27b-baseline-agentgateway.yaml
```

| It produces | Used for |
| --- | --- |
| `.cache/llm-d-<sha>/` | the pinned llm-d guides (overlays, router values) |
| `.cache/charts/<chart>-<version>/` | the router Helm chart |
| `.cache/crds/` | InferencePool CRDs ([1.2](#12-gateway-api-and-inferencepool-crds)) |
| `.cache/images.lock` | every image, pinned to a digest |
| images in `IMAGE_REGISTRY/<host>/<path>` | the cluster pulls from here |
| `gs://<bucket>/<org>/<model>/` | the weights of every profile's `model` and `draftModel` |
| `dist/llm-d-bundle-<sha>-<date>.tar.gz` | everything above except images and weights; carry it into the air gap |

`bundle.sh` uploads the weights itself (it needs `hf` and `gcloud`). To upload by hand instead, keep this layout: the plain Hugging Face repo files at `<org>/<name>/`.

```bash
hf download Qwen/Qwen3.8-27B --local-dir /tmp/m/Qwen/Qwen3.8-27B --exclude ".cache/*"
gcloud storage rsync --recursive /tmp/m/Qwen/Qwen3.8-27B gs://<bucket>/Qwen/Qwen3.8-27B
```

Inside the air gap, unpack the tarball. The machine that runs `deploy.sh` (a Jenkins agent or a workstation) needs `kubectl` (≥ 1.27, with kustomize v5), `helm` ≥ 3.8, `yq` v4, `git` and `python3`. It doesn't need internet access.

---

## 3. Write a profile

### 3.1 Choose a strategy

| Your situation | `modelserver.overlay` | `router.values` |
| --- | --- | --- |
| Default: any dense model, multi-turn or agentic traffic | `guides/optimized-baseline/modelserver/gpu/vllm/base` | `guides/optimized-baseline/router/optimized-baseline.values.yaml` |
| Long shared prefixes, more than fit in HBM | `guides/tiered-prefix-cache/modelserver/gpu/vllm/native/cpu/gke` | `guides/tiered-prefix-cache/router/single-host/tiered-prefix-cache-cpu.values.yaml` |
| Long prompts with short answers; tune TTFT and ITL separately (needs RDMA) | `guides/pd-disaggregation/modelserver/gpu/vllm/gke` | `guides/pd-disaggregation/router/pd-disaggregation.values.yaml` |
| P/D plus reuse of evicted prefixes | P/D overlay + `combos/pd-tiered-cpu` | P/D values + `combos/pd-tiered-cpu/router.values.yaml` |
| Large MoE (DeepSeek-class) across nodes (needs full-mesh RDMA) | `guides/wide-ep/modelserver/gpu/vllm/gke` | `guides/wide-ep/router/wide-ep.values.yaml` + `gpu.values.yaml` |
| A model with an upstream recipe (DeepSeek-V4, GLM-5.2, Kimi-K3.1, Nemotron-3-Ultra, Qwen3.5-397B) | `guides/models/<model>/...` | `guides/models/<model>/router/...` |

Rules worth knowing:
- **Aggregated overlays** (baseline, tiered) take any model through `model`, `modelserver.tensorParallel`, `replicas` and `args`.
- **P/D and wide-EP** take `model` and `args`, but size each role differently. To change GPU counts there, use `modelserver.patches` or an upstream model recipe.
- **Router values replace each other; they don't merge.** The EPP plugin graph is one string, so layering `tiered` on top of `pd` does not give you both. Combinations need one merged router values file, like `combos/pd-tiered-cpu/router.values.yaml`.
- **Names are at most 40 characters.** If the name gets longer, set `modelAlias`.

### Sample A: any Hugging Face model on the baseline

```yaml
# profile: profiles/gemma-4-31b-baseline-agentgateway.yaml
model: google/gemma-4-31B-it              # HF id; weights at gs://<bucket>/google/gemma-4-31B-it/
strategy: baseline                        # → name gemma-4-31b-it-baseline-vllm
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base
  tensorParallel: 2                       # --tensor-parallel-size=2 and 2 GPUs per replica
  replicas: 2
  # args: [...]                           # this model's own vLLM flags (parsers, chat template, limits)
router:
  values:
    - guides/optimized-baseline/router/optimized-baseline.values.yaml
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
```

The overlay was written for Qwen3-32B. The pipeline swaps in your model and **drops Qwen's tool/reasoning-parser flags**. Put your model's own flags in `args`; the model's vLLM recipe at `recipes.vllm.ai/<org>/<model>` lists them. Also check that the overlay's vLLM image (v0.31.0) supports the architecture.

### Sample B: model with built-in MTP speculative decoding

```yaml
# profile: profiles/qwen3.8-27b-baseline-agentgateway.yaml
model: Qwen/Qwen3.8-27B
strategy: baseline
speculativeConfig:                        # no draftModel: the model drafts with its own MTP layers
  method: mtp
  num_speculative_tokens: 3
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base
  tensorParallel: 1                       # H200/B200; use 2 on H100-80GB
  replicas: 2
  args:                                   # from https://recipes.vllm.ai/Qwen/Qwen3.8-27B
    - --enable-auto-tool-choice
    - --tool-call-parser=qwen3_coder
    - --reasoning-parser=qwen3
router:
  values:
    - guides/optimized-baseline/router/optimized-baseline.values.yaml
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
```

### Sample C: speculative decoding with a separate draft model

```yaml
# profile: profiles/baseline-specdec-agentgateway.yaml
model: Qwen/Qwen3-32B
strategy: baseline-specdec                # different strategy → different name from plain baseline
draftModel: Qwen/Qwen3-0.6B               # same tokenizer; fetched from gs://<bucket>/Qwen/Qwen3-0.6B/
speculativeConfig:                        # optional; "model" is filled in from draftModel
  num_speculative_tokens: 5
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base
router:
  values:
    - guides/optimized-baseline/router/optimized-baseline.values.yaml
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
```

`--speculative-config` is added **only** when `draftModel` or `speculativeConfig` is set. Overlays that already use MTP (GLM-5.2) reject a draft model.

### Sample D: tiered prefix cache (HBM → CPU RAM)

```yaml
# profile: profiles/tiered-cpu-gke.yaml
model: Qwen/Qwen3-32B
strategy: tiered-cpu
modelserver:
  overlay: guides/tiered-prefix-cache/modelserver/gpu/vllm/native/cpu/gke    # 300 GiB CPU tier per replica
router:
  values:
    - guides/tiered-prefix-cache/router/single-host/tiered-prefix-cache-cpu.values.yaml
gateway:
  provider: gke                            # GKE Gateway → HealthCheckPolicy rendered
  name: llm-d-inference-gateway
  namespace: gateway-infra
```

The CPU tier lives in `/dev/shm`. The tier size, the shm `sizeLimit`, the pod memory and the router's `lruCapacityPerServer` must always change together.

### Sample E: prefill/decode disaggregation

```yaml
# profile: profiles/pd-gke.yaml
model: openai/gpt-oss-120b
strategy: pd                               # 1 prefill (TP=1) + 1 decode (TP=4), NIXL KV transfer over RDMA
modelserver:
  overlay: guides/pd-disaggregation/modelserver/gpu/vllm/gke
router:
  values:
    - guides/pd-disaggregation/router/pd-disaggregation.values.yaml
gateway:
  provider: gke
  name: llm-d-inference-gateway
  namespace: gateway-infra
```

Needs LWS ([1.4](#14-leaderworkerset-only-for-pd-and-wide-ep)). The EPP stays at 1 replica because P/D load accounting is per process.

### Sample F: P/D + tiered prefix cache (combination)

```yaml
# profile: profiles/pd-tiered-cpu-agentgateway.yaml
model: openai/gpt-oss-120b
strategy: pd-tiered-cpu
modelserver:
  overlay: guides/pd-disaggregation/modelserver/gpu/vllm/gke
  components:
    - guides/recipes/modelserver/components/disaggregatedset-schema   # must come first: patch by name, not index
    - combos/pd-tiered-cpu                 # prefill: NIXL producer + CPU OffloadingConnector, 100 GiB
router:
  values:
    - guides/pd-disaggregation/router/pd-disaggregation.values.yaml
    - combos/pd-tiered-cpu/router.values.yaml    # ONE merged plugin graph: P/D profiles + GPU+CPU prefix index
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
```

`lruCapacityPerServer` and `peakPrefillThroughput` in the combo are estimates. Calibrate them with `guides/recipes/router/calibration` before production.

### Sample G: wide-EP + P/D + tiered KV cache (upstream recipe)

```yaml
# profile: profiles/wide-ep-pd-tiered-glm-agentgateway.yaml
model: zai-org/GLM-5.2-FP8                 # 8 nodes / 64 H200, InfiniBand
strategy: wide-ep-pd-tiered
modelserver:
  overlay: guides/models/glm-5-2/modelserver/gpu/vllm/deployments/default
router:
  values:
    - guides/models/glm-5-2/router/glm-5-2.values.yaml
    - guides/models/glm-5-2/router/glm-5.2-overrides.values.yaml   # last wins: fixed GPU+CPU index size
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
waitTimeout: 120m                          # large models load slowly
```

### Sample H: several models on one Gateway

Set `gateway.baseModel` in every profile that shares the Gateway, so each route matches only its own model:

```yaml
# profile: profiles/qwen3.8-27b-shared-agentgateway.yaml
model: Qwen/Qwen3.8-27B
strategy: baseline
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base
  tensorParallel: 1
  args: [--enable-auto-tool-choice, --tool-call-parser=qwen3_coder, --reasoning-parser=qwen3]
router:
  values:
    - guides/optimized-baseline/router/optimized-baseline.values.yaml
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
  baseModel: Qwen/Qwen3.8-27B             # route matches X-Gateway-Base-Model-Name: Qwen/Qwen3.8-27B
```

Then register the model with IPP ([1.6](#16-several-models-on-one-gateway-inference-payload-processor)):

```yaml
# ipp-qwen3.8.yaml   →  kubectl apply -n llm-d -f ipp-qwen3.8.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: qwen3-8-27b-model-mapping
  labels:
    inference.llm-d.ai/ipp-managed: "true"
data:
  baseModel: "Qwen/Qwen3.8-27B"            # the "model" value clients send
```

If routes already exist on the Gateway and `baseModel` is not set, `deploy.sh` stops.

### Sample I: changing what an overlay hard-codes (patch)

For anything without a profile field, such as memory or GPU count per P/D role, add a kustomize patch:

```yaml
# models/gpt-oss-pd-bigger-decode/patch.yaml   →  modelserver.patches: [models/gpt-oss-pd-bigger-decode/patch.yaml]
apiVersion: disaggregatedset.x-k8s.io/v1
kind: DisaggregatedSet
metadata:
  name: pd-disagg-vllm                     # upstream name (renaming happens after patches)
spec:
  roles:
    - name: decode
      spec:
        leaderWorkerTemplate:
          workerTemplate:
            spec:
              containers:
                - name: modelserver
                  resources:
                    limits:   {memory: 128Gi}
                    requests: {memory: 128Gi}
```

For a `DisaggregatedSet`, list `guides/recipes/modelserver/components/disaggregatedset-schema` in `modelserver.components`, so patches merge roles, containers and volumes by name.

---

## 4. Validate offline

None of these steps need a cluster:

```bash
cd pipeline
./deploy.sh profiles/qwen3.8-27b-baseline-agentgateway.yaml --name     # qwen3-8-27b-baseline-vllm
./deploy.sh profiles/qwen3.8-27b-baseline-agentgateway.yaml --env      # every resolved setting
IMAGE_REGISTRY=us-docker.pkg.dev/<project>/llm-d MODEL_BUCKET=gs://<bucket> \
  ./deploy.sh profiles/qwen3.8-27b-baseline-agentgateway.yaml --dry-run
less .build/qwen3-8-27b-baseline-vllm/{modelserver,router}.yaml        # exactly what will be applied
./test.sh                                                               # all profiles, ~10 s
```

`--dry-run` stops at the first problem: a misspelled key, a name over 40 characters, an image missing from the bundle, a draft model on an MTP overlay, `tensorParallel` on P/D, and so on. `test.sh` checks the wiring that would otherwise only fail at runtime:
- the pool selects exactly this deployment's pods;
- no names collide in the shared namespace;
- the route points at the right Gateway;
- weights are fetched from GCS and loaded offline;
- the model, TP, args and speculative config reached every vLLM container;
- every image is mirrored and digest-pinned.

---

## 5. Deploy

```bash
cd pipeline
export NAMESPACE=llm-d                                   # defaults shown
export SERVICE_ACCOUNT=llm-d-modelserver
export MODEL_BUCKET=gs://<bucket>                        # unset = download from Hugging Face (needs HF_TOKEN)
export IMAGE_REGISTRY=us-docker.pkg.dev/<project>/llm-d  # unset = public registries
./deploy.sh profiles/qwen3.8-27b-baseline-agentgateway.yaml
```

What happens:
1. **Render.** The model servers come from the overlay, the router from the cached chart. Then the pipeline renames resources, labels pods, adds the fetch step, swaps the model, sets args and pins images.
2. **Preflight.** It checks that the namespace, ServiceAccount, CRDs (plus LWS for P/D and wide-EP) and Gateway exist. It also checks that the Gateway accepts routes from `llm-d`, and that no other route already claims `/` unless `baseModel` is set.
3. **Apply the router.** The EPP, `InferencePool` and `HTTPRoute` are applied, and the script waits for the EPP rollout.
4. **Apply the model servers.** On each node, `fetch-model` copies the weights to local SSD once. Pods on the same node share the copy, and restarts skip the download. vLLM then loads the weights offline.
5. **Wait.** It waits for the HTTPRoute to be accepted and for all pods to be Ready (`waitTimeout`, default 60m).
6. **Smoke test.** It sends one `/v1/completions` request through the Gateway.

---

## 6. Verify and call the model

```bash
N=qwen3-8-27b-baseline-vllm
kubectl get pods,inferencepool,httproute -n llm-d -l llm-d.ai/deployment=$N
kubectl logs -n llm-d -l llm-d.ai/deployment=$N -c fetch-model --tail=5       # "ready: /model-cache/hub/..."
kubectl get httproute $N -n llm-d -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'

IP=$(kubectl get gateway llm-d-inference-gateway -n agentgateway-system -o jsonpath='{.status.addresses[0].value}')
curl -s http://$IP/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen/Qwen3.8-27B",
  "messages": [{"role": "user", "content": "Say hello in one word."}],
  "max_tokens": 32
}'
```

Clients always send the **Hugging Face model id**, even though the weights come from GCS.

---

## 7. Day-2 operations

| Task | How |
| --- | --- |
| Change flags, replicas or TP | Edit the profile, then `./deploy.sh <profile>` (`--dry-run` first). |
| New weights for the same model | Upload them to a **new path** (`gs://<bucket>/Qwen/Qwen3.8-27B@2026-12-01`), set `weights.gcsUri` to it, and redeploy. Nodes cache by path, so the same path is not re-downloaded. |
| Add a model | Write a profile, run `./bundle.sh profiles/<new>.yaml` on the connected side (images and weights), then deploy. |
| Remove a deployment | `./deploy.sh <profile> --delete`. This removes exactly the rendered model-server and router objects. The ServiceAccount, namespace and Gateway stay. |
| Upgrade llm-d | Change `llmdRef` (or `LLMD_REF`), run `./test.sh`, and re-run `./bundle.sh`. If upstream moved or reordered something, the render fails before anything reaches a cluster. |
| Free node disk | Delete old model folders under `/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models/hub/` on the node. The cache is never evicted automatically. |

Moving to a newer router chart version does not prune resources the new version dropped. Run `--delete` with the old render first.

---

## 8. Run it from Jenkins

The bundle tarball is the job's input. The agent needs no internet access.

```groovy
// Jenkinsfile (sample)
pipeline {
  agent { label 'llm-d-deployer' }            // kubectl, helm, yq, git, python3
  parameters {
    string(name: 'PROFILE', defaultValue: 'qwen3.8-27b-baseline-agentgateway', description: 'profiles/<PROFILE>.yaml')
    choice(name: 'ACTION', choices: ['dry-run', 'deploy', 'delete'])
    choice(name: 'CLUSTER', choices: ['gpu-staging', 'gpu-prod'])
  }
  environment {
    NAMESPACE      = 'llm-d'
    IMAGE_REGISTRY = 'us-docker.pkg.dev/<project>/llm-d'
    MODEL_BUCKET   = 'gs://<bucket>'
  }
  options { timeout(time: 3, unit: 'HOURS') }
  stages {
    stage('Unpack bundle') {                  // .cache/ from the latest bundle.sh run
      steps { copyArtifacts projectName: 'llm-d-bundle', selector: lastSuccessful(), target: 'bundle'
              sh 'tar -xzf bundle/dist/llm-d-bundle-*.tar.gz -C pipeline ./.cache' }
    }
    stage('Validate') { steps { dir('pipeline') { sh './test.sh' } } }
    stage('Render') {
      steps { dir('pipeline') {
        sh "./deploy.sh profiles/${params.PROFILE}.yaml --dry-run"
        archiveArtifacts artifacts: '.build/**/*.yaml'          // exactly what gets applied
      } }
    }
    stage('Approve') {
      when { expression { params.ACTION != 'dry-run' && params.CLUSTER == 'gpu-prod' } }
      steps { input message: "${params.ACTION} ${params.PROFILE} on ${params.CLUSTER}?" }
    }
    stage('Apply') {
      when { expression { params.ACTION != 'dry-run' } }
      steps { dir('pipeline') {
        withCredentials([file(credentialsId: "kubeconfig-${params.CLUSTER}", variable: 'KUBECONFIG')]) {
          lock("gateway-${params.CLUSTER}") {                   // preflight checks shared Gateway routes
            sh "./deploy.sh profiles/${params.PROFILE}.yaml ${params.ACTION == 'delete' ? '--delete' : ''}"
          }
        }
      } }
    }
  }
}
```

---

## 9. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Every request returns **503** on GKE | `gateway.provider` is not `gke`, so no `HealthCheckPolicy` was rendered. Set `provider: gke` and redeploy. |
| `HTTPRoute ... not accepted` / deploy waits at the route | The Gateway listener doesn't allow routes from `llm-d`. Set `allowedRoutes.namespaces.from: All` (or a matching Selector). |
| `Gateway already has routes ...; set BASE_MODEL` | Another model already owns `/`. Set `gateway.baseModel` in every profile, and install IPP ([1.6](#16-several-models-on-one-gateway-inference-payload-processor)). |
| Pod stuck in `Init:0/1`, the `fetch-model` log shows 403 | The ServiceAccount can't read the bucket. Check the Workload Identity binding ([1.5](#15-shared-namespace-serviceaccount-and-access-to-the-weights-bucket)) and Private Google Access. |
| `fetch-model` log shows "fetching" for a long time | Expected on a node's first download (hundreds of GB). Other pods on the node wait on its lock. Later starts skip it. |
| `ImagePullBackOff` | The node SA lacks `artifactregistry.reader`, or the image wasn't mirrored. Re-run `bundle.sh` with `IMAGE_REGISTRY`. |
| `image ... is not in .cache/images.lock` | The profile uses an image the bundle doesn't have. Run `./bundle.sh profiles/<it>.yaml` on the connected side. |
| `cannot fetch llm-d` / `cannot pull ...chart` | No network and no `.cache/`. Unpack the bundle into `pipeline/`. |
| `derived name ... at most 40 chars` | Set `modelAlias` (for example `llama33-70b`). |
| `unknown key(s) in ...` | A typo in the profile. The message names the key. |
| vLLM: `unrecognized arguments` or parser errors after a model swap | Put the new model's parser and chat-template flags in `modelserver.args`. The old model's flags were dropped. |
| vLLM OOM or KV-cache-too-small at startup | Raise `tensorParallel`, lower `--max-model-len` / `--gpu-memory-utilization` in `args`, or remove the draft model. |
| Pods Pending: insufficient `nvidia.com/gpu` or ephemeral storage | Not enough free GPUs or local SSD. Check node pool size, `tensorParallel × replicas`, and the model size against local SSD. |
| P/D: decode errors under load, `Connection reset` | Keep-alive mismatch. The upstream P/D overlay sets `VLLM_HTTP_TIMEOUT_KEEP_ALIVE=120`; keep it if you patch the env. |

---

## Appendix: reference

**Profile keys:** `model`, `strategy`, `modelAlias`, `engine`, `nameTemplate`, `draftModel`, `speculativeConfig`, `modelserver.{overlay, components, patches, args, tensorParallel, replicas}`, `router.{values, set, mode, chartVersion}`, `gateway.{provider, name, namespace, baseModel}`, `weights.{gcsUri, draftGcsUri}`, `llmdRef`, `waitTimeout`. See the commented schema in [`../README.md`](../README.md).

**Environment** (the same for every model, set by Jenkins):

| Variable | Default | Purpose |
| --- | --- | --- |
| `NAMESPACE` | `llm-d` | shared namespace |
| `SERVICE_ACCOUNT` | `llm-d-modelserver` | pre-existing; model-server pods run as it |
| `MODEL_BUCKET` | (unset) | `gs://` bucket with weights; unset = Hugging Face |
| `IMAGE_REGISTRY` | (unset) | private registry; needs `.cache/images.lock` |
| `MODEL_CACHE_PATH` | `/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models` | node-local weight cache |
| `DOWNLOADER_IMAGE` | `gcr.io/google.com/cloudsdktool/google-cloud-cli:slim` | `fetch-model` image (mirrored by `bundle.sh`) |
| `HF_TOKEN` | (unset) | only when `MODEL_BUCKET` is unset |
