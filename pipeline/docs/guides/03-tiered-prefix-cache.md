# 03. Tiered prefix cache: HBM → CPU RAM

When the prefixes your traffic reuses (system prompts, documents, long sessions) don't fit in GPU memory, vLLM evicts them and recomputes them later. The **tiered prefix cache** keeps evicted KV blocks in CPU RAM instead (vLLM's native `OffloadingConnector`), and the router keeps two prefix indexes, GPU and CPU, so requests still go to the pod that holds their prefix.

**You will deploy:** `Qwen/Qwen3-32B`, 2 replicas × TP=2, each with a 300 GiB CPU KV tier, behind a GKE Gateway.

Prerequisites: [prerequisites.md](../prerequisites.md) with a **GKE Gateway** ([§5](../prerequisites.md#5-a-gateway)) in `gateway-infra`, and nodes with at least ~350 GiB of free RAM per replica.

## 1. Decide whether you need it

Use it when vLLM's prefix-cache hit rate drops under load while requests clearly share prefixes, or when contexts are long and sessions many. Check before and after with vLLM's `vllm:prefix_cache_hits` / `vllm:prefix_cache_queries` metrics. If everything fits in HBM, the baseline ([guide 01](01-first-deployment.md)) is simpler.

## 2. The profile

```yaml
# profile: profiles/tiered-cpu-gke.yaml
model: Qwen/Qwen3-32B
strategy: tiered-cpu
modelserver:
  overlay: guides/tiered-prefix-cache/modelserver/gpu/vllm/native/cpu/gke    # 300 GiB CPU tier per replica
  kvCache:
    bytesPerToken: 262144                  # Qwen3-32B KV per token: sizes the router's CPU prefix index
router:
  values:
    - guides/tiered-prefix-cache/router/single-host/tiered-prefix-cache-cpu.values.yaml
gateway:
  provider: gke                            # GKE Gateway → HealthCheckPolicy rendered
  name: llm-d-inference-gateway
  namespace: gateway-infra
```

| Line | Why |
| --- | --- |
| `overlay: .../native/cpu/gke` | vLLM native offloading to CPU, GKE node settings. `lmcache-connector/...` and `.../fs/...` (shared filesystem tier) are alternatives ([configuration §5](../configuration.md#5-catalog-model-server-overlays)). |
| `kvCache.bytesPerToken` | The router's CPU index has a fixed size (`autoTune: false`), because vLLM doesn't report the CPU tier. The render computes it as CPU tier bytes ÷ (64 × bytes per token): 300 GiB ÷ (64 × 262144) = 19200 blocks. |
| `provider: gke` | Renders the `HealthCheckPolicy` and `GCPBackendPolicy`. Without them, every request is a 503. |

For Qwen3-32B, `bytesPerToken` = 64 layers × 8 KV heads × 128 head dim × 2 (K, V) × 2 bytes = 262144. For another model, take it from the deploy's `kvCache` line ([step 5](#5-deploy-and-size-the-index)).

## 3. Render and check

```bash
./deploy.sh -e prod profiles/tiered-cpu-gke.yaml --dry-run
B=.build/qwen3-32b-tiered-cpu-vllm
grep -o 'OffloadingConnector[^"]*' $B/modelserver.yaml | head -1        # the connector
grep -o 'cpu_bytes_to_use[^,}]*' $B/modelserver.yaml | head -1          # the tier size
grep -n 'lruCapacityPerServer' $B/router.yaml                           # 19200 for the CPU index
./test.sh
```

The render log also prints the computed size: `prefix index capacity: cpu-prefix-cache-producer lruCapacityPerServer=19200 (GPU 0 + CPU 19200 blocks of 64 tokens)`.

## 4. Change the tier size (optional)

The CPU tier lives in `/dev/shm`. Three values move together: the tier size (`cpu_bytes_to_use`), the shm volume `sizeLimit`, and the pod memory request/limit. Change them with a patch ([configuration §9](../configuration.md#9-what-has-no-knob-and-how-to-do-it-anyway)); the router index follows automatically from `cpu_bytes_to_use` and `kvCache.bytesPerToken`.

## 5. Deploy and size the index

```bash
./deploy.sh -e prod profiles/tiered-cpu-gke.yaml
```

The run ends with one line per pod:

```
qwen3-32b-tiered-cpu-vllm-xxxx: kvCache: {gpuTokens: <N>, bytesPerToken: <B>}
```

If `bytesPerToken` differs from the profile, copy it in and redeploy. `./deploy.sh -e prod profiles/tiered-cpu-gke.yaml --kv-cache` prints it again later.

## 6. Verify

```bash
N=qwen3-32b-tiered-cpu-vllm
kubectl logs -n llm-d -l llm-d.ai/deployment=$N -c modelserver --tail=-1 | grep -iE 'offload|KV cache size' | head
IP=$(kubectl get gateway llm-d-inference-gateway -n gateway-infra -o jsonpath='{.status.addresses[0].value}')   # internal: call from the VPC
curl -s http://$IP/v1/completions -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-32B", "prompt": "Say hello.", "max_tokens": 16}'
```

Under real traffic, compare `vllm:prefix_cache_hits` with the baseline. Before production, calibrate the router: [fine-tuning.md](../fine-tuning.md).
