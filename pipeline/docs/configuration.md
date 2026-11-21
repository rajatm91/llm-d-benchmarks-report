# What you can configure

This is the full catalog: every setting the pipeline reads, and every upstream llm-d template a profile can point at. For a first deploy, follow [deploy-guide.md](deploy-guide.md); this page is what to come back to when you want to change something.

The template lists are from llm-d **v1.0.0** (`llmdRef: 378b42d…`). The pipeline's default `LLMD_REF` (`565373b…`, a later `main` commit) has the same layout plus a few extras, listed in [9](#9-differences-between-the-two-pinned-llm-d-versions). To list the templates of whatever ref you pin, run `./deploy.sh <profile> --dry-run` once (it fetches the ref into `.cache/llm-d-<ref>/`) and look under `guides/`.

## 1. How a deployment is put together

Each layer can change anything the layer above it set:

```
environment (envs/<env>.env, Jenkins)   where it goes: cluster, namespace, SA, GAR, bucket
└─ profile (profiles/<name>.yaml)       what runs
   ├─ model servers = upstream overlay
   │                 + modelserver.components   (kustomize components, in order)
   │                 + modelserver.patches      (your kustomize patches, in order)
   │                 + model / image / args / tensorParallel / replicas / weights   (pipeline rewrites)
   └─ router       = llm-d router chart (router.chartVersion)
                     + guides/recipes/router/base.values.yaml   (always first)
                     + router.values            (values files, in order)
                     + pool selector + gateway  (set by the pipeline)
                     + router.set               (helm --set, last)
```

The rule of thumb: use a **profile field** when one exists, a **component** when upstream already ships the change, a **patch** for anything else on the model servers, and a **values file** or `router.set` for anything on the router.

## 2. Environment settings

These describe the target, not the model, so they live in `envs/<env>.env` (copy [`envs/example.env`](../envs/example.env)) or in Jenkins. They are the same for every profile.

| Variable | Default | Read by | What it does |
| --- | --- | --- | --- |
| `KUBECONFIG` | kubectl's default | deploy | Which cluster. `deploy.sh` uses the current context. |
| `NAMESPACE` | `llm-d` | deploy | Shared namespace for all models. Must exist. |
| `SERVICE_ACCOUNT` | `llm-d-modelserver` | deploy | Pre-existing SA the model-server pods run as. Needs read access to the bucket. |
| `MODEL_BUCKET` | `gs://models_registry` | deploy | Where garuda stores weights, one folder per model. |
| `MODEL_CACHE_PATH` | `/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models` | deploy | hostPath on each node that caches weights (GKE local SSD). |
| `DOWNLOADER_IMAGE` | `gcr.io/google.com/cloudsdktool/google-cloud-cli:slim` | deploy, bundle | Image of the init container that copies weights from GCS. |
| `SMOKE_IMAGE` | `docker.io/curlimages/curl:8.11.1` | deploy, bundle | Image of the post-deploy smoke test. |
| `IMAGE_REGISTRY` | unset (public registries) | deploy, bundle | Your registry, e.g. `us-docker.pkg.dev/<proj>/llm-d`. Set it and every image is rewritten into it. |
| `IMAGE_REMOTES` | unset | deploy, bundle | Artifact Registry remote repos, one per upstream host: `'docker.io=<repo> ghcr.io=<repo> gcr.io=<repo> quay.io=<repo>'`. Images from a listed host become `<repo>/<upstream path>@<digest>` and are left off the mirror list. Other hosts use `IMAGE_REGISTRY`. |
| `IMAGE_TEMPLATE` | `{registry}/{host}/{path}@{digest}` | deploy, bundle | Layout inside `IMAGE_REGISTRY`. Placeholders: `{registry} {host} {path} {name} {tag} {digest}` ([`lib/images.sh`](../lib/images.sh)). Must be the same for bundle and deploy. |
| `OUT` | `dist` | bundle | Where the tarball and mirror list go. |
| `BUNDLE_STEPS` | `sources images` | bundle | `sources` = guides, charts, CRDs (GitHub) packed as `llm-d-sources-*.tar.gz`; `images` = digests, mirror list, final bundle from an existing `.cache/` (registries only). Split across two machines. |
| `INFERENCE_CRDS_URL` | GAIE `releases/latest/.../v1-manifests.yaml` | bundle | InferencePool CRDs cached into `.cache/crds/`. |
| `ROUTER_CRDS` | unset | bundle | `1` = also cache the llm-d-router CRDs (`InferenceObjective`, `InferenceModelRewrite`) as `.cache/crds/llm-d-router.yaml`. Needed for flow-control priorities. |
| `ROUTER_CRDS_URL` | llm-d-router `releases/download/v1.0.0/manifests.yaml` | bundle | Where those come from. Must hold CRDs only. |
| `LWS_CHART` | unset | bundle | `1` = also bundle LeaderWorkerSet: chart (with CRDs) into `.cache/charts/lws-<LWS_VERSION>/`, image `registry.k8s.io/lws/lws` into the lock and mirror list. Install it air-gapped with `./install-lws.sh`. |
| `LWS_VERSION` | `1.0.0` | bundle, install-lws | LWS chart version (P/D needs ≥ 0.11.1). |

## 3. Profile fields

Unknown keys stop the render (typos never fall back to defaults). `./deploy.sh <profile> --env` prints what a profile resolves to.

### Identity and naming

| Field | Required | Default | Notes |
| --- | --- | --- | --- |
| `model` | yes | | HF id. Clients send it as `model`; also picks the GCS folder (`google/gemma-4-31B-it` → `google__gemma_4_31b_it`). |
| `strategy` | yes | | Free-text tag in the name, e.g. `baseline`, `pd`, `flowctl`. |
| `modelAlias` | | last part of `model` | Shorter slug when the name would go over 40 characters. |

Every resource is named `<model>-<strategy>-<engine>` (engine from the overlay path: `/vllm/`, `/sglang/` or `/trtllm/`). The name must be a DNS label of at most 40 characters.
| `llmdRef` | | pipeline's `LLMD_REF` | llm-d commit whose `guides/` are used. Pin a release tag's commit for reproducible deploys. |
| `waitTimeout` | | `60m` | How long to wait for pods to be ready. |

### `modelserver`

| Field | Default | Notes |
| --- | --- | --- |
| `overlay` | required | Path under the llm-d repo (`guides/...`) or this repo. Catalog in [4](#4-model-server-overlays). |
| `components` | `[]` | Kustomize components layered on the overlay, in order. Catalog in [6](#6-components-you-can-layer). Paths under `guides/` or this repo (e.g. `combos/pd-tiered-cpu`). |
| `patches` | `[]` | Your kustomize patch files, applied after components. Use upstream resource names (renaming happens after). For a `DisaggregatedSet`, also add the `disaggregatedset-schema` component so patches merge lists by name. |
| `image` | overlay's | Replaces the image of the vLLM containers only (not sidecars or init containers). Needs a tag or digest. |
| `args` | `[]` | Extra `vllm serve` flags. Flags tied to the overlay's reference model are dropped first. |
| `tensorParallel` | overlay's | Aggregated (Deployment) overlays only. Sets `--tensor-parallel-size` and the GPU count. |
| `replicas` | overlay's | Aggregated overlays only. For P/D and wide-EP, use `patches`. |

### Speculative decoding

| Field | Notes |
| --- | --- |
| `draftModel` | HF id of a draft or EAGLE model. Weights come from GCS like the main model. |
| `speculativeConfig` | Map passed as `--speculative-config`. Default `{num_speculative_tokens: 5}`. Without `draftModel`, it needs a `method` that brings its own drafter (`mtp`, `ngram`, ...). Rejected if the overlay already sets speculative decoding. |

### `weights`

| Field | Default | Notes |
| --- | --- | --- |
| `gcsUri` | `$MODEL_BUCKET/<folder of model>` | Exact folder, e.g. for a new revision. Use a new folder for new weights: nodes cache by path. |

### `router`

| Field | Default | Notes |
| --- | --- | --- |
| `mode` | `gateway` | `gateway` (HTTPRoute on an existing Gateway) or `standalone` (EPP with an Envoy sidecar, no Gateway). |
| `chartVersion` | `v0` (moving) | Router chart version. Pin it (e.g. `v1.0.0`) together with `llmdRef`. |
| `values` | `[]` | Values files layered after `base.values.yaml`. Catalog in [5](#5-router-values). |
| `set` | `[]` | `helm --set` entries, applied last. Keys in [7](#7-router-chart-keys-routerset). |

The pipeline always sets these, so values files can't change them: `router.modelServers.matchLabels` (this deployment's pods only), `provider.name`, `httpRoute.create`, `httpRoute.inferenceGatewayName/Namespace`, `httpRoute.baseModel`.

### `gateway`

| Field | Default | Notes |
| --- | --- | --- |
| `provider` | `none` | `gke`, `agentgateway`, `istio` or `none`. Picks the provider-specific objects (HealthCheckPolicy, DestinationRule, ...). |
| `name` | `llm-d-inference-gateway` | Existing Gateway. Upstream manifests for one: `guides/recipes/gateway/<agentgateway|gke-l7-rilb|gke-l7-regional-external-managed|istio|kgateway|envoy-ai-gateway|nginx-gateway-fabric>`. |
| `namespace` | `$NAMESPACE` | Gateway's namespace. Its listeners must allow routes from `$NAMESPACE`. |
| `baseModel` | | Needed when several models share one Gateway (routes match on `X-Gateway-Base-Model-Name`; needs IPP). Without it, the render stops if the Gateway already has routes. |

## 4. Model-server overlays

`modelserver.overlay` picks one of these. Most guides have a `base` (any cluster) and a `gke` variant (GKE node selectors, local-SSD cache, RDMA where relevant). All paths are `guides/<guide>/modelserver/gpu/vllm/<variant>`.

**Status** comes from rendering each one through `./deploy.sh --dry-run` with its router values:
- ✅ renders and deploys with profile fields only;
- ➕ renders, but the guide also needs something outside the pipeline (listed);
- ❌ does not fit the pipeline as it is.

| Guide | Variants | Router values | Status |
| --- | --- | --- | --- |
| `optimized-baseline` | `base` `gke` | `optimized-baseline/router/optimized-baseline.values.yaml` | ✅ (used by most profiles) |
| `precise-prefix-cache-routing` | `base` `gke` | `precise-prefix-cache-routing/router/precise-prefix-cache-routing.values.yaml` | ✅ |
| `predicted-latency-routing` | `base` `gke` | `predicted-latency-routing/router/predicted-latency.values.yaml` (also `-slo`, `-pd`, `-multimodal`) | ✅ (latency predictor images come from the chart) |
| `tiered-prefix-cache` | `native/{cpu,fs}/{base,gke}`, `lmcache-connector/{cpu,fs}/{base,gke}`, `mooncake-store/{cpu,fs}/base`, `mooncake-store/fs/mooncake-client` | `tiered-prefix-cache/router/single-host/tiered-prefix-cache-cpu.values.yaml` (multi-host variant too) | ✅ for `native` and `lmcache-connector`; ➕ `mooncake-store` needs a Mooncake master |
| `pd-disaggregation` | `base` `gke` `gke/base` `gke/a4x` `gke/a4xmax` `aws` `coreweave` `cks-mooncake` | `pd-disaggregation/router/pd-disaggregation.values.yaml` | ✅ with LWS ≥ 0.11.1 (`enableDisaggregatedSet=true`). `base` has no image: add component `recipes/modelserver/components/images/gpu-vllm/release`, or use `gke`. `tensorParallel`/`replicas` → `patches`. |
| `wide-ep` | `base` `gke` `coreweave` | `wide-ep/router/wide-ep.values.yaml` + `wide-ep/router/gpu.values.yaml` | ✅ with LWS; sizing → `patches` |
| `p2p-kv-cache-sharing` | `base` `rdma` | `p2p-kv-cache-sharing/router/p2p-kv-cache-sharing.values.yaml` | ✅ |
| `multimodal-serving/aggregation` | `base` `gke` | `multimodal-serving/aggregation/router/aggregation.values.yaml` | ✅ (use a vision model) |
| `multimodal-serving/e-disaggregation` | `e-p-d/{base,gke,coreweave}`, `e-pd/{base,gke,coreweave}` | `multimodal-serving/e-disaggregation/router/vllm/e-p-d-disaggregation.values.yaml` / `e-pd-…` | ➕ LWS; untested here |
| `flow-control` | none: uses `optimized-baseline` | `flow-control/router/flow-control.values.yaml` | ➕ priorities need `router.inferenceObjectives` ([7](#7-router-chart-keys-routerset)) and the `InferenceObjective` CRD (`ROUTER_CRDS=1 ./bundle.sh`); retune `maxConcurrency` (`guides/flow-control/tuning.md`) |
| `turn-priority-fairness` | `base` `gke` (or `optimized-baseline`) | `turn-priority-fairness/router/turn-priority-fairness.values.yaml` | ➕ same as flow-control |
| `batch-serving/asynchronous-processing/multitenant` | `base` `gke` `single-gpu` | `…/values/router/flow-control-{evictable,holdback}.yaml` | ➕ objectives + async broker; untested here |
| `agentic-api` | `base` `gke` | `optimized-baseline/router/optimized-baseline.values.yaml` | ➕ Postgres secret and the agentic API service |
| `modelexpress-p2p` | `base` `gke` `coreweave` `fastsafetensors-{localnvme,nfs,prewarm}` | `modelexpress-p2p/router/modelexpress-p2p.values.yaml` | ➕ ModelExpress server (`modelexpress/modelexpress-server.yaml`) |
| `fast-model-actuation` (and `-keda`) | `base` | `fast-model-actuation/router/fast-model-actuation.values.yaml` | ➕ FMA CRDs and controller (and KEDA) |
| `pod-snapshot` | `gke` | `pod-snapshot/router/pod-snapshot.values.yaml` | ➕ GKE pod snapshot resources and bucket |
| `coord-disaggregation` | `base` `gke` `coreweave` | three EPPs (`coord-disaggregation-{encode,prefill,decode}.values.yaml`) | ❌ the pipeline renders one router per deployment |
| `hyperconverged-cephfs` | `base` (default ref only) | | ➕ CephFS |

**Model-specific overlays** (`guides/models/<model>/modelserver/gpu/vllm/...`) are tuned for one model. Use them with that model; swapping in another model usually fails, because the args are model-specific.

| Model | Overlays | Router values |
| --- | --- | --- |
| `models/glm-5-2` | `deployments/default`, `deployments/p<N>w<N>d<N>w<N>` (P/D shapes), `deployments/benchmark/{baseline,offloading,mtp-offloading,full-isl-mtp-offloading}/…`, `providers/coreweave`; SGLang under `gpu/sglang/…` | `models/glm-5-2/router/glm-5-2.values.yaml` + `glm-5.2-overrides.values.yaml` (`precise-routing.values.yaml` for the `-precise` shape) |
| `models/deepseek-v4` | `base`, `base-low-latency`, `deployments/oci-*`, `providers/oci` | `models/deepseek-v4/router/deepseek-v4.values.yaml` |
| `models/nemotron-3-ultra` | `base` `gke` | `models/nemotron-3-ultra/router/nemotron-3-ultra.values.yaml` |
| `models/qwen3-5-397b` | TPU only (`tpu/vllm`, `tpu/vllm-disaggregated`) | `models/qwen3-5-397b/router/…` |
| `models/kimi-k3-1` | `base` `gke` (default ref only) | |

**Other accelerators and engines** exist for several guides (`optimized-baseline` has the most): `amd/{vllm,sglang,atom}`, `cpu/vllm`, `xpu/…`, `tpu/…`, `biren/vllm`, plus `gpu/sglang` and `gpu/trtllm` (router values `optimized-baseline-trtllm.values.yaml`, `tpu-v7.values.yaml`, `npu.rbln.values.yaml`). The pipeline handles `vllm`, `sglang` and `trtllm` engines, but `modelserver.image`, `args` and `tensorParallel` only rewrite vLLM; for other engines use `patches`.

## 5. Router values

`router.values` takes any of the guide files in [4](#4-model-server-overlays) plus these feature recipes, which can be layered on any of them:

| File (`guides/recipes/router/…`) | What it adds |
| --- | --- |
| `features/monitoring.values.yaml` | EPP metrics for Prometheus (`router.monitoring.prometheus.enabled`, needs the Prometheus operator) |
| `features/monitoring-gke.values.yaml` | Same with Google Managed Prometheus |
| `features/tracing.values.yaml` / `tracing-gke.values.yaml` | OpenTelemetry tracing from the EPP |
| `features/agentgateway-proxy.values.yaml` | `router.mode: standalone` with an agentgateway sidecar instead of Envoy |
| `features/httproute-flags.yaml` | Upstream's HTTPRoute flags; the pipeline already sets these, don't add it |

`guides/recipes/router/calibration/*.yaml` are not values files: they are ConfigMaps with scripts that measure a running deployment (peak prefill throughput, cached-token delta) to tune scorer weights.

Your own values file can sit anywhere in this repo (e.g. `combos/<name>/router.values.yaml`). The usual reason to write one is to change the EPP's plugin config (`router.epp.pluginsCustomConfig`): copy the guide's file, edit, and point `router.values` at your copy.

**EPP plugins used in the v1.0 guides**, for writing your own `pluginsCustomConfig`:
- scorers: `prefix-cache-scorer`, `queue-scorer`, `kv-cache-utilization-scorer`, `token-load-scorer`, `active-request-scorer`, `no-hit-lru-scorer`, `latency-scorer`
- filters: `prefix-cache-affinity-filter`, `prefill-filter`, `decode-filter`, `encode-filter`, `slo-headroom-tier-filter`
- pickers: `max-score-picker`, `weighted-random-picker`
- producers: `approx-prefix-cache-producer`, `precise-prefix-cache-producer`, `inflight-load-producer`, `token-producer`, `predicted-latency-producer`
- P/D: `disagg-profile-handler`, `always-disagg-pd-decider`, `always-disagg-multimodal-decider`
- flow control (feature gate `flowControl`): `concurrency-detector`, `round-robin-fairness-policy`, `fcfs-ordering-policy`, `priority-holdback-policy`, `program-aware-fairness`, `latency-slo-admitter`

## 6. Components you can layer

`modelserver.components` entries, applied in order on top of the overlay.

| Component (`guides/recipes/modelserver/components/…`) | Use |
| --- | --- |
| `images/gpu-vllm/{release,nightly,aws-efa/release}` | Sets the vLLM image on overlays that leave a placeholder (e.g. `pd-disaggregation/.../base`). `modelserver.image` then overrides it. |
| `images/gpu-sglang/…`, `images/gpu-trtllm/release`, `images/{amd,xpu,tpu,cpu,npu,…}-…` | Same for other engines and accelerators |
| `images/routing-sidecar/{release,nightly}` | P/D routing sidecar image |
| `disaggregatedset-schema` | Lets your `patches` merge `DisaggregatedSet` roles, containers and volumes by name. Add it whenever you patch a P/D overlay. |
| `monitoring`, `monitoring-pd` | `PodMonitor` for the model servers |
| `graceful-shutdown` | Longer termination grace + preStop drain |
| `gke-rdma` | GPUDirect RDMA networking on GKE (also `guides/pd-disaggregation/modelserver/components/gke-rdma`) |
| `disable-gke-nccl-tuner-patch` | Turns off the GKE NCCL tuner |
| `model-cache`, `gke-model-cache-hostpath` | Upstream's weight cache. The pipeline already adds its own GCS fetch + hostPath cache; don't combine. |

Model and guide specific components (with their own overlays):
- `guides/models/glm-5-2/modelserver/gpu/vllm/components/{kv-events,no-mtp,offloading-cpu,offloading-tiered}`
- `guides/models/deepseek-v4/modelserver/gpu/vllm/components/{decode-flashinfer,<N>p<N>d-*}`
- `guides/modelexpress-p2p/modelserver/gpu/vllm/components/{istio-mesh,shared-compile-cache}`

**Combining strategies** (e.g. P/D + tiered cache) is done with a component of your own in this repo plus an extra router values file. See `combos/pd-tiered-cpu/` and the README's combination table.

## 7. Router chart keys (`router.set`)

Applied last with `helm --set`. In the gateway chart, the router sub-chart's keys live under `router.`. The main ones:

| Key | Default | Use |
| --- | --- | --- |
| `router.epp.image.tag` | `main` | **Pin it**, e.g. `v1.0.0`; the v1.0.0 chart still defaults to `main`. Also `.registry`, `.repository`. |
| `router.epp.replicas`, `router.epp.haMode` | 1 | EPP high availability. `router.epp.crossReplica.{enabled,redis.address,…}` shares state between replicas. |
| `router.epp.resources.*` | 4 CPU / 8 GiB | EPP size. |
| `router.epp.autoscaling.{enabled,minReplicas,maxReplicas,targetCPUUtilizationPercentage}` | off | HPA for the EPP. |
| `router.epp.pluginsConfigFile` | | Which plugin config the EPP loads (set by the guide values). |
| `router.tokenizer.{enabled,modelName,image.*,resources.*}` | | Tokenizer sidecar (precise prefix routing). |
| `router.monitoring.prometheus.{enabled,auth.enabled}`, `router.monitoring.provider.name` | | EPP metrics. |
| `router.tracing.{enabled,otelExporterEndpoint,sampling.*}` | off | Tracing. |
| `router.inferencePool.failureMode` | `FailOpen` | What happens if the EPP is down. |
| `router.inferenceObjectives[i].{name,priority}` | `[]` | Creates `InferenceObjective`s pointing at this deployment's pool (flow-control priority bands; clients pick one with the `x-llm-d-inference-objective` header). They carry the deployment label, so `--delete` removes them. Names are per namespace: give each deployment its own (e.g. `<name>-premium`). |
| `router.latencyPredictor.{trainingServer,predictionServers}.image.*` | | Predicted-latency routing images. |
| `provider.gke.preferredBackends.*` | | GKE backend balancing (`balancingMode`, `maxRatePerEndpoint`, ...). |
| `httpRoute.requestTimeout` | | Route timeout for long generations. |

Full list: `yq '..' .cache/charts/llm-d-router-gateway-<ver>/charts/router/values.yaml`.

## 8. What is not configurable (and how to do it anyway)

| You want | Do this |
| --- | --- |
| Node pool, tolerations, affinity, memory, shm size, env vars | `modelserver.patches` |
| TP or replicas on P/D or wide-EP | `modelserver.patches` on the `DisaggregatedSet` / `LeaderWorkerSet` (+ `disaggregatedset-schema`) |
| Flow-control priorities | `router.inferenceObjectives` in `router.set` or a values file. Install the `InferenceObjective` CRD first: `ROUTER_CRDS=1 ./bundle.sh`, then `kubectl apply -f .cache/crds/llm-d-router.yaml`. `deploy.sh` stops if it is missing. |
| A guide that needs extra objects (Mooncake master, Postgres, ModelExpress, FMA, KEDA, ...) | Apply them yourself before `deploy.sh`. The pipeline only applies the model servers and the router. Air-gapped, mirror their images by hand too. |
| Several EPPs for one deployment (`coord-disaggregation`) | Not supported |
| Autoscaling (WVA, KEDA, HPA on model servers) | Separate controllers, see `guides/workload-autoscaling/*`; not part of a profile |
| Several models behind one Gateway | `gateway.baseModel` + IPP |

## 9. Differences between the two pinned llm-d versions

Only in the default `LLMD_REF` (`565373b…`, `main` from 2026-11-12), not in v1.0.0:
- `ocp` variants (OpenShift) for `optimized-baseline`, `pd-disaggregation`, `precise-prefix-cache-routing`, `predicted-latency-routing`, `tiered-prefix-cache`, `wide-ep`
- `gke` and `ocp` variants for `fast-model-actuation` (and `-keda`)
- `hyperconverged-cephfs`
- `models/kimi-k3-1`

Only in v1.0.0: `coord-disaggregation/modelserver/gpu/vllm/common`.

A profile without `llmdRef` follows the pipeline default; set `llmdRef` and `router.chartVersion` (and `router.epp.image.tag`) together to pin one version. See deploy-guide sample K.
