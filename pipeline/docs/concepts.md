# Concepts

How the pipeline turns a profile into running pods, and the llm-d ideas you need to pick a strategy. Read this once before your first deploy.

- [1. Two halves: model servers and router](#1-two-halves-model-servers-and-router)
- [2. Profile and environment](#2-profile-and-environment)
- [3. What deploy.sh does](#3-what-deploysh-does)
- [4. Naming and the shared namespace](#4-naming-and-the-shared-namespace)
- [5. Model weights from GCS](#5-model-weights-from-gcs)
- [6. llm-d strategies (well-lit paths)](#6-llm-d-strategies-well-lit-paths)
- [7. Registering with a Gateway](#7-registering-with-a-gateway)
- [8. Combining strategies](#8-combining-strategies)

## 1. Two halves: model servers and router

Every llm-d deployment has two halves. The split is what lets strategies combine.

| Half | What it is | Upstream source | Profile keys |
| --- | --- | --- | --- |
| **Model servers** | vLLM (or SGLang, TRT-LLM) pods. Decides the topology (TP/DP/EP, aggregated or P/D), KV connectors and memory. | `guides/<guide>/modelserver/<accel>/<engine>/<variant>/` (a kustomize overlay) | `modelserver.overlay`, `.components`, `.patches` |
| **Router** | The EPP (endpoint picker), an `InferencePool`, and an `HTTPRoute` on your Gateway. Decides which pod gets each request (prefix-cache affinity, load, P/D pairing). | the llm-d router Helm chart + `guides/<guide>/router/*.values.yaml` | `router.values`, `router.set` |

You pick both from the **same** llm-d guide, unless you are combining guides ([8](#8-combining-strategies)).

## 2. Profile and environment

Settings are split by what they describe, so one profile deploys unchanged to staging and production:

| | Profile (`profiles/<name>.yaml`) | Environment (`envs/<env>.env`, or Jenkins) |
| --- | --- | --- |
| Describes | **what runs**: model, strategy, size, vLLM image and flags, llm-d version, Gateway | **where it runs**: cluster, namespace, ServiceAccount, registry, weights bucket |
| Changes | per model deployment | per cluster |
| Example keys | `model`, `strategy`, `modelserver.*`, `router.*`, `gateway.*` | `KUBECONFIG`, `NAMESPACE`, `IMAGE_REGISTRY`, `MODEL_BUCKET` |

Both are checked strictly: an unknown profile key or a misspelled environment name stops the run instead of silently falling back to a default. Every field is in [configuration.md](configuration.md).

## 3. What deploy.sh does

`deploy.sh` is only a list of steps. Each step lives in `lib/`:

| Step | Function | Effect |
| --- | --- | --- |
| Fetch | `fetch_llmd` | Clones llm-d at `llmdRef` into `.cache/llm-d-<sha>/` (reused when present). |
| Render model servers | `render_modelservers` | `kustomize` the overlay with `components`, then `patches`. |
| Share the namespace | `share_namespace` | Renames resources, re-labels pods, points pods at `SERVICE_ACCOUNT` ([4](#4-naming-and-the-shared-namespace)). |
| vLLM image | `set_vllm_image` | `modelserver.image` on every container that runs `vllm serve`. |
| Model swap | `swap_model` | Replaces the overlay's reference model with `model`, drops its model-specific flags. |
| Size | `set_size` | `tensorParallel` and `replicas` (aggregated overlays only). |
| Args | `add_vllm_args` | `modelserver.args` and `--speculative-config`. |
| Weights | `add_weights_fetch` | Adds the `fetch-model` init container and offline HF settings ([5](#5-model-weights-from-gcs)). |
| Monitoring | `add_vllm_monitoring` | `MONITORING=gmp`: `PodMonitoring` for vLLM and the EPP. |
| Render router | `render_router` | Router chart + values; pool selects only this deployment; sizes the prefix index from `modelserver.kvCache`. |
| Mirror images | `mirror_images` | With `IMAGE_REGISTRY` / `IMAGE_REMOTES`: every image → your registry, pinned by digest. |
| *(stop here with `--dry-run`)* | | Output: `.build/<name>/modelserver.yaml` and `router.yaml`. |
| Preflight | `preflight` | Namespace, ServiceAccount, CRDs, LWS, Gateway and its routes exist and fit. |
| Apply | `apply_all` | `kubectl apply --server-side`: router first (waits for the EPP), then model servers. |
| Wait | `wait_ready` | HTTPRoute accepted, all pods Ready within `waitTimeout`. |
| Smoke test | `smoke_test` | One `/v1/completions` request through the Gateway. |
| KV cache report | `kv_cache_report` | Prints the measured `modelserver.kvCache` to copy into the profile. |

The router is applied from its rendered manifest, not with `helm install`. The chart has no hooks or lookups, so the result is the same, and what gets applied is exactly what `--dry-run` produced (and what Jenkins archives).

## 4. Naming and the shared namespace

Every model is deployed into **one shared namespace** (`NAMESPACE`, default `llm-d`), and its model-server pods run as **one pre-existing ServiceAccount** (`SERVICE_ACCOUNT`, default `llm-d-modelserver`).

Names are derived, not written by hand: `<model>-<strategy>-<engine>`.

| Part | Source | Example |
| --- | --- | --- |
| `<model>` | `modelAlias`, or the last part of the HF id, lowercased, non-alphanumerics → `-` | `Qwen/Qwen3.8-27B` → `qwen3-8-27b` |
| `<strategy>` | `strategy` in the profile | `baseline` |
| `<engine>` | the overlay path: `/vllm/`, `/sglang/` or `/trtllm/` | `vllm` |

The name must be a DNS label of at most 40 characters (Helm and LWS append suffixes). Set `modelAlias` when it is longer. `./deploy.sh <profile> --name` prints it.

So that models can coexist, the render:
- drops upstream `ServiceAccount`s and points every `serviceAccountName` at `SERVICE_ACCOUNT`;
- renames the workload to `<name>` (or `<name>-<role>`) and every other resource to `<name>-<upstream name>`;
- labels workloads and pods with `llm-d.ai/deployment=<name>` and `llm-d.ai/strategy`;
- makes the `InferencePool` select `llm-d.ai/deployment=<name>`, so it never picks up another model's pods.

The router chart still creates its own EPP ServiceAccount (`<name>-epp`) with the RBAC it needs to watch pods and pools. Set `ROUTER_SERVICE_ACCOUNT` to use an existing account instead.

## 5. Model weights from GCS

This repo never downloads or uploads weights. The garuda repo stores them in GCS, one folder per model:

```
gs://models_registry/<folder>/          config.json, *.safetensors, tokenizer files at the top
<folder> = HF id lowercased, "/" → "__", every other non-alphanumeric → "_"
  google/gemma-4-31B-it  → gs://models_registry/google__gemma_4_31b_it
  Qwen/Qwen3.8-27B       → gs://models_registry/qwen__qwen3_8_27b
  zai-org/GLM-5.2-FP8    → gs://models_registry/zai_org__glm_5_2_fp8
```

The render adds a `fetch-model` init container to every vLLM pod:

- **Download.** `gcloud storage rsync` from the folder to a node-local hostPath (`MODEL_CACHE_PATH`, GKE local SSD by default).
- **Layout.** Files land as a Hugging Face cache entry. vLLM runs with `HF_HOME=/model-cache` and `HF_HUB_OFFLINE=1`, so it still gets the HF id, and clients still send the HF id as `model`.
- **Once per node.** A `flock` plus a completion marker: pods on the same node wait for one download, and restarts skip it.
- **Sanity check.** No `config.json` at the top of the folder → the init container fails with a clear error and retries on the next start.

The node cache is keyed by GCS path and never evicted. To ship new weights, have garuda write a **new folder** and point `weights.gcsUri` at it.

## 6. llm-d strategies (well-lit paths)

| Strategy | What changes | Use when | Upstream reference hardware |
| --- | --- | --- | --- |
| **Optimized baseline** | Router: prefix-cache affinity + token-load scoring. Aggregated vLLM `Deployment`. | Default for every model. Multi-turn and agentic traffic gain from prefix affinity. | Qwen3-32B, 2 × TP=2 (4 × H100) |
| **Precise prefix-cache routing** | Engines publish KV events; the router keeps an exact index instead of an approximate one. | High prefix reuse where the approximate index mis-routes. | as baseline |
| **Predicted-latency routing** | Router scores pods by predicted TTFT/TPOT (online-trained). | SLO-driven traffic with mixed request sizes. | — |
| **Tiered prefix cache** | Engine offloads KV from HBM to CPU RAM (or disk). Router indexes both tiers. | The working set of prefixes is bigger than HBM (long contexts, many sessions). | Qwen3-32B, 300 GiB CPU tier per replica |
| **P/D disaggregation** | Separate prefill and decode pods (`DisaggregatedSet`, LWS). KV moves over NIXL. | Long prompts, short answers; tune TTFT and ITL separately. Needs RDMA for full speed. | gpt-oss-120b, 1 P TP=1 + 1 D TP=4 (H200) |
| **Wide expert parallelism** | Large MoE as DP × EP across nodes. Always P/D in llm-d. | DeepSeek-class MoE. Needs full-mesh RDMA. | DeepSeek-R1, 32 × H200 |
| **P2P KV cache sharing** | Pods pull prefix KV from each other. | Hot prefixes live on a busy pod. | — |
| **Flow control, autoscaling, multi-model** | Admission control, WVA/KEDA, IPP. | Fleet-level needs. Orthogonal to the rows above. | — |

`guides/models/*` (GLM-5.2, DeepSeek-V4, Nemotron-3-Ultra, ...) are upstream's own compositions of these strategies, tuned for one model. Use one when it matches your model.

[configuration.md §5](configuration.md#5-catalog-model-server-overlays) lists every overlay and its router values; [guides/](guides/README.md) deploys the common ones step by step.

## 7. Registering with a Gateway

```
client ─► Gateway (agentgateway / GKE L7 / Istio)            ns: gateway.namespace (pre-existing, shared)
            └─ HTTPRoute  parentRef ─► Gateway                ns: NAMESPACE ┐
                  └─ backendRef ─► InferencePool              ns: NAMESPACE │ rendered by
                        ├─ endpointPickerRef ─► EPP           ns: NAMESPACE │ the pipeline
                        └─ selector llm-d.ai/deployment=<name> ─► vLLM pods ┘
```

The pipeline renders `oci://ghcr.io/llm-d/charts/llm-d-router-gateway` with the HTTPRoute pointed at `gateway.name` / `gateway.namespace`. Route and pool share a namespace, so no `ReferenceGrant` is needed. `gateway.provider` adds what that Gateway type needs:

| `gateway.provider` | Extra objects | Note |
| --- | --- | --- |
| `gke` | `HealthCheckPolicy`, `GCPBackendPolicy` | **Required on GKE**: without them the load balancer health check fails and every request returns 503. |
| `agentgateway` | none | Needs agentgateway installed with `inferenceExtension.enabled=true`. |
| `istio` | `DestinationRule` | Istio with the inference extension. |
| `none` | none | |

**One Gateway, many models.** The route is a catch-all (`/`), and two catch-alls on one Gateway conflict (the oldest wins). Preflight refuses to add a second one unless `gateway.baseModel` is set; the route then matches on the `X-Gateway-Base-Model-Name` header, which IPP sets from the request body. See [guide 06](guides/06-multi-model-gateway.md).

`router.mode: standalone` skips the Gateway: the EPP runs with a proxy sidecar behind its own Service.

## 8. Combining strategies

Three rules:

1. **The engine side composes through kustomize; the router side does not.** Engine features stack as components on one overlay. The EPP plugin graph, however, is one YAML string inside the Helm values (`router.epp.pluginsCustomConfig.<file>`), and Helm replaces strings instead of merging them. Layering `tiered.values.yaml` over `pd.values.yaml` gives you only the last one. A combination needs **one merged `EndpointPickerConfig`**, which is what `combos/*/router.values.yaml` holds.
2. **The topology is the base.** Pick aggregated, P/D or wide-EP first, then add cache features on top.
3. **The pool selector follows the pods.** The render pins the pool to the pods' labels whichever guide the router values came from, and `test.sh` checks that the pool selects every model-server pod and nothing else.

| Combination | Engine side | Router side | Where |
| --- | --- | --- | --- |
| Baseline + tiered | The tiered overlay is aggregated + offload | Tiered values (GPU + CPU indexes) | upstream guide |
| **P/D + tiered (CPU)** | Prefill: `MultiConnector` = NIXL producer + `OffloadingConnector`. Decode unchanged. | P/D profiles, one prefix index sized GPU + CPU | `combos/pd-tiered-cpu` ([guide 04](guides/04-pd-disaggregation.md)) |
| **Wide-EP + P/D + tiered (CPU + NVMe)** | Prefill tiered offload | Wide-EP config, index sized GPU + CPU | upstream `guides/models/glm-5-2` ([guide 05](guides/05-wide-ep.md)) |
| Wide-EP + precise routing | Per-rank KV events | `precise-prefix-cache-producer` | upstream GLM-5.2 `-precise` shape |

To add your own combination:
1. Create `combos/<name>/kustomization.yaml` as a `kind: Component`. For a `DisaggregatedSet`, list `guides/recipes/modelserver/components/disaggregatedset-schema` **before** it. Patch arg lists by index, guarded with JSON-patch `test` ops (see `combos/pd-tiered-cpu`), so an upstream reorder fails the render instead of patching the wrong flag.
2. Create `combos/<name>/router.values.yaml` with **one** merged plugin config, under the config filename the base guide uses (`pd-config.yaml`, ...).
3. Add a profile and run `./test.sh`.

After combining, re-tune the router: see [fine-tuning.md](fine-tuning.md).
