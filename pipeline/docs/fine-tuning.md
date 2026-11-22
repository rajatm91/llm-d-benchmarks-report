# Fine-tuning llm-d deployments

The llm-d guide a profile is built on (its deployment strategy) decides **which** router (EPP) settings must be tuned; the model and accelerator decide their **values**. Most values shipped in llm-d come from H100/H200 runs, and the reference matrix has no RTX PRO 6000 row, so a new (model, accelerator) pair needs a one-off tuning pass after its first deploy. No pipeline module is needed for that.

Checked against llm-d `main` at commit `234d1c7` (21 Nov 2026). Both refs the pipeline pins (`LLMD_REF` in `lib/profile.sh` and the v1.0.0 `llmdRef`) ship the calibration scripts.

## What to tune, by llm-d guide

| llm-d guide | `peakPrefillThroughput` (`calibrate.sh`) | `lruCapacityPerServer` (formula) | Other settings |
| --- | --- | --- | --- |
| `optimized-baseline` | Yes, through the EPP | Only where `autoTune: false` | — |
| `pd-disaggregation` | Yes, against a **prefill pod** | Only where `autoTune: false` (e.g. `combos/pd-tiered-cpu`) | — |
| `tiered-prefix-cache` | No | **Always**: vLLM does not report CPU-tier size | Recompute when tier size or model changes |
| `precise-prefix-cache-routing` | Yes | No: index fed by vLLM KV events | `blockSizeTokens` = vLLM `--block-size` |
| `coord-disaggregation` | Yes | No (`autoTune: true`) | Three EPPs; not supported by the pipeline |
| `multimodal-serving` | Yes | — | — |
| `predicted-latency-routing` | Not needed: xgboost sidecars learn TTFT/TPOT online | — | Retraining interval, SLO headroom. P/D variant: `predicted-latency-pd.values.yaml` |
| `p2p-kv-cache-sharing` | — | — | `minCachedTokenDelta` (`calibrate-min-cached-token-delta.sh`), per transport |
| `flow-control`, `turn-priority-fairness` | — | — | `concurrency-detector.maxConcurrency` (ships `132`): per-pod saturation point; benchmark it |
| `wide-ep` | — | — | Nothing hardware-specific (queue / active-request scorers) |
| `workload-autoscaling` | Token-aware mode reuses the calibrated value | — | Scaling thresholds, from benchmarks |

Rules that hold for any model:

1. `peakPrefillThroughput` depends on **model × accelerator × TP × chunk size** (`--max-num-batched-tokens`). Reuse a value from [`configuration-matrix.md`](https://github.com/llm-d/llm-d/blob/main/guides/recipes/router/calibration/configuration-matrix.md) only if all four match; otherwise run `calibrate.sh`.
2. `lruCapacityPerServer` depends only on KV bytes per token and the GPU/CPU KV capacity. The pipeline computes it at render (so `deploy.sh` and `bundle.sh` both get it) from `modelserver.kvCache` in the profile; see below.
3. Settings with no script (`maxConcurrency`, scorer `weight:` values, autoscaling thresholds) are tuned with this repo's benchmarks.
4. Put tuned values in a profile-specific router values file, never in a shared `combos/*` file or the upstream guide file.

## How calibration works

`calibrate.sh` measures one number and prints it; it changes no config. The `prefix-cache-affinity-filter` uses `peakPrefillThroughput` to turn a pod's in-flight token load into a predicted TTFT, which decides whether a request stays sticky to its prefix-cache pod.

1. The script starts a Job (`calibration-peak-throughput.yaml`) whose ConfigMap holds a Python measurer.
2. The Job streams `/v1/completions` requests of exactly `CHUNK_SIZE` random token IDs, so every request misses the prefix cache.
3. It sends `NUM_WARMUP` (5) warmup requests, then `NUM_MEASUREMENTS` (20) timed ones, recording time to first chunk.
4. It prints `peakPrefillThroughput = CHUNK_SIZE / median(TTFT)` in tokens/s.

| Env var | Default | Notes |
| --- | --- | --- |
| `GUIDE_NAME` | `optimized-baseline` | Release name; used to find `<name>-epp` |
| `NAMESPACE` | `default` | |
| `MODEL_NAME` | `Qwen/Qwen3-32B` | Served model id |
| `CHUNK_SIZE` | `8192` | Must equal vLLM `--max-num-batched-tokens` |
| `VLLM_ENDPOINT` | EPP service | Set it to target a pod directly |
| `NUM_WARMUP` / `NUM_MEASUREMENTS` | `5` / `20` | |
| `T_MAX_SECONDS` | `18` | Feeds an informational `TAU` line only |

The script needs `kubectl` and `envsubst` on `PATH`. To apply the value, set it under the `prefix-cache-affinity-filter` parameters in the router values, redeploy, and restart the EPP (`kubectl rollout restart deployment/<name>-epp`).

**Finding `CHUNK_SIZE`.** vLLM prints it at engine start-up (e.g. `Chunked prefill is enabled with max_num_batched_tokens=8192`):

```bash
kubectl logs <prefill-pod> -n <namespace> | grep -i max_num_batched_tokens
```

If the profile does not set `--max-num-batched-tokens`, vLLM's API server picks a default by GPU memory: 8192 on cards with 70 GiB or more (RTX PRO 6000 has 96 GB), 2048 on smaller ones.

## Sizing lruCapacityPerServer (computed by the pipeline)

`lruCapacityPerServer` is the number of router blocks (`blockSizeTokens`, 64) the prefix index assumes each endpoint holds. A producer with `autoTune: true` sizes itself from vLLM's GPU blocks; a producer with `autoTune: false` (needed whenever it must count a CPU tier, which vLLM does not report) gets a fixed number. The values files ship that number for the model the guide was written for, so the render (`set_prefix_cache_capacity` in `lib/render.sh`) **replaces it** for every `autoTune: false` producer:

```
lruCapacityPerServer = gpuTokens / 64                       (only if no autoTune producer already indexes the GPU)
                     + cpu_bytes_to_use / (64 × bytesPerToken)
```

| Input | Where it comes from |
| --- | --- |
| `modelserver.kvCache.gpuTokens` | Profile. vLLM startup line `GPU KV cache size: N tokens`, per router endpoint (per DP rank on wide-EP). Used when the fixed index covers the GPU tier (`combos/pd-tiered-cpu`, GLM-5.2). |
| `modelserver.kvCache.bytesPerToken` | Profile. KV bytes per token for the whole model, all TP ranks: `Available KV cache memory` × TP / `GPU KV cache size`, or from `config.json`: 2 (K,V) × layers × KV heads × head dim × dtype bytes. Used when there is a CPU tier. |
| CPU tier bytes | Read from the model-server render: the largest `cpu_bytes_to_use` in the vLLM kv-transfer config, literal or `${VAR:-default}` (the `VAR` env value wins). |

You don't have to work these out. Every deploy ends by reading them from each model-server pod's vLLM startup log, and `./deploy.sh <profile> --kv-cache` does the same for a running deployment:

```
<prefill-pod>: kvCache: {gpuTokens: <N>, bytesPerToken: <B>}
```

`gpuTokens` is the smallest `GPU KV cache size` line (one per engine, i.e. per DP rank); `bytesPerToken` is the sum of every rank's `Available KV cache memory` over the sum of those sizes, so TP and DP need no input. On P/D, copy the prefill pod's line. Until the profile sets them, the render logs a `WARNING: modelserver.kvCache.{...} not set` and keeps the values file's number, so a first deploy of a new model works without them. The log line shows what was set, e.g. `approx-prefix-cache-producer lruCapacityPerServer=35755 (GPU 13000 + CPU 22755 blocks of 64 tokens)`.

- Too high a value shows as `llm_d_epp_prefix_indexer_hit_ratio` well above vLLM's own prefix hit rate: the router steers to blocks pods no longer hold. Lower `gpuTokens` or raise `bytesPerToken`.
- P/D: only prefill has a CPU tier, and the index is shared by all endpoints, so the prefill value is used for decode too (as upstream does).
- Hybrid-attention models (Gemma 4: sliding-window layers) store less per token than the full-layer formula; prefer the log-derived `bytesPerToken`.

## Runbook: tuning a new profile

Run once per new (model, accelerator, strategy), after the profile is deployed and serving. Worked example: `gemma-4-31b-pd-tiered-g4-gke` (Gemma 4 31B, 3 × g4-standard-96 with RTX PRO 6000, TP=1, CPU tier on prefill), which inherits `peakPrefillThroughput: 33821` (gpt-oss-120b on H200) from `combos/pd-tiered-cpu`; its `modelserver.kvCache` holds estimates from `config.json` until replaced with log values.

1. Find the profile's guide in the table above; that row is the list of settings to tune.
2. Deploy with the borrowed values and confirm the smoke request passes.
3. Copy the `kvCache: {...}` line the deploy printed (or `./deploy.sh <profile> --kv-cache`) for a prefill pod, and note `max_num_batched_tokens` from its startup log.
4. Calibrate. On P/D, target a prefill pod directly: through the EPP, TTFT would include the decode hop and the NIXL KV hand-off.

   ```bash
   GUIDE_NAME=gemma-4-31b-it-pd-tiered-g4-vllm \
   NAMESPACE=<namespace> \
   MODEL_NAME=google/gemma-4-31B-it \
   CHUNK_SIZE=<max_num_batched_tokens from step 3> \
   VLLM_ENDPOINT=http://<prefill-pod-ip>:<port> \
   .cache/llm-d-<LLMD_REF>/guides/recipes/router/calibration/calibrate.sh
   ```

5. Paste that `kvCache` into the profile's `modelserver`. The render recomputes `lruCapacityPerServer`.
6. For `peakPrefillThroughput`, copy `combos/pd-tiered-cpu/router.values.yaml` to a profile-specific file (e.g. `combos/gemma-4-31b-g4/router.values.yaml`), set the measured value there, and point the profile's `router.values` at it instead of the combo.
7. Redeploy (`./deploy.sh`, or `./bundle.sh` for air-gapped) and restart the EPP.
8. Record the value with its model, accelerator, TP and chunk size in the profile comment, so the next profile on the same hardware has a reference point.

## Caveats

- **Wide-EP / DP ranks.** A single calibration request exercises one rank. llm-d's GLM-5.2 guide ships a per-rank value (3585, 2048-token chunk); its DeepSeek-V4 guide multiplies per-rank by the ranks behind one endpoint. Check how endpoints map to ranks before scaling.
- **CPU-tier restores** are slower than HBM hits; calibration measures cold prefill only and does not capture that.
- **Predicted-latency routing** replaces the static `peakPrefillThroughput` with online-trained models. It assumes a homogeneous pool and adds about 10 vCPU and 8 GiB to the router pod.

## Sources

- [Router calibration README](https://github.com/llm-d/llm-d/blob/main/guides/recipes/router/calibration/README.md)
- [Calibration configuration matrix](https://github.com/llm-d/llm-d/blob/main/guides/recipes/router/calibration/configuration-matrix.md)
- [Tiered prefix cache guide](https://github.com/llm-d/llm-d/blob/main/guides/tiered-prefix-cache/README.md)
- [Predicted-latency routing guide](https://github.com/llm-d/llm-d/blob/main/guides/predicted-latency-routing/README.md)
- [Flow control guide](https://github.com/llm-d/llm-d/blob/main/guides/flow-control/README.md)
- [Workload autoscaling guide](https://github.com/llm-d/llm-d/blob/main/guides/workload-autoscaling/README.md)
