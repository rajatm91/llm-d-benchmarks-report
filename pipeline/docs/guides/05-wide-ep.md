# 05. Wide expert parallelism

Large mixture-of-experts models (DeepSeek, GLM, Kimi) spread their experts across many GPUs and nodes: data parallel attention plus expert parallel MoE layers, with all-to-all communication (DeepEP) between ranks. In llm-d, wide-EP is always disaggregated: one `DisaggregatedSet` whose prefill and decode roles each span several nodes (leader + workers, via LWS). The `InferencePool` targets every DP rank's port (8000–8007), so each rank is a router endpoint.

Prerequisites: [prerequisites.md](../prerequisites.md), **LWS with `enableDisaggregatedSet=true`**, and a **full-mesh RDMA fabric** (InfiniBand or GPUDirect-RDMA; rail-only topologies fail). Each node's local SSD must hold the model.

- [1. DeepSeek-R1 on the wide-EP guide](#1-deepseek-r1-on-the-wide-ep-guide)
- [2. GLM-5.2: wide-EP, P/D and tiered KV (upstream recipe)](#2-glm-52-wide-ep-pd-and-tiered-kv-upstream-recipe)
- [3. Verify](#3-verify)
- [4. Changing the shape](#4-changing-the-shape)

## 1. DeepSeek-R1 on the wide-EP guide

32 × H200 over 4 nodes: prefill DP16/EP16 + decode DP16/EP16.

**Step 1. Check the weights** (~700 GB; every node caches them once):

```bash
gcloud storage ls gs://models_registry/deepseek_ai__deepseek_r1_0528/config.json
```

**Step 2. The profile.** Wide-EP needs two router values files: the guide's config and its GPU overrides.

```yaml
# profile: profiles/wide-ep-gke.yaml
model: deepseek-ai/DeepSeek-R1-0528
strategy: wide-ep
modelserver:
  overlay: guides/wide-ep/modelserver/gpu/vllm/gke
router:
  values:
    - guides/wide-ep/router/wide-ep.values.yaml
    - guides/wide-ep/router/gpu.values.yaml
gateway:
  provider: gke
  name: llm-d-inference-gateway
  namespace: gateway-infra
```

**Step 3. Render, check, deploy.**

```bash
./deploy.sh -e prod profiles/wide-ep-gke.yaml --dry-run
yq 'select(.kind=="InferencePool") | .spec.targetPorts' .build/deepseek-r1-0528-wide-ep-vllm/router.yaml   # 8000..8007
./test.sh
./deploy.sh -e prod profiles/wide-ep-gke.yaml
```

The first start downloads ~700 GB per node in parallel; set `waitTimeout: 120m` in the profile if 60 minutes is not enough.

## 2. GLM-5.2: wide-EP, P/D and tiered KV (upstream recipe)

When llm-d ships a recipe for your model under `guides/models/`, use it: it composes wide-EP, P/D, KV offload (CPU + local NVMe) and MTP, tuned for that model. The pipeline only adds naming, weights and images.

GLM-5.2-FP8, shape `p3w2d1w2`: 3 prefill + 1 decode DEP16 groups, 8 nodes / 64 H200, InfiniBand.

```yaml
# profile: profiles/wide-ep-pd-tiered-glm-agentgateway.yaml
model: zai-org/GLM-5.2-FP8                 # 8 nodes / 64 H200, InfiniBand
strategy: wide-ep-pd-tiered
modelserver:
  overlay: guides/models/glm-5-2/modelserver/gpu/vllm/deployments/default
  kvCache:                                 # per DP rank: sizes the router's GPU+CPU prefix index
    gpuTokens: 236800
    bytesPerToken: 61464
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

| Line | Why |
| --- | --- |
| `overlay: .../deployments/default` | Upstream's default shape. Other shapes: `deployments/p<N>w<N>d<N>w<N>` ([configuration §5](../configuration.md#5-catalog-model-server-overlays)). |
| `kvCache` | **Per DP rank**, since each rank is a router endpoint. Replace with the deploy's `kvCache` line for a prefill pod. |
| no `draftModel` | GLM-5.2's overlay already runs MTP; a draft model is rejected. |

Steps are the same as [1](#1-deepseek-r1-on-the-wide-ep-guide): check weights (`gs://models_registry/zai_org__glm_5_2_fp8`), `--dry-run`, `./test.sh`, deploy.

## 3. Verify

```bash
N=$(./deploy.sh profiles/<profile>.yaml --name)
kubectl get pods -n llm-d -l llm-d.ai/deployment=$N -L llm-d.ai/role -o wide          # leaders + workers per group
kubectl logs -n llm-d <prefill-leader-pod> -c modelserver --tail=-1 | grep -iE 'deepep|KV cache size|error' | head
```

Every DP rank logs its own `GPU KV cache size`. `./deploy.sh <profile> --kv-cache` takes the smallest as `gpuTokens`.

## 4. Changing the shape

`tensorParallel` and `replicas` do not apply. To change DP/EP size, node count or group counts:
- prefer an upstream shape (`guides/models/<model>/.../deployments/...`) when one fits;
- otherwise patch the `DisaggregatedSet` roles (size, `--data-parallel-size`, resources) with `modelserver.patches`, plus `disaggregatedset-schema` ([guide 04 §5](04-pd-disaggregation.md#5-change-what-the-overlay-hard-codes)).

Wide-EP routing has nothing hardware-specific to calibrate except where a prefix index is used ([fine-tuning.md](../fine-tuning.md)).
