# 04. Prefill/decode disaggregation

Prefill (processing the prompt) is compute-bound; decode (generating tokens) is memory-bandwidth-bound. **P/D disaggregation** runs them in separate pods so each can be sized and tuned on its own: TTFT depends on prefill, ITL on decode. The KV cache moves from prefill to decode over NIXL (RDMA when available). The router runs two scheduling profiles: it picks a prefill pod and a decode pod per request.

This guide deploys plain P/D, then adds a CPU KV tier on prefill (a combination of two llm-d guides), then changes what the overlay hard-codes.

Prerequisites: [prerequisites.md](../prerequisites.md), **LWS with `enableDisaggregatedSet=true`** ([§6](../prerequisites.md#6-leaderworkerset-pd-and-wide-ep-only)), and RDMA between GPU nodes for the `gke` overlay. No RDMA? See [guide 07](07-gemma-pd-tiered-g4.md).

- [1. When P/D pays off](#1-when-pd-pays-off)
- [2. Plain P/D](#2-plain-pd)
- [3. Verify the split](#3-verify-the-split)
- [4. P/D + CPU tier on prefill (combo)](#4-pd--cpu-tier-on-prefill-combo)
- [5. Change what the overlay hard-codes](#5-change-what-the-overlay-hard-codes)

## 1. When P/D pays off

- Long prompts with short answers (RAG, summarization, agent tool results).
- You need to hold an ITL target while prompt sizes vary.
- You have RDMA. Over TCP, cross-node KV transfers can cost more than they save; benchmark against aggregated replicas.

## 2. Plain P/D

**Step 1. The profile.** gpt-oss-120b, 1 prefill pod (TP=1) + 1 decode pod (TP=4) on H200:

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

The `gke` overlay requests GPUs and RDMA NICs through DRA (A3 Ultra / A4 machines). The `base` overlay uses plain `nvidia.com/gpu` but ships no image: add the `guides/recipes/modelserver/components/images/gpu-vllm/release` component.

**Step 2. Render and check.**

```bash
./deploy.sh -e prod profiles/pd-gke.yaml --dry-run
B=.build/gpt-oss-120b-pd-vllm/modelserver.yaml
yq 'select(.kind=="DisaggregatedSet") | .spec.roles[].name' $B                       # prefill, decode
yq 'select(.kind=="DisaggregatedSet") | .spec.roles[] | .name + ": " +
  ([.spec.leaderWorkerTemplate.workerTemplate.spec.containers[] | select(.name=="modelserver") | .args[]
    | select(test("tensor-parallel|kv-transfer"))] | join(" "))' $B
./test.sh
```

**Step 3. Deploy.** Preflight stops if LWS or the `DisaggregatedSet` CRD is missing.

```bash
./deploy.sh -e prod profiles/pd-gke.yaml
```

Keep the EPP at 1 replica: P/D load accounting is per process.

## 3. Verify the split

```bash
N=gpt-oss-120b-pd-vllm
kubectl get pods -n llm-d -l llm-d.ai/deployment=$N -L llm-d.ai/role -o wide
kubectl logs -n llm-d -l llm-d.ai/deployment=$N,llm-d.ai/role=decode -c modelserver --tail=-1 | grep -iE 'nixl|KV cache size' | head
```

Decode pods also run a `routing-proxy` sidecar: it receives the request, asks the chosen prefill pod to compute the KV cache, and pulls it over NIXL.

## 4. P/D + CPU tier on prefill (combo)

Prefix reuse happens on prefill, so that is where a CPU tier helps. Two llm-d guides are combined:

| Half | How | File |
| --- | --- | --- |
| Engine | Prefill's KV connector becomes a `MultiConnector`: NIXL (producer, for decode) + `OffloadingConnector` (100 GiB CPU tier). shm and memory are raised to match. Decode is unchanged. | `combos/pd-tiered-cpu/kustomization.yaml` |
| Router | **One** merged plugin config: the P/D profiles plus a prefix index sized for GPU + CPU blocks. Layering the two guides' values files would keep only the last one ([concepts §8](../concepts.md#8-combining-strategies)). | `combos/pd-tiered-cpu/router.values.yaml` |

**Step 1. The profile.**

```yaml
# profile: profiles/pd-tiered-cpu-agentgateway.yaml
model: openai/gpt-oss-120b
strategy: pd-tiered-cpu
modelserver:
  overlay: guides/pd-disaggregation/modelserver/gpu/vllm/gke
  components:
    - guides/recipes/modelserver/components/disaggregatedset-schema   # must come first: patch by name, not index
    - combos/pd-tiered-cpu                 # prefill: NIXL producer + CPU OffloadingConnector, 100 GiB
  kvCache:                                 # sizes the router's GPU+CPU prefix index (startup log values)
    gpuTokens: 832000
    bytesPerToken: 73728
router:
  values:
    - guides/pd-disaggregation/router/pd-disaggregation.values.yaml
    - combos/pd-tiered-cpu/router.values.yaml    # ONE merged plugin graph: P/D profiles + GPU+CPU prefix index
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
```

Order matters in `components`: `disaggregatedset-schema` first, so the combo's strategic-merge patches match roles and containers by name.

**Step 2. Render and check.**

```bash
./deploy.sh -e prod profiles/pd-tiered-cpu-agentgateway.yaml --dry-run 2>&1 | grep 'prefix index capacity'
B=.build/gpt-oss-120b-pd-tiered-cpu-vllm/modelserver.yaml
yq 'select(.kind=="DisaggregatedSet") | .spec.roles[] | .name + ": " +
  ([.spec.leaderWorkerTemplate.workerTemplate.spec.containers[] | select(.name=="modelserver") | .args[]
    | select(test("Offloading"))] | length | tostring)' $B          # prefill: 1, decode: 0
./test.sh
```

**Step 3. Deploy, then replace the estimates.** `kvCache` holds estimates. After the deploy, copy the **prefill** pod's `kvCache: {...}` line into the profile and redeploy; the render recomputes `lruCapacityPerServer`. `peakPrefillThroughput` in the combo is a gpt-oss/H200 value: calibrate it for anything else ([fine-tuning.md](../fine-tuning.md)).

**Resizing the tier.** Tier size (`cpu_bytes_to_use` 100 GiB), shm `sizeLimit` (110Gi) and pod memory (140Gi) change together, in a copy of the combo.

## 5. Change what the overlay hard-codes

P/D overlays fix GPU counts, memory and placement per role, and `tensorParallel` / `replicas` don't apply. Use a kustomize patch. This one raises decode memory:

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

Steps:
1. Save it under this repo (e.g. `models/gpt-oss-pd-bigger-decode/patch.yaml`).
2. In the profile, list the patch and the schema component:
   ```
   modelserver:
     components: [guides/recipes/modelserver/components/disaggregatedset-schema]
     patches: [models/gpt-oss-pd-bigger-decode/patch.yaml]
   ```
3. `--dry-run` and check the field in `.build/<name>/modelserver.yaml`.

Without `disaggregatedset-schema`, a strategic-merge patch replaces the whole `roles` list instead of merging into `decode`.

To change TP or GPU count per role, patch the role's `--tensor-parallel-size` arg and `nvidia.com/gpu` requests together. Args are a plain list, so use a JSON patch by index, guarded with `test` ops so an upstream reorder fails the render: `combos/g4-pd-sizing/kustomization.yaml` is a complete example ([guide 07](07-gemma-pd-tiered-g4.md)).
