# 02. Bring your own model

Every llm-d overlay ships with a reference model (Qwen3-32B for the baseline, gpt-oss-120b for P/D, ...), but strategies are model-agnostic. This guide swaps in other models, adds speculative decoding, fits a model on one-GPU nodes, and pins the llm-d and vLLM versions.

Prerequisite: [guide 01](01-first-deployment.md) works on your cluster (Gateway, namespace, ServiceAccount, bucket access).

- [1. The workflow for any new model](#1-the-workflow-for-any-new-model)
- [2. Swap the model: Gemma 4 31B](#2-swap-the-model-gemma-4-31b)
- [3. Speculative decoding](#3-speculative-decoding)
- [4. One GPU per node: 5 × g4-standard-48](#4-one-gpu-per-node-5--g4-standard-48)
- [5. Pin the llm-d and vLLM versions](#5-pin-the-llm-d-and-vllm-versions)

## 1. The workflow for any new model

1. **Check vLLM support.** The overlay's vLLM image must support the architecture (the default ref ships v0.31.0, which covers Gemma 4 and Qwen3.5/3.8). If not, set `modelserver.image`.
2. **Get the model's flags** from its vLLM recipe, `https://recipes.vllm.ai/<org>/<model>`: tool-call and reasoning parsers, chat template, context length.
3. **Size it.** Weights (BF16 ≈ 2 bytes × parameters) plus KV cache must fit in `tensorParallel` GPUs. Replicas = GPUs available ÷ `tensorParallel`.
4. **Check the weights** are in GCS: `gcloud storage ls gs://models_registry/<folder>/config.json`.
5. **Write the profile**, `--dry-run`, read `.build/<name>/modelserver.yaml`, `./test.sh`.
6. **Deploy**, then confirm the vLLM startup log (`GPU KV cache size`, no argument errors).

What the pipeline does with `model`: it replaces the overlay's reference id in every vLLM command and in the `llm-d.ai/model` labels, and **drops the reference model's own flags** (`--tool-call-parser`, `--reasoning-parser`, `--chat-template`, `--enable-auto-tool-choice`). Your `modelserver.args` take their place.

`tensorParallel` and `replicas` work on aggregated overlays (baseline, tiered). P/D and wide-EP size each role separately: use patches there ([guide 04](04-pd-disaggregation.md#5-change-what-the-overlay-hard-codes)).

## 2. Swap the model: Gemma 4 31B

Gemma 4 31B in BF16 is about 62.5 GB, so on H100-80GB it needs TP=2.

**Step 1. Check the weights.**

```bash
gcloud storage ls gs://models_registry/google__gemma_4_31b_it/config.json
```

**Step 2. The profile.**

```yaml
# profile: profiles/gemma-4-31b-baseline-agentgateway.yaml
model: google/gemma-4-31B-it              # weights at gs://models_registry/google__gemma_4_31b_it/
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

**Step 3. Check the swap in the render.**

```bash
./deploy.sh profiles/gemma-4-31b-baseline-agentgateway.yaml --dry-run
yq 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="modelserver") | .args' \
  .build/gemma-4-31b-it-baseline-vllm/modelserver.yaml
```

Expect `google/gemma-4-31B-it`, `--tensor-parallel-size=2`, and no Qwen parser flags.

**Step 4. Deploy and call it** as in [guide 01 §7–8](01-first-deployment.md#7-deploy), with `"model": "google/gemma-4-31B-it"`.

## 3. Speculative decoding

Two ways, both set in the profile. `--speculative-config` is added only when one of them is present.

### 3a. Built-in MTP layers (no draft model)

Qwen3.8-27B drafts with its own multi-token-prediction layers:

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

### 3b. A separate draft model

A small model with the same tokenizer drafts for the big one. Its weights come from GCS too (`Qwen/Qwen3-0.6B` → `gs://models_registry/qwen__qwen3_0_6b`), fetched by the same init container.

```yaml
# profile: profiles/baseline-specdec-agentgateway.yaml
model: Qwen/Qwen3-32B
strategy: baseline-specdec                # different strategy → different name from plain baseline
draftModel: Qwen/Qwen3-0.6B               # same tokenizer; fetched from gs://models_registry/qwen__qwen3_0_6b/
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

Notes:
- Use a distinct `strategy` so the name differs from the non-speculative deployment of the same model; both can then run side by side.
- Overlays that already configure speculative decoding (GLM-5.2's MTP) reject a draft model.
- On P/D and wide-EP the render warns: upstream does not cover draft models there. Benchmark before production.

**Check:** `grep -- --speculative-config .build/<name>/modelserver.yaml`, then after deploy, the vLLM log shows the speculative config and, under load, acceptance rate metrics.

## 4. One GPU per node: 5 × g4-standard-48

A `g4-standard-48` has **one** NVIDIA RTX PRO 6000 (96 GB). Gemma 4 31B in BF16 fits on it, so run one whole-GPU replica per node (TP across nodes would go over the network). This also shows a newer vLLM image.

```yaml
# profile: profiles/gemma-4-31b-g4-agentgateway.yaml
model: google/gemma-4-31B-it              # gs://models_registry/google__gemma_4_31b_it
strategy: g4                              # → name gemma-4-31b-it-g4-vllm
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base
  image: docker.io/vllm/vllm-openai:v0.32.0   # newer vLLM than the overlay's v0.31.0 (vLLM containers only)
  tensorParallel: 1                       # whole model on the one GPU
  replicas: 5                             # = nodes × GPUs per node (5 × 1)
  args:
    - --max-model-len=32768               # ~24 GB left for KV cache after BF16 weights; check the startup log
    # - --quantization=fp8                # optional: weights ~31 GB → ~55 GB for KV cache
router:
  values:
    - guides/optimized-baseline/router/optimized-baseline.values.yaml
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
```

Steps:
1. Save it as `profiles/gemma-4-31b-g4-agentgateway.yaml`.
2. **Keep the pods on the G4 pool.** The `base` overlay has no node selector or GPU toleration. Add a patch file and list it in `modelserver.patches`:

   ```yaml
   # file: models/gemma-g4/patch.yaml  →  modelserver.patches: [models/gemma-g4/patch.yaml]
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: optimized-baseline-nvidia-gpu-vllm-decode   # upstream name (renaming happens after patches)
   spec:
     template:
       spec:
         nodeSelector:
           cloud.google.com/gke-nodepool: <g4-pool>
         tolerations:
           - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
   ```

   Find the upstream Deployment name with `kubectl kustomize .cache/llm-d-<sha>/guides/optimized-baseline/modelserver/gpu/vllm/base | yq 'select(.kind=="Deployment").metadata.name'`.
3. `--dry-run`, `./test.sh`, deploy.
4. Read `GPU KV cache size: N tokens` in each pod's log. If `--max-model-len` does not fit, vLLM refuses to start: lower it or add `--quantization=fp8`.

Air-gapped: a new `image` must be bundled first (`./bundle.sh profiles/gemma-4-31b-g4-agentgateway.yaml`), or the render stops with `image ... is not in .cache/images.lock`.

## 5. Pin the llm-d and vLLM versions

Pinning "llm-d 1.0" means pinning three things, because each has its own default:

| Piece | Profile key | Value | Default otherwise |
| --- | --- | --- | --- |
| guides (overlays, router values) | `llmdRef` | `378b42d…`, the commit of tag `v1.0.0` | the pipeline's `LLMD_REF` |
| router chart | `router.chartVersion` | `v1.0.0` | `v0`, a moving tag |
| EPP image | `router.set: [router.epp.image.tag=v1.0.0]` | `v1.0.0` | `:main`, even in the v1.0.0 chart |
| vLLM | `modelserver.image` | `vllm-openai:v0.34.0` | the overlay's image (llm-d 1.0 ships v0.31.0) |

Gemma 4 31B on llm-d 1.0 with vLLM v0.34.0, sized for the pool from [4](#4-one-gpu-per-node-5--g4-standard-48):

```yaml
# profile: profiles/gemma-4-31b-llmd-1.0-vllm-0.34-agentgateway.yaml
model: google/gemma-4-31B-it
strategy: llmd1                           # -> name gemma-4-31b-it-llmd1-vllm
llmdRef: 378b42d18dabe0b9c4ced4e6f3670d93b52db08e   # llm-d/llm-d tag v1.0.0
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base
  image: docker.io/vllm/vllm-openai:v0.34.0
  tensorParallel: 1                       # BF16 weights ~62.5 GB fit on the 96 GB GPU
  replicas: 5                             # nodes x GPUs per node / tensorParallel = 5 x 1 / 1
  args:
    - --max-model-len=32768               # ~24 GB left for KV cache; check "GPU KV cache size" in the log
    # - --quantization=fp8                # optional: weights ~31 GB -> ~55 GB for KV cache
router:
  chartVersion: v1.0.0
  values:
    - guides/optimized-baseline/router/optimized-baseline.values.yaml
  set:
    - router.epp.image.tag=v1.0.0
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
```

Steps:
1. `./deploy.sh profiles/gemma-4-31b-llmd-1.0-vllm-0.34-agentgateway.yaml --dry-run`. The first render fetches the v1.0.0 guides into `.cache/llm-d-378b42d…/`, next to the default ref, and the v1.0.0 chart into `.cache/charts/`.
2. Check the pins: `grep -h 'image:' .build/gemma-4-31b-it-llmd1-vllm/*.yaml | sort -u` shows `vllm-openai:v0.34.0` and `endpoint-picker:v1.0.0`.
3. Air-gapped: `./bundle.sh -e prod profiles/gemma-4-31b-llmd-1.0-vllm-0.34-agentgateway.yaml` and mirror the new rows. Profiles on different llm-d versions coexist in one bundle.
4. Deploy.

To move a pinned profile to a new llm-d release later, change all three pins together, then `./test.sh` and `docs/check-guide.sh`.
