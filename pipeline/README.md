# llm-d deploy pipeline

**New here? Follow [docs/deploy-guide.md](docs/deploy-guide.md)**: a step-by-step walkthrough from an empty cluster to a serving model, with sample YAMLs for every strategy (checked by `docs/check-guide.sh`).

Reusable pipeline that deploys a model with any llm-d well-lit path (or a combination of them) and registers it with an **existing** Gateway (agentgateway, GKE Gateway, Istio, …).

It wraps the upstream [llm-d/llm-d](https://github.com/llm-d/llm-d) `guides/` (pinned by commit in `LLMD_REF`) instead of copying manifests, so upstream fixes come in by bumping one SHA.

```bash
./deploy.sh profiles/pd-tiered-cpu-agentgateway.yaml --dry-run   # render only, output in .build/<name>/
./deploy.sh profiles/pd-tiered-cpu-agentgateway.yaml             # deploy, wait, smoke test
./deploy.sh profiles/pd-tiered-cpu-agentgateway.yaml --delete
./test.sh                                                       # offline render checks for all profiles
```

Needs `kubectl` (with built-in kustomize), `helm` ≥ 3.8 (OCI), `yq` v4, `git`, `python3`.

---

## 0. Naming, namespace, ServiceAccount

Every model is deployed into **one shared namespace** (`NAMESPACE`, default `llm-d`), and its model-server pods run as **one pre-existing ServiceAccount** (`SERVICE_ACCOUNT`, default `llm-d-modelserver`). Both must exist before the first deploy. Preflight checks for them.

Names are derived, not hand-written: `NAME_TEMPLATE='{model}-{strategy}-{engine}'`.

| Part | Source | Example |
| --- | --- | --- |
| `{model}` | `MODEL_ALIAS`, or the HF repo name, lowercased, non-alphanumerics → `-` | `Qwen/Qwen3-32B` → `qwen3-32b` |
| `{strategy}` | `STRATEGY` in the profile | `pd-tiered-cpu` |
| `{engine}` | inferred from `MODELSERVER_OVERLAY` (`vllm`/`sglang`/`trtllm`), or `ENGINE` | `vllm` |

The result must be a DNS label of at most 40 characters. Set `MODEL_ALIAS` when it is longer. `./deploy.sh <profile> --name` prints it.

What `deploy.sh` does to the upstream render so that models can coexist:
- It drops upstream `ServiceAccount`s and points every `serviceAccountName` at `SERVICE_ACCOUNT`.
- It renames the workload to `NAME` (or `NAME-<role>` when there are several) and every other resource to `NAME-<upstream name>`, updating `resourceClaimTemplateName` references.
- It labels the workload and its pod templates with `llm-d.ai/deployment=NAME` and `llm-d.ai/strategy`. It fills `llm-d.ai/model` and `llm-d.ai/engine-type` only where upstream leaves them unset. Deployments also get `llm-d.ai/deployment` in their selector.
- The InferencePool selects `llm-d.ai/deployment=NAME`, so it never picks up another model's pods or helper pods (such as the GLM kv-cache-evictor DaemonSet, which carries the same `llm-d.ai/guide` label).

The router chart always creates its own EPP ServiceAccount (`NAME-epp`) and RBAC, because the EPP needs to watch pods and pools. The pre-existing SA covers model-server pods only. Upstream model-server SAs carry no RBAC, so a plain SA (plus image-pull secrets or workload identity, if you use them) is enough.

## 0a. Air-gapped deploy: `bundle.sh`

On a machine **with** internet access:
```bash
IMAGE_REGISTRY=us-docker.pkg.dev/<proj>/llm-d \
./bundle.sh                      # or: ./bundle.sh profiles/a.yaml profiles/b.yaml
```
1. **Renders every profile.** This fills `.cache/` (the pinned llm-d guides, the router chart under `.cache/charts/`, the InferencePool CRDs under `.cache/crds/`) and `.build/`.
2. **Locks image digests.** Every image the renders use, plus the smoke-test image, is resolved to a digest in `.cache/images.lock`. Moving tags like `:main`, `:nightly` and `:latest` are frozen there.
3. **Mirrors images** to `IMAGE_REGISTRY/<source host>/<path>` with crane, gcrane, skopeo or `docker buildx imagetools`. The copy is multi-arch and digest-preserving.
4. **Packs** this directory, including `.cache/`, into `dist/llm-d-bundle-<llmd sha>-<date>.tar.gz` (about 8 MB).

Without `IMAGE_REGISTRY`, step 3 is skipped (mirror with your own tooling, using the paths above). Model weights are not part of the bundle; see [0b](#0b-model-weights-from-gcs).

Inside the air gap, unpack the tarball and deploy as usual:
```bash
export IMAGE_REGISTRY=us-docker.pkg.dev/<proj>/llm-d
./deploy.sh profiles/<name>.yaml
```
`deploy.sh` needs no network. It reads the guides and chart from `.cache/` and rewrites every image to `$IMAGE_REGISTRY/...@sha256:<digest>`. An image that is not in `images.lock` fails the render. A new profile or an `llmdRef` bump means re-running `bundle.sh` (with just the new profiles is fine; the lock is merged). `./test.sh` checks the air-gapped rewrite for every profile whenever `images.lock` exists.

The router is applied from the rendered manifest (`kubectl apply --server-side`), like the model servers. The chart has no hooks or lookups, so this is what `helm install` would create, and it is exactly the manifest that `--dry-run` and Jenkins archive. All router objects carry `llm-d.ai/deployment=<name>`. Removing resources that disappeared between chart versions is not automatic: run `--delete` with the old render first.

## 0b. Model weights from GCS

Weights are **never downloaded or uploaded by this repo**. The garuda repo downloads them and stores them in GCS, and this pipeline assumes they are already there, one folder per model:

```
gs://models_registry/<folder>/          # the model repo files at the top: config.json, *.safetensors, tokenizer...
<folder> = HF id, lowercased, "/" -> "__", every other non-alphanumeric -> "_"
  google/gemma-4-31B-it  -> gs://models_registry/google__gemma_4_31b_it
  Qwen/Qwen3.8-27B       -> gs://models_registry/qwen__qwen3_8_27b
  zai-org/GLM-5.2-FP8    -> gs://models_registry/zai_org__glm_5_2_fp8
```
`MODEL_BUCKET` (default `gs://models_registry`) changes the bucket. `weights.gcsUri` / `weights.draftGcsUri` in a profile override the full path for one model. No Hugging Face access and no token are needed.

How it works: `deploy.sh` adds a `fetch-model` init container to every pod that runs `vllm serve`.
- **Download:** it runs `gcloud storage rsync` from the bucket to a node-local hostPath (`MODEL_CACHE_PATH`, default GKE local SSD `/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models`).
- **Layout:** the files go in as a Hugging Face cache entry (`hub/models--<org>--<name>/snapshots/<sha1(gs path)>`). vLLM gets `HF_HOME=/model-cache` and `HF_HUB_OFFLINE=1`, so the overlays keep passing the HF model ID unchanged and the served model name does not change.
- **One download per node:** a `flock` plus a completion marker means pods and ranks on the same node wait for a single download, and a restart skips it. Wide-EP downloads once on each node, in parallel.
- **Sanity check:** if the folder has no `config.json` at its top, `fetch-model` fails with a clear error and writes no marker, so the next start retries.

Prerequisites:
- **Bucket access:** the pre-existing `SERVICE_ACCOUNT` needs `roles/storage.objectViewer` on the bucket, granted through Workload Identity.
- **Network:** the nodes reach `storage.googleapis.com` through Private Google Access.
- **Image:** mirror `DOWNLOADER_IMAGE` to Artifact Registry and pin it.
- **Disk:** local SSD per node must be at least the model size. Cached models are never evicted, so clean old ones up yourself.

**Updating weights:** have garuda write them to a **new folder** and point `weights.gcsUri` at it. The node marker is keyed by path, so new files under the same path are not picked up by nodes that already hold that path.

## 0c. Speculative decoding with a draft model

```yaml
draftModel: Qwen/Qwen3-0.6B          # HF id of the draft (or an EAGLE head); omit -> no --speculative-config
speculativeConfig:                   # optional, default {num_speculative_tokens: 5}; "model" is filled from draftModel
  num_speculative_tokens: 5          # e.g. method: eagle3, draft_tensor_parallel_size: 1
```
- **Weights:** the draft comes from the same bucket and naming (`Qwen/Qwen3-0.6B` → `gs://models_registry/qwen__qwen3_0_6b`, override with `weights.draftGcsUri`). The same `fetch-model` step downloads both models into the node cache.
- **Flag placement:** `--speculative-config` is added to every vLLM container. In list-form overlays it is appended to `args`. In script-form overlays (`bash -c "exec vllm serve ..."`) it is inserted right after the model, because vLLM expects `vllm serve <model> --flags`. The render fails if any vLLM container ends up without the flag.
- **MTP overlays:** overlays that already configure speculative decoding (for example GLM-5.2's MTP) are rejected when `DRAFT_MODEL` is set.
- **P/D and wide-EP:** a draft model is not covered by the upstream guides on these paths, so the render prints a warning. Validate before production.
- **Naming:** use a distinct `STRATEGY` (for example `baseline-specdec`) so the derived name differs from the non-speculative deployment of the same model.

## 0d. Deploying any model

Strategies are model-agnostic. Each overlay ships a reference model (Qwen3-32B for baseline and tiered, gpt-oss-120b for P/D, …), but you can set `model:` to any HF id:

```yaml
model: google/gemma-4-31B-it
strategy: baseline
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base
  tensorParallel: 2
  replicas: 2
  args: [--max-model-len=32768]      # the new model's flags (parsers, chat template, limits)
```
- **Model id:** the overlay's reference id (found through its `llm-d.ai/model` label) is replaced in every vLLM command (list args or bash script, including the KV-events topic) and in the `llm-d.ai/model` labels and selector.
- **Old model's flags:** its model-specific flags (`--tool-call-parser`, `--reasoning-parser`, `--chat-template`, `--enable-auto-tool-choice`) are dropped. Put the new model's flags in `args`. They are inserted right after the model id, or appended for list-form overlays, and shell-quoted, so JSON values are safe.
- **vLLM image:** `modelserver.image` swaps the image of every container that runs `vllm serve`; sidecars, `fetch-model` and helper containers keep theirs. It must name a tag or digest. `bundle.sh` picks it up like any other image (lock + mirror), and with `IMAGE_REGISTRY` it is pinned by digest.
- **Sizing:** `tensorParallel` rewrites the TP flag and the GPU limits and requests, and `replicas` sets the Deployment replicas. Both work on aggregated overlays (baseline, tiered) only. P/D and wide-EP size each role differently, so use `modelserver.patches` or an upstream `guides/models/*` recipe there.
- **Check first:** confirm the overlay's vLLM image supports the architecture (v0.31.0 supports Gemma 4 and Qwen3.5/3.8) and take flags from the model's vLLM recipe (`recipes.vllm.ai/<org>/<model>`). The render cannot check that the model fits in GPU memory.

## 1. llm-d deployment strategies (well-lit paths)

Every llm-d deployment has the same two halves. That split is what lets strategies combine:

| Half | What it is | Upstream location | How the pipeline layers it |
| --- | --- | --- | --- |
| **Model servers** | vLLM/SGLang pods: topology (TP/DP/EP), KV connectors, memory | `guides/<path>/modelserver/<accel>/<engine>/<infra>/` (kustomize) | `MODELSERVER_OVERLAY` + `COMPONENTS` + `PATCHES` |
| **llm-d Router** | EPP (endpoint picker) + `InferencePool` (+ `HTTPRoute` in gateway mode) | `guides/<path>/router/*.values.yaml` (helm values) | `ROUTER_VALUES` (layered `-f`, last wins) |

| Path | What changes | Use when | Reference HW (upstream default) |
| --- | --- | --- | --- |
| **Optimized baseline** | Router: `prefix-cache-affinity-filter` + `token-load-scorer`. Aggregated vLLM `Deployment`. | Default for every model. Multi-turn and agentic traffic gains from prefix affinity. | Qwen3-32B, 2× TP=2 (4× H100) |
| **Precise prefix-cache routing** | Engines publish KV events over ZMQ. Router keeps an exact index (`precise-prefix-cache-producer`) instead of an approximate one. | High prefix reuse where the approximate index mis-routes. Costs a ZMQ subscription per rank. | same as baseline |
| **Predicted-latency routing** | Router scores by predicted TTFT/TPOT. | SLO-driven, mixed request sizes. | — |
| **Tiered prefix cache** | Engine: KV offload HBM → CPU RAM (→ shared FS or local NVMe). vLLM `OffloadingConnector` (native, recommended), LMCache, or SGLang HiCache. Router: GPU-tier and CPU-tier prefix indexes. | Working set of prefixes is bigger than HBM (long contexts, many sessions). | Qwen3-32B, 300 GiB CPU tier per replica |
| **P2P KV cache sharing** | Pods pull prefix KV from each other. | Prefix lives on a busy pod. | — |
| **P/D disaggregation** | `DisaggregatedSet` (LWS) with `prefill` and `decode` roles. NIXL KV transfer over RDMA. Decode pods get a routing sidecar. Router runs two scheduling profiles. | Long inputs with short outputs. Lets you size TTFT and ITL separately. Needs RDMA. | gpt-oss-120b, 1P TP=1 + 1D TP=4 (H200) |
| **Wide expert parallelism** | Large MoE as DP=EP across nodes (DeepEP / MoRI all-to-all). **Always P/D in llm-d.** The pool targets every DP-rank port (8000–8007). | DeepSeek-class MoE. Needs a full-mesh RDMA fabric (rail-only fails). | DeepSeek-R1, 32× H200 (DP16 P + DP16 D) |
| **Multimodal / Omni / Responses API** | E/P/D roles, omni engines, stateful API. | Specific workloads. | — |
| **Ops (any path)** | Autoscaling (WVA / KEDA), flow control, multi-model routing (IPP), batch, rollouts, fast actuation. | Fleet level. Orthogonal to the paths above. | — |

The **Models** recipes (`guides/models/*`: DeepSeek-V4, GLM-5.2, Qwen3.5-397B, …) are upstream's own *compositions* of these foundations, tuned per accelerator. When one matches your model, use it. That is what `wide-ep-pd-tiered-glm-agentgateway.yaml` does.

## 2. Registering with an existing Gateway

```
client ─► Gateway (agentgateway / GKE L7 / Istio)            ns: GATEWAY_NAMESPACE  (pre-existing, shared)
            └─ HTTPRoute  parentRef ─► Gateway                ns: NAMESPACE  ┐
                  └─ backendRef ─► InferencePool              ns: NAMESPACE  │ created by the
                        ├─ endpointPickerRef ─► EPP (ext-proc) ns: NAMESPACE  │ llm-d-router-gateway
                        └─ selector llm-d.ai/guide=<x> ─► model-server pods   ┘ chart + kustomize
```

The pipeline renders `oci://ghcr.io/llm-d/charts/llm-d-router-gateway` (cached in `.cache/charts/`) with `httpRoute.create=true`, `httpRoute.inferenceGatewayName=$GATEWAY_NAME`, `httpRoute.inferenceGatewayNamespace=$GATEWAY_NAMESPACE` and `provider.name=$GATEWAY_PROVIDER`. The route and the pool share a namespace, so no `ReferenceGrant` is needed.

| Provider | Gateway prerequisites (one-time, cluster admin) | `GATEWAY_PROVIDER` renders |
| --- | --- | --- |
| **agentgateway** | `helm install agentgateway oci://cr.agentgateway.dev/charts/agentgateway --set inferenceExtension.enabled=true` (plus the `agentgateway-crds` chart). GatewayClass `agentgateway`. Upstream's preferred self-installed gateway (kgateway recipes are deprecated). | nothing extra |
| **GKE Gateway** | Gateway API enabled, a proxy-only subnet, GatewayClass `gke-l7-rilb` (internal) or `gke-l7-regional-external-managed`. GKE ≥ 1.34.0-gke.1626000 manages the `InferencePool` CRD. | `HealthCheckPolicy` + `GCPBackendPolicy`. **Without these, the LB health check fails and requests return 503.** The HTTPRoute timeout is skipped on GKE. |
| Istio | Istio with the inference extension | `DestinationRule` |

Preflight checks done by `deploy.sh` before it applies anything:
- The Gateway exists. If it lives in another namespace, its listeners must allow routes from it (`allowedRoutes.namespaces.from: All` or a `Selector`).
- **One Gateway, many models:** two catch-all `/` routes on the same listener conflict (the oldest wins). If other routes are already attached, the pipeline refuses to continue unless `BASE_MODEL` is set. With `BASE_MODEL` set, the route matches on the `X-Gateway-Base-Model-Name` header, which [IPP](https://github.com/llm-d/llm-d/tree/main/guides/multi-model-routing) injects from the request body. Install IPP once per gateway.
- The required CRDs are present: `InferencePool`, plus LWS/`DisaggregatedSet` when the overlay needs them.

`ROUTER_MODE=standalone` skips the Gateway entirely: the EPP runs with an Envoy or agentgateway sidecar and gets its own Service.

## 3. Combining strategies

**Rule 1: the engine side composes through kustomize, the router side does not.**
Engine features stack as components on one topology overlay. The EPP plugin graph, however, is a single YAML string inside the helm values (`router.epp.pluginsCustomConfig.<file>`). Helm replaces strings and does not merge them. Layering `tiered.values.yaml` on top of `pd.values.yaml` therefore does not give you both: you have to write **one merged `EndpointPickerConfig`**. That is what `combos/*/router.values.yaml` contains.

**Rule 2: the topology is the base, everything else is an add-on.**
Pick the topology first: aggregated, P/D, or wide-EP (which implies P/D). Then layer the cache features on top of it.

**Rule 3: the pool selector must follow the pods.**
In a combination, the router values come from one guide (for example the `tiered-prefix-cache` labels) and the pods from another (for example `pd-disaggregation`). `deploy.sh` pins the pool's `llm-d.ai/guide` label to the value the rendered pods carry, and adds `llm-d.ai/deployment=NAME`. `test.sh` asserts that the pool selects every model-server pod and nothing else.

| Combination | Engine side | Router side | Status |
| --- | --- | --- | --- |
| Baseline + tiered | Tiered overlay *is* aggregated plus offload | Tiered values: GPU + CPU prefix indexes | upstream guide |
| **P/D + tiered (CPU)** | Prefill only: `MultiConnector` = `NixlConnector(kv_producer)` + `OffloadingConnector(kv_both)`. Decode stays a NIXL consumer, since prefix reuse happens on prefill. CPU tier lives in `/dev/shm`, so raise the shm `sizeLimit` and pod memory to match. | P/D profiles (prefill/decode). One `approx-prefix-cache-producer` with `autoTune: false` and capacity = GPU blocks + CPU blocks, so the affinity filter counts CPU-tier hits | **this repo: `combos/pd-tiered-cpu`** (same pattern as upstream GLM-5.2) |
| **Wide-EP + P/D + tiered (CPU + NVMe)** | `OFFLOADING_MODE=tiered` on prefill: `TieringOffloadingSpec`, CPU plus local NVMe `secondary_tiers` | Wide-EP config, index sized GPU + CPU (31k blocks per rank), DP-rank `targetPorts`, `disaggregatedset-rollout-screener` | upstream `guides/models/glm-5-2` (`components/offloading-{cpu,tiered}`) |
| Wide-EP + precise routing | Per-rank KV events plus render Service | `precise-prefix-cache-producer`. Engine `--block-size` must equal the router `blockSizeTokens` | upstream GLM-5.2 `p2w1d1w1-precise` |
| Any path + autoscaling / flow control / IPP | — | Separate controllers and plugins | upstream ops guides |

Re-tune these whenever you combine paths:
- `peakPrefillThroughput` (affinity-filter gate) depends on the hardware, the model and the path. A CPU-tier restore is slower than an HBM hit. Re-measure with `guides/recipes/router/calibration`.
- `lruCapacityPerServer` = (GPU KV bytes + CPU tier bytes) / (64 × KV bytes per token). The values in `combos/pd-tiered-cpu/router.values.yaml` are estimates for gpt-oss-120b on H200.
- CPU tier size, shm `sizeLimit` and pod memory always change together.

### Adding your own combination
1. Create `combos/<name>/kustomization.yaml` as a `kind: Component`. When the target is a `DisaggregatedSet`, list `guides/recipes/modelserver/components/disaggregatedset-schema` **before** it in `COMPONENTS`, so strategic-merge patches match roles, containers and volumes by name. Patch arg lists by index, guarded with JSON-patch `test` ops (see `combos/pd-tiered-cpu`). If upstream reorders the args, the render then fails instead of silently patching the wrong flag.
2. Create `combos/<name>/router.values.yaml` with **one** merged plugin config. Keep the config filename the base guide uses (`pd-config.yaml`, `wide-ep-config.yaml`, …).
3. Add a `profiles/<name>.yaml` and run `./test.sh`.

## 4. Profiles

| Profile | Strategy | Gateway |
| --- | --- | --- |
| `baseline-agentgateway.yaml` | Optimized baseline | agentgateway |
| `baseline-specdec-agentgateway.yaml` | Optimized baseline + draft-model speculative decoding | agentgateway |
| `qwen3.8-27b-baseline-agentgateway.yaml` | Qwen3.8-27B on baseline + built-in MTP (model swap example) | agentgateway |
| `gemma-4-31b-baseline-agentgateway.yaml` | Gemma 4 31B on baseline, TP=2 (model swap example) | agentgateway |
| `gemma-4-31b-llmd-1.0-vllm-0.34-agentgateway.yaml` | Gemma 4 31B pinned to **llm-d 1.0** (guides, chart, EPP image) + **vLLM v0.34.0**, 5 × g4-standard-48 | agentgateway |
| `tiered-cpu-gke.yaml` | Tiered prefix cache (CPU) | GKE |
| `pd-gke.yaml` | P/D | GKE |
| `pd-tiered-cpu-agentgateway.yaml` | **P/D + tiered CPU** (combo) | agentgateway |
| `wide-ep-gke.yaml` | Wide-EP (+ P/D) | GKE |
| `wide-ep-pd-tiered-glm-agentgateway.yaml` | **Wide-EP + P/D + CPU/NVMe tiered** (upstream composition) | agentgateway |

Profile schema (YAML). Unknown keys fail the render, so a typo can't silently fall back to a default:
```yaml
model: Qwen/Qwen3-32B                # required: HF id (also gives the GCS folder: qwen__qwen3_32b)
strategy: baseline-specdec           # required: the {strategy} part of the name
modelAlias: qwen3-32b                # optional: short {model} part when the name exceeds 40 chars
engine: vllm                         # optional: inferred from modelserver.overlay
nameTemplate: "{model}-{strategy}-{engine}"
draftModel: Qwen/Qwen3-0.6B          # optional: enables --speculative-config
speculativeConfig: {num_speculative_tokens: 5}   # with draftModel, or alone with a built-in method (method: mtp)
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base   # required
  components: [guides/recipes/modelserver/components/disaggregatedset-schema, combos/pd-tiered-cpu]
  patches: [models/llama-70b/patch.yaml]
  tensorParallel: 2                  # aggregated overlays only: --tensor-parallel-size + GPU count
  replicas: 2                        # aggregated overlays only
  args: [--enable-auto-tool-choice, --tool-call-parser=qwen3_coder]   # the model's own vLLM flags
  image: docker.io/vllm/vllm-openai:v0.32.0   # replaces the overlay's vLLM image (vLLM containers only)
router:
  values: [guides/optimized-baseline/router/optimized-baseline.values.yaml]   # layered in order, last wins
  set: []                            # extra helm --set
  mode: gateway                      # gateway | standalone
  chartVersion: v0
gateway: {provider: agentgateway, name: llm-d-inference-gateway, namespace: agentgateway-system, baseModel: ""}
weights: {gcsUri: "", draftGcsUri: ""}   # override $MODEL_BUCKET/<folder> per model
llmdRef: 565373b741e90bffa27930b4669c6e1f222f6225
waitTimeout: 60m
```
Environment-wide settings come from env vars or Jenkins, not from profiles: `NAMESPACE`, `SERVICE_ACCOUNT`, `MODEL_BUCKET`, `MODEL_CACHE_PATH`, `DOWNLOADER_IMAGE`, `IMAGE_REGISTRY`. `./deploy.sh <profile> --env` prints the resolved settings. Paths that start with `guides/` resolve inside the pinned llm-d checkout. Any other path resolves relative to this directory.

**Changing the model** means changing the engine args, the GPU counts and the router sizing. Upstream hard-codes all of them per overlay, so add a `PATCHES` file instead of expecting a single `MODEL` variable to rewrite them. `MODEL` is used only for the smoke test.
