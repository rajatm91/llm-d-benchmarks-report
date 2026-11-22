# Configuration

Every setting the pipeline reads, what it does, and when to use it, followed by the catalog of upstream llm-d templates a profile can point at. For a first deploy, follow [guide 01](guides/01-first-deployment.md); come back here when you want to change something.

- [1. Where each setting lives](#1-where-each-setting-lives)
- [2. Which knob for which change](#2-which-knob-for-which-change)
- [3. Environment settings](#3-environment-settings)
- [4. Profile fields](#4-profile-fields)
- [5. Catalog: model-server overlays](#5-catalog-model-server-overlays)
- [6. Catalog: router values](#6-catalog-router-values)
- [7. Catalog: components](#7-catalog-components)
- [8. Router chart keys (`router.set`)](#8-router-chart-keys-routerset)
- [9. What has no knob (and how to do it anyway)](#9-what-has-no-knob-and-how-to-do-it-anyway)
- [10. Differences between the two pinned llm-d versions](#10-differences-between-the-two-pinned-llm-d-versions)

The template lists are from llm-d **v1.0.0** (`llmdRef: 378b42d…`). The pipeline's default `LLMD_REF` (`565373b…`, a later `main` commit) has the same layout plus a few extras ([10](#10-differences-between-the-two-pinned-llm-d-versions)). To browse the templates of the ref you pin, run `./deploy.sh <profile> --dry-run` once and look under `.cache/llm-d-<ref>/guides/`.

## 1. Where each setting lives

Each layer can change anything the layer above it set:

```
environment (envs/<env>.env, Jenkins)   where it runs: cluster, namespace, SA, registry, bucket
└─ profile (profiles/<name>.yaml)       what runs
   ├─ model servers = upstream overlay                (modelserver.overlay)
   │                 + kustomize components, in order (modelserver.components)
   │                 + your kustomize patches, in order (modelserver.patches)
   │                 + pipeline rewrites: model, image, args, tensorParallel, replicas, weights
   └─ router       = llm-d router chart               (router.chartVersion)
                     + guides/recipes/router/base.values.yaml   (always first)
                     + values files, in order          (router.values)
                     + pool selector, gateway, prefix-index size (set by the pipeline)
                     + helm --set entries              (router.set, last)
```

Rule of thumb: use a **profile field** when one exists, a **component** when upstream already ships the change, a **patch** for anything else on the model servers, and a **values file** or `router.set` for the router.

**Inspect before you deploy.** `./deploy.sh <profile> --env` prints every resolved setting; `--dry-run` writes the exact manifests to `.build/<name>/`.

## 2. Which knob for which change

| I want to… | Use | Example |
| --- | --- | --- |
| Serve a different model | `model` + `modelserver.args` | [guide 02](guides/02-bring-your-own-model.md) |
| Change GPU count per replica / replica count (baseline, tiered) | `modelserver.tensorParallel` / `replicas` | `tensorParallel: 2` |
| Change GPU count on P/D or wide-EP | `modelserver.patches` or a component | [guide 04 step 5](guides/04-pd-disaggregation.md#5-change-what-the-overlay-hard-codes) |
| Add vLLM flags | `modelserver.args` | `[--max-model-len=32768]` |
| Use a newer vLLM | `modelserver.image` | `docker.io/vllm/vllm-openai:v0.34.0` |
| Speculative decoding | `draftModel` and/or `speculativeConfig` | [guide 02](guides/02-bring-your-own-model.md#3-speculative-decoding) |
| Pin the llm-d version | `llmdRef` + `router.chartVersion` + `router.set: [router.epp.image.tag=...]` | [guide 02](guides/02-bring-your-own-model.md#5-pin-the-llm-d-and-vllm-versions) |
| Node selector, tolerations, memory, shm, env vars | `modelserver.patches` | [guide 04 step 5](guides/04-pd-disaggregation.md#5-change-what-the-overlay-hard-codes) |
| Size the router's prefix index for my model | `modelserver.kvCache` | [fine-tuning.md](fine-tuning.md) |
| Change router plugins or weights | a values file in this repo, listed in `router.values` | `combos/<name>/router.values.yaml` |
| Change one router chart value | `router.set` | `router.epp.replicas=2` |
| Longer request timeout | `gateway.timeoutSec` | `900` |
| Share a Gateway with other models | `gateway.baseModel` + IPP | [guide 06](guides/06-multi-model-gateway.md) |
| New weights for the same model | `weights.gcsUri` (new folder) | `gs://models_registry/qwen__qwen3_8_27b_v2` |
| Name too long | `modelAlias` | `modelAlias: llama33-70b` |
| Another cluster / namespace / registry | env file | [3](#3-environment-settings) |
| Metrics in Cloud Monitoring | `MONITORING=gmp` | [3](#3-environment-settings) |

## 3. Environment settings

These describe the target, not the model. Put them in `envs/<env>.env` (copy [`envs/example.env`](../envs/example.env)) and pass `--env-file <env>` (or `-e`), or set them in Jenkins.

```bash
cp envs/example.env envs/prod.env
./deploy.sh -e prod profiles/<name>.yaml     # envs/prod.env; a path works too
```

The file's values win over the shell. Only the names below are allowed: a typo (`IMAGE_REMOTE`) stops the run with "did you mean IMAGE_REMOTES?". The scripts also catch CRLF line endings, curly quotes, and spaces around `=`. `envs/*.env` other than `example.env` are git-ignored.

### Target cluster

| Variable | Default | Set it when |
| --- | --- | --- |
| `KUBECONFIG` | kubectl's default | Always, in practice. `deploy.sh` uses the current context and prints it first; a kubeconfig file per environment that holds only that cluster makes a wrong-cluster deploy impossible. |
| `NAMESPACE` | `llm-d` | Your shared model namespace has another name. Must exist. |
| `SERVICE_ACCOUNT` | `llm-d-modelserver` | Your model-server SA has another name. Must exist in `NAMESPACE` and read the bucket. |
| `ROUTER_SERVICE_ACCOUNT` | unset | Your cluster forbids creating ServiceAccounts. The EPP then runs as this existing SA (the chart's `<name>-epp` SA is dropped; its Roles/ClusterRole are bound to this one). |

### Weights

| Variable | Default | Set it when |
| --- | --- | --- |
| `MODEL_BUCKET` | `gs://models_registry` | garuda stores weights in another bucket. |
| `MODEL_CACHE_PATH` | `/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models` | Your nodes' local SSD is mounted elsewhere. |
| `DOWNLOADER_IMAGE` | `gcr.io/google.com/cloudsdktool/google-cloud-cli:slim` | You want another `gcloud` image for `fetch-model`. |

### Images

| Variable | Default | Set it when |
| --- | --- | --- |
| `IMAGE_REGISTRY` | unset (public registries) | The cluster pulls from your registry, e.g. `us-docker.pkg.dev/<proj>/llm-d`. Every image is rewritten into it, pinned by digest from `.cache/images.lock`. |
| `IMAGE_TEMPLATE` | `{registry}/{host}/{path}@{digest}` | Your mirroring changes digests or flattens paths. Placeholders `{registry} {host} {path} {name} {tag} {digest}`. **Same value for `bundle.sh` and `deploy.sh`.** See [air-gapped.md](air-gapped.md#3-choose-the-image-layout). |
| `IMAGE_REMOTES` | unset | You use Artifact Registry remote (pull-through) repos: `'docker.io=<repo> ghcr.io=<repo> gcr.io=<repo> quay.io=<repo>'`. Those images are pulled through by digest and need no copying. |
| `SMOKE_IMAGE` | `docker.io/curlimages/curl:8.11.1` | You want another image for the post-deploy smoke test. |

### Monitoring

| Variable | Default | Set it when |
| --- | --- | --- |
| `MONITORING` | unset | `gmp`: create GKE Managed Prometheus `PodMonitoring` for vLLM (`<name>-modelserver`, every vLLM port) and the EPP (`<name>-epp`). The EPP runs with `--metrics-endpoint-auth=false`, so no token objects. Preflight checks the CRD. |
| `MONITORING_INTERVAL` | `15s` | You want another scrape interval. |

### Bundling (`bundle.sh`, `install-lws.sh`)

| Variable | Default | Set it when |
| --- | --- | --- |
| `OUT` | `dist` | Tarballs and the mirror list should go elsewhere. |
| `BUNDLE_STEPS` | `sources images` | GitHub and the image registries are reachable from different machines: run `sources` on one and `images` on the other. |
| `INFERENCE_CRDS_URL` | GAIE `releases/latest/.../v1-manifests.yaml` | You need a specific InferencePool CRD release. |
| `ROUTER_CRDS` | unset | `1`: also cache the llm-d-router CRDs (`InferenceObjective`, ...) for flow-control priorities. |
| `ROUTER_CRDS_URL` | llm-d-router `v1.0.0/manifests.yaml` | Another llm-d-router release. Must hold CRDs only. |
| `LWS_CHART` | unset | `1`: also bundle the LeaderWorkerSet chart and image (P/D, wide-EP air-gapped). |
| `LWS_VERSION` | `1.0.0` | Another LWS chart (P/D needs ≥ 0.11.1). |

Proxy variables (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and lowercase forms) are also allowed in env files.

## 4. Profile fields

A profile is one YAML file per model deployment. Unknown keys stop the render. The full schema, with defaults:

```yaml
model: Qwen/Qwen3-32B                # required
strategy: baseline                   # required
modelAlias: ""                       # default: last part of model
draftModel: ""
speculativeConfig: {num_speculative_tokens: 5}
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base   # required
  components: []
  patches: []
  args: []
  tensorParallel: <overlay's>
  replicas: <overlay's>
  image: <overlay's>
  kvCache: {gpuTokens: <unset>, bytesPerToken: <unset>}
router:
  values: []
  set: []
  mode: gateway
  chartVersion: v0
gateway:
  provider: none
  name: llm-d-inference-gateway
  namespace: <NAMESPACE>
  baseModel: ""
  timeoutSec: <chart's 300>
weights:
  gcsUri: <MODEL_BUCKET>/<folder of model>
llmdRef: 565373b741e90bffa27930b4669c6e1f222f6225
waitTimeout: 60m
```

### Identity

| Field | Required | Default | What and when |
| --- | --- | --- | --- |
| `model` | yes | | HF id. Clients send it as `model`; it also picks the GCS folder (`google/gemma-4-31B-it` → `google__gemma_4_31b_it`) and replaces the overlay's reference model everywhere. |
| `strategy` | yes | | Free-text tag in the name (`baseline`, `pd`, `g4`). Use a different value for each deployment of the same model, e.g. `baseline` and `baseline-specdec`. |
| `modelAlias` | | last part of `model` | When `<model>-<strategy>-<engine>` is over 40 characters. |
| `llmdRef` | | `LLMD_REF` in `lib/profile.sh` | Pin an llm-d commit (e.g. the `v1.0.0` tag's) for reproducible deploys. Pin `router.chartVersion` and the EPP image tag with it. |
| `waitTimeout` | | `60m` | Large models (wide-EP, hundreds of GB of weights) need longer: `120m`. |

### `modelserver`

| Field | Default | What and when |
| --- | --- | --- |
| `overlay` | required | The topology. A path under the llm-d repo (`guides/...`) or this repo. Catalog: [5](#5-catalog-model-server-overlays). The path must contain `/vllm/`, `/sglang/` or `/trtllm/`. |
| `components` | `[]` | Kustomize components applied in order on the overlay: upstream features (images, monitoring, RDMA) or this repo's combos. Catalog: [7](#7-catalog-components). |
| `patches` | `[]` | Your kustomize patch files, applied after components. For anything without a field: node pool, tolerations, memory, per-role GPU count. Use **upstream** resource names (renaming happens later). For a `DisaggregatedSet`, also list the `disaggregatedset-schema` component. |
| `args` | `[]` | Your model's `vllm serve` flags (parsers, chat template, context length). The overlay's model-specific flags (`--tool-call-parser`, `--reasoning-parser`, `--chat-template`, `--enable-auto-tool-choice`) are dropped first, so always set them for the new model. Inserted after the model id, shell-quoted (JSON values are safe). |
| `tensorParallel` | overlay's | Aggregated overlays (baseline, tiered) only. Sets `--tensor-parallel-size` and the GPU requests and limits. P/D and wide-EP stop the render: use `patches`. |
| `replicas` | overlay's | Aggregated overlays only. Replicas = nodes × GPUs per node ÷ `tensorParallel`. |
| `image` | overlay's | A newer or older vLLM. Only containers that run `vllm serve` change. Needs a tag or digest; air-gapped, re-run `bundle.sh` for the profile. |
| `kvCache.gpuTokens` | | Sizes a fixed-size router prefix index that covers GPU blocks (`combos/pd-tiered-cpu`, GLM-5.2): vLLM's `GPU KV cache size: N tokens`, per router endpoint. |
| `kvCache.bytesPerToken` | | Sizes a router prefix index that covers a CPU KV tier: KV bytes per token for the whole model. Unset values → the render warns and keeps the values file's number. Every deploy prints both, measured; see [fine-tuning.md](fine-tuning.md). |

### Speculative decoding

| Field | What and when |
| --- | --- |
| `draftModel` | HF id of a draft or EAGLE model with the same tokenizer. Weights come from GCS like the main model. Rejected on overlays that already set speculative decoding (GLM-5.2 MTP). |
| `speculativeConfig` | Map passed as `--speculative-config`. Default `{num_speculative_tokens: 5}`; `model` is filled from `draftModel`. Without `draftModel`, needs a `method` that brings its own drafter (`mtp`, `ngram`). |

`--speculative-config` is added only when one of the two is set. On P/D and wide-EP the render warns: upstream does not cover draft models there.

### `router`

| Field | Default | What and when |
| --- | --- | --- |
| `values` | `[]` | Values files layered after `base.values.yaml`, last wins. Normally the guide's own file(s); add your own file to change plugins. Catalog: [6](#6-catalog-router-values). |
| `set` | `[]` | `helm --set` entries, applied last. For single values: EPP image tag, replicas, resources. Keys: [8](#8-router-chart-keys-routerset). |
| `mode` | `gateway` | `standalone`: no Gateway, the EPP runs with a proxy sidecar behind its own Service (`<name>-epp`). |
| `chartVersion` | `v0` (moving) | Pin it (e.g. `v1.0.0`) together with `llmdRef`. |

The pipeline always sets these, so values files cannot change them: `router.modelServers.matchLabels`, `provider.name`, `httpRoute.create`, `httpRoute.inferenceGatewayName/Namespace`, `httpRoute.baseModel`.

### `gateway`

| Field | Default | What and when |
| --- | --- | --- |
| `provider` | `none` | `gke`, `agentgateway`, `istio` or `none`. **`gke` is required on GKE Gateways** (renders the health check policy; without it, 503s). |
| `name` | `llm-d-inference-gateway` | The existing Gateway to attach to. |
| `namespace` | `NAMESPACE` | The Gateway's namespace. Its listeners must allow routes from `NAMESPACE`. |
| `baseModel` | | Several models on one Gateway: the route matches the `X-Gateway-Base-Model-Name` header (set by IPP). Without it, preflight stops if the Gateway already has a catch-all route. |
| `timeoutSec` | chart's `300` | Long generations. GKE: `timeoutSec` on every `GCPBackendPolicy`. Others: the HTTPRoute request timeout. |

### `weights`

| Field | Default | What and when |
| --- | --- | --- |
| `gcsUri` | `MODEL_BUCKET/<folder of model>` | garuda used a non-standard folder, or you ship a new revision (always a **new** folder: nodes cache by path). |

## 5. Catalog: model-server overlays

`modelserver.overlay` picks one of these. Most guides have a `base` (any cluster) and a `gke` variant (GKE node selectors, local-SSD cache, RDMA where relevant). Paths are `guides/<guide>/modelserver/gpu/vllm/<variant>`.

**Status** comes from rendering each one with `./deploy.sh --dry-run`:
✅ renders and deploys with profile fields only; ➕ renders, but the guide also needs something outside the pipeline (listed); ❌ does not fit the pipeline.

| Guide | Variants | Router values | Status |
| --- | --- | --- | --- |
| `optimized-baseline` | `base` `gke` | `optimized-baseline/router/optimized-baseline.values.yaml` | ✅ |
| `precise-prefix-cache-routing` | `base` `gke` | `precise-prefix-cache-routing/router/precise-prefix-cache-routing.values.yaml` | ✅ |
| `predicted-latency-routing` | `base` `gke` | `predicted-latency-routing/router/predicted-latency.values.yaml` (also `-slo`, `-pd`, `-multimodal`) | ✅ |
| `tiered-prefix-cache` | `native/{cpu,fs}/{base,gke}`, `lmcache-connector/{cpu,fs}/{base,gke}`, `mooncake-store/{cpu,fs}/base`, `mooncake-store/fs/mooncake-client` | `tiered-prefix-cache/router/single-host/tiered-prefix-cache-cpu.values.yaml` (multi-host variant too) | ✅ `native`, `lmcache-connector`; ➕ `mooncake-store` needs a Mooncake master |
| `pd-disaggregation` | `base` `gke` `gke/base` `gke/a4x` `gke/a4xmax` `aws` `coreweave` `cks-mooncake` | `pd-disaggregation/router/pd-disaggregation.values.yaml` | ✅ with LWS. `base` has no image: add component `recipes/modelserver/components/images/gpu-vllm/release`. Sizing → `patches`. |
| `wide-ep` | `base` `gke` `coreweave` | `wide-ep/router/wide-ep.values.yaml` + `wide-ep/router/gpu.values.yaml` | ✅ with LWS; sizing → `patches` |
| `p2p-kv-cache-sharing` | `base` `rdma` | `p2p-kv-cache-sharing/router/p2p-kv-cache-sharing.values.yaml` | ✅ |
| `multimodal-serving/aggregation` | `base` `gke` | `multimodal-serving/aggregation/router/aggregation.values.yaml` | ✅ (use a vision model) |
| `multimodal-serving/e-disaggregation` | `e-p-d/{base,gke,coreweave}`, `e-pd/{base,gke,coreweave}` | `multimodal-serving/e-disaggregation/router/vllm/e-p-d-disaggregation.values.yaml` / `e-pd-…` | ➕ LWS; untested here |
| `flow-control` | none: uses `optimized-baseline` | `flow-control/router/flow-control.values.yaml` | ➕ priorities need `router.inferenceObjectives` and the `InferenceObjective` CRD; retune `maxConcurrency` |
| `turn-priority-fairness` | `base` `gke` (or `optimized-baseline`) | `turn-priority-fairness/router/turn-priority-fairness.values.yaml` | ➕ same as flow-control |
| `batch-serving/asynchronous-processing/multitenant` | `base` `gke` `single-gpu` | `…/values/router/flow-control-{evictable,holdback}.yaml` | ➕ objectives + async broker; untested here |
| `agentic-api` | `base` `gke` | `optimized-baseline/router/optimized-baseline.values.yaml` | ➕ Postgres secret and the agentic API service |
| `modelexpress-p2p` | `base` `gke` `coreweave` `fastsafetensors-{localnvme,nfs,prewarm}` | `modelexpress-p2p/router/modelexpress-p2p.values.yaml` | ➕ ModelExpress server |
| `fast-model-actuation` (and `-keda`) | `base` | `fast-model-actuation/router/fast-model-actuation.values.yaml` | ➕ FMA CRDs and controller (and KEDA) |
| `pod-snapshot` | `gke` | `pod-snapshot/router/pod-snapshot.values.yaml` | ➕ GKE pod snapshot resources and bucket |
| `coord-disaggregation` | `base` `gke` `coreweave` | three EPPs | ❌ the pipeline renders one router per deployment |
| `hyperconverged-cephfs` | `base` (default ref only) | | ➕ CephFS |

**Model-specific overlays** (`guides/models/<model>/modelserver/gpu/vllm/...`) are tuned for one model. Use them with that model; their args are model-specific.

| Model | Overlays | Router values |
| --- | --- | --- |
| `models/glm-5-2` | `deployments/default`, `deployments/p<N>w<N>d<N>w<N>` (P/D shapes), `deployments/benchmark/…`, `providers/coreweave`; SGLang under `gpu/sglang/…` | `models/glm-5-2/router/glm-5-2.values.yaml` + `glm-5.2-overrides.values.yaml` (`precise-routing.values.yaml` for `-precise`) |
| `models/deepseek-v4` | `base`, `base-low-latency`, `deployments/oci-*`, `providers/oci` | `models/deepseek-v4/router/deepseek-v4.values.yaml` |
| `models/nemotron-3-ultra` | `base` `gke` | `models/nemotron-3-ultra/router/nemotron-3-ultra.values.yaml` |
| `models/qwen3-5-397b` | TPU only (`tpu/vllm`, `tpu/vllm-disaggregated`) | `models/qwen3-5-397b/router/…` |
| `models/kimi-k3-1` | `base` `gke` (default ref only) | |

**Other accelerators and engines** exist for several guides: `amd/{vllm,sglang,atom}`, `cpu/vllm`, `xpu/…`, `tpu/…`, `biren/vllm`, `gpu/sglang`, `gpu/trtllm`. The pipeline handles `vllm`, `sglang` and `trtllm`, but `modelserver.image`, `args` and `tensorParallel` only rewrite vLLM containers; use `patches` for the others.

## 6. Catalog: router values

`router.values` takes any guide file from [5](#5-catalog-model-server-overlays), plus these feature recipes, which layer on any of them:

| File (`guides/recipes/router/…`) | Adds |
| --- | --- |
| `features/monitoring.values.yaml` | EPP metrics for the Prometheus operator. (On GKE, prefer `MONITORING=gmp`.) |
| `features/monitoring-gke.values.yaml` | Same with Google Managed Prometheus |
| `features/tracing.values.yaml` / `tracing-gke.values.yaml` | OpenTelemetry tracing from the EPP |
| `features/agentgateway-proxy.values.yaml` | Standalone mode with an agentgateway sidecar instead of Envoy |
| `features/httproute-flags.yaml` | Don't add it: the pipeline already sets these |

`guides/recipes/router/calibration/*.yaml` are not values files: they measure a running deployment. See [fine-tuning.md](fine-tuning.md).

**Your own values file** can live anywhere in this repo (e.g. `combos/<name>/router.values.yaml`). The usual reason is to change the EPP plugin config (`router.epp.pluginsCustomConfig`): copy the guide's file, edit it, and list your copy in `router.values` instead. Plugins used in the v1.0 guides:
- scorers: `prefix-cache-scorer`, `queue-scorer`, `kv-cache-utilization-scorer`, `token-load-scorer`, `active-request-scorer`, `no-hit-lru-scorer`, `latency-scorer`
- filters: `prefix-cache-affinity-filter`, `prefill-filter`, `decode-filter`, `encode-filter`, `slo-headroom-tier-filter`
- pickers: `max-score-picker`, `weighted-random-picker`
- producers: `approx-prefix-cache-producer`, `precise-prefix-cache-producer`, `inflight-load-producer`, `token-producer`, `predicted-latency-producer`
- P/D: `disagg-profile-handler`, `always-disagg-pd-decider`, `always-disagg-multimodal-decider`
- flow control (feature gate `flowControl`): `concurrency-detector`, `round-robin-fairness-policy`, `fcfs-ordering-policy`, `priority-holdback-policy`, `program-aware-fairness`, `latency-slo-admitter`

## 7. Catalog: components

`modelserver.components` entries, applied in order on the overlay.

| Component (`guides/recipes/modelserver/components/…`) | Use |
| --- | --- |
| `images/gpu-vllm/{release,nightly,aws-efa/release}` | Sets the vLLM image on overlays that leave a placeholder (`pd-disaggregation/.../base`). `modelserver.image` then overrides it. |
| `images/gpu-sglang/…`, `images/gpu-trtllm/release`, `images/{amd,xpu,tpu,cpu,npu,…}-…` | Same for other engines and accelerators |
| `images/routing-sidecar/{release,nightly}` | P/D routing sidecar image |
| `disaggregatedset-schema` | Lets your patches merge `DisaggregatedSet` roles, containers and volumes by name. **Add it first whenever you patch a P/D overlay.** |
| `monitoring`, `monitoring-pd` | `PodMonitor` for the model servers (Prometheus operator) |
| `graceful-shutdown` | Longer termination grace + preStop drain |
| `gke-rdma` | GPUDirect RDMA on GKE |
| `disable-gke-nccl-tuner-patch` | Turns off the GKE NCCL tuner |
| `model-cache`, `gke-model-cache-hostpath` | Upstream's weight cache. Don't combine with the pipeline's own GCS fetch. |

This repo's components:

| Component | Use |
| --- | --- |
| `combos/pd-tiered-cpu` | P/D + 100 GiB CPU KV tier on prefill. With `combos/pd-tiered-cpu/router.values.yaml`. [Guide 04](guides/04-pd-disaggregation.md). |
| `combos/g4-pd-sizing` | P/D on 3 × g4-standard-96 without RDMA: decode TP=1, one slice per node, GPU toleration. [Guide 07](guides/07-gemma-pd-tiered-g4.md). |

Model-specific components: `guides/models/glm-5-2/modelserver/gpu/vllm/components/{kv-events,no-mtp,offloading-cpu,offloading-tiered}`, `guides/models/deepseek-v4/modelserver/gpu/vllm/components/…`, `guides/modelexpress-p2p/modelserver/gpu/vllm/components/…`.

## 8. Router chart keys (`router.set`)

Applied last with `helm --set`. In the gateway chart, the router sub-chart's keys live under `router.`.

| Key | Default | Use |
| --- | --- | --- |
| `router.epp.image.tag` | `main` | **Pin it** (e.g. `v1.0.0`); the v1.0.0 chart still defaults to `main`. Also `.registry`, `.repository`. |
| `router.epp.replicas`, `router.epp.haMode` | 1 | EPP high availability. Keep 1 on P/D (load accounting is per process). |
| `router.epp.resources.*` | 4 CPU / 8 GiB | EPP size. |
| `router.epp.autoscaling.{enabled,minReplicas,maxReplicas,targetCPUUtilizationPercentage}` | off | HPA for the EPP. |
| `router.tokenizer.{enabled,modelName,image.*,resources.*}` | | Tokenizer sidecar (precise prefix routing). |
| `router.tracing.{enabled,otelExporterEndpoint,sampling.*}` | off | Tracing. |
| `router.inferencePool.failureMode` | `FailOpen` | What happens when the EPP is down. |
| `router.inferenceObjectives[i].{name,priority}` | `[]` | Flow-control priority bands (`x-llm-d-inference-objective` header). Needs the `InferenceObjective` CRD. Names are per namespace: prefix them with the deployment name. |
| `router.latencyPredictor.{trainingServer,predictionServers}.image.*` | | Predicted-latency routing images. |
| `provider.gke.preferredBackends.*` | | GKE backend balancing. |

Full list: `yq '..' .cache/charts/llm-d-router-gateway-<ver>/charts/router/values.yaml`.

## 9. What has no knob (and how to do it anyway)

| You want | Do this |
| --- | --- |
| Node pool, tolerations, affinity, memory, shm size, env vars | `modelserver.patches` |
| TP or replicas on P/D or wide-EP | `modelserver.patches` on the `DisaggregatedSet` / `LeaderWorkerSet` (+ `disaggregatedset-schema`) |
| Flow-control priorities | `router.inferenceObjectives` + the `InferenceObjective` CRD ([prerequisites §8](prerequisites.md#8-optional-add-ons)) |
| A guide that needs extra services (Mooncake, Postgres, ModelExpress, FMA, KEDA) | Apply them yourself before `deploy.sh`; air-gapped, mirror their images by hand. |
| Several EPPs for one deployment (`coord-disaggregation`) | Not supported |
| Autoscaling of model servers (WVA, KEDA, HPA) | Separate controllers (`guides/workload-autoscaling/*`) |

## 10. Differences between the two pinned llm-d versions

Only in the default `LLMD_REF` (`565373b…`, `main` from 2026-11-12), not in v1.0.0:
- `ocp` variants (OpenShift) for `optimized-baseline`, `pd-disaggregation`, `precise-prefix-cache-routing`, `predicted-latency-routing`, `tiered-prefix-cache`, `wide-ep`
- `gke` and `ocp` variants for `fast-model-actuation` (and `-keda`)
- `hyperconverged-cephfs`
- `models/kimi-k3-1`

Only in v1.0.0: `coord-disaggregation/modelserver/gpu/vllm/common`.

A profile without `llmdRef` follows the pipeline default. To pin one version, set `llmdRef`, `router.chartVersion` and `router.epp.image.tag` together ([guide 02 §5](guides/02-bring-your-own-model.md#5-pin-the-llm-d-and-vllm-versions)).
