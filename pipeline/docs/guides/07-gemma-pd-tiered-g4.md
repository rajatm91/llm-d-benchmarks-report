# 07. Gemma 4 31B with P/D + tiered KV cache on G4 (3 × g4-standard-96)

This guide deploys `google/gemma-4-31B-it` with **prefill/decode disaggregation** and a **CPU KV tier on prefill** on a GKE pool of 3 × `g4-standard-96` (2 × NVIDIA RTX PRO 6000, 96 GB each, per node). G4 has no RDMA NICs, so this is also the reference for running P/D on any non-RDMA GPU pool. The files are in the repo: `profiles/gemma-4-31b-pd-tiered-g4-gke.yaml` and `combos/g4-pd-sizing/`, checked by `test.sh` (`pd-g4`). It builds on [guide 04](04-pd-disaggregation.md).

| Step | What |
| --- | --- |
| [0. Layout and why](#0-layout-and-why) | read once |
| [1. Check the cluster](#1-check-the-cluster) | once per cluster |
| [2. Read the files](#2-read-the-files) | once |
| [3. Validate offline](#3-validate-offline) | every change |
| [4. Bundle the images](#4-bundle-the-images-connected-machine) | once, and on image changes |
| [5. Deploy and verify](#5-deploy-and-verify) | every change |
| [6. Tune](#6-tune-before-production) | before production |
| [7. Troubleshooting](#7-troubleshooting) | when something breaks |

---

## 0. Layout and why

```
node 1: [GPU0 prefill TP=1 + 100 GiB CPU tier] [GPU1 decode TP=1]   ← slice 1
node 2: [GPU0 prefill TP=1 + 100 GiB CPU tier] [GPU1 decode TP=1]   ← slice 2
node 3: [GPU0 prefill TP=1 + 100 GiB CPU tier] [GPU1 decode TP=1]   ← slice 3
          KV: prefill → decode over NIXL (CUDA IPC on the same node, TCP across nodes)
```

| Decision | Reason |
| --- | --- |
| Overlay `pd-disaggregation/.../vllm/base`, **not** `.../gke` | The `gke` overlay asks DRA for one GPU **plus one `mrdma.google.com` RDMA NIC** per rank (A3 Ultra / A4). G4 has no such NICs, so every pod would stay `Pending`. `base` uses plain `nvidia.com/gpu`. |
| Decode TP=1, 1 GPU | Upstream decode is TP=4 (4 GPUs). A G4-96 node has 2. Gemma 4 31B in BF16 (~62.5 GB) fits on one 96 GB GPU. |
| 3 slices, `ExclusiveSlice` on `kubernetes.io/hostname` | One prefill + one decode per node. Prefill pods request 140Gi RAM (CPU tier); this keeps two of them from landing on the same node. |
| Decode `maxSurge: 0` | All 6 GPUs are in use; upstream's `maxSurge: 1` would wait for a 7th. A slice's decode is briefly down during a rollout. |
| `--max-model-len=65536` | vLLM v0.34.0 measured 25.77 GiB / 183,793 tokens of KV cache per GPU after the weights: 2.8 full-length requests per pod. Gemma's default context would not fit. |
| NIXL over TCP | No RDMA on G4. Works, but transfers across nodes are slower; the router may pair any prefill with any decode. |

Per node the pods request 2 GPUs, 24 vCPU and 204Gi RAM (prefill 140Gi + decode 64Gi), well inside a `g4-standard-96`.

> **Is P/D worth it here?** P/D pays off mostly on long prompts. With 6 GPUs and TCP transfers, 6 aggregated replicas with the CPU tier ([guide 03](03-tiered-prefix-cache.md)) may do better. Benchmark both before you commit to one.

---

## 1. Check the cluster

### 1.1 Prerequisites: CRDs

The render applies one `DisaggregatedSet`, one `InferencePool` and one `HTTPRoute` (plus a Deployment, Service, ConfigMap and RBAC for the EPP). These CRDs must exist before `deploy.sh` runs:

| CRD | API group | Comes from | Install |
| --- | --- | --- | --- |
| `leaderworkersets` | `leaderworkerset.x-k8s.io` | LWS ≥ v0.11.1 | [prerequisites §6](../prerequisites.md#6-leaderworkerset-pd-and-wide-ep-only) (`lws/crds`) |
| `disaggregatedsets` | `disaggregatedset.x-k8s.io` | LWS, only with `--set enableDisaggregatedSet=true` | same step |
| `inferencepools` | `inference.networking.k8s.io` (v1) | Gateway API Inference Extension | managed by GKE ≥ 1.34.0-gke.1626000 with Gateway API on; else `kubectl apply -f .cache/crds/inference-extension-v1.yaml` ([prerequisites §4](../prerequisites.md#4-gateway-api-and-inferencepool-crd)) |
| `gateways`, `httproutes`, `gatewayclasses` | `gateway.networking.k8s.io` (v1) | Gateway API | GKE with Gateway API enabled (`--gateway-api=standard`) |
| `healthcheckpolicies`, `gcpbackendpolicies` | `networking.gke.io` | GKE Gateway controller | same; the router renders one of each for `provider: gke` |

**Not needed:** the llm-d-router CRDs (`InferenceObjective`, `ROUTER_CRDS=1`, only for flow-control priorities), DRA / `resource.k8s.io` device classes and RDMA NIC drivers (only the `gke` RDMA overlay uses them).

### 1.2 Prerequisites: images

What the rendered manifests run, with the digests `bundle.sh` locked (`.cache/images.lock`, llm-d ref `565373b`). `deploy.sh` pins each to its digest, so the moving `:main` / `:slim` tags are safe:

| Image | Used by | Digest |
| --- | --- | --- |
| `docker.io/vllm/vllm-openai:v0.34.0` | prefill + decode `modelserver` | `sha256:20fdb089454afbb324efa4110a2c025ff7b27cc1a086e07aa580b18df8ad1ce1` |
| `ghcr.io/llm-d/llm-d-router-disagg-sidecar:main` | decode `routing-proxy` (P/D sidecar) | `sha256:c2c5bc442819f5e02e6bd0d03a95f11182bbbb65fb60e58aca87ba7baff8fe09` |
| `ghcr.io/llm-d/llm-d-router-endpoint-picker:main` | EPP (router) | `sha256:9be34ab3363517ed3b5c9ca368fb76cb1449228e3fee48c875a3942239653f0c` |
| `gcr.io/google.com/cloudsdktool/google-cloud-cli:slim` | `fetch-model` init (weights from GCS) | `sha256:6795669175125b3556f19ebd3ba4ff2d1ae01d51b72af920c4573c372a52ef2d` |
| `docker.io/curlimages/curl:8.11.1` | `deploy.sh` smoke test pod | `sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69` |

Re-running `bundle.sh` later can lock newer digests for `:main` / `:slim`; `.cache/images.lock` is the source of truth. Print the list for your bundle with:

```bash
./deploy.sh profiles/gemma-4-31b-pd-tiered-g4-gke.yaml --dry-run
for f in .build/gemma-4-31b-it-pd-tiered-g4-vllm/{modelserver,router}.yaml; do
  yq -N '.. | select(tag == "!!map" and has("image")) | .image' "$f"; done | sort -u
```

Air-gapped, LWS has one more image: `registry.k8s.io/lws/lws:v1.0.0`. `LWS_CHART=1 ./bundle.sh` locks it and bundles the chart; map `registry.k8s.io` in `IMAGE_REMOTES` (a remote repo with custom upstream `https://registry.k8s.io`) or copy it per the mirror list, then install with `./install-lws.sh` ([4](#4-bundle-the-images-connected-machine)). The GKE Gateway is Google-managed, nothing to mirror.

The model weights are not an image: `fetch-model` copies `gs://models_registry/google__gemma_4_31b_it/` (~63 GB) to each node's local SSD.

### 1.3 Check the cluster

Do the one-time setup in [prerequisites.md](../prerequisites.md) first: InferencePool CRD (§4), a **GKE Gateway** named `llm-d-gemma-gateway` in the deployment namespace (below; `gke-l7-rilb` needs a proxy-only subnet in the region), **LWS with `enableDisaggregatedSet=true` (§6)**, namespace + ServiceAccount + Workload Identity (§7). Then check:

```bash
kubectl config current-context                         # must be the G4 cluster, not kind
kubectl get nodes -l node.kubernetes.io/instance-type=g4-standard-96 \
  -o custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,MEM:.status.allocatable.memory,EPH:.status.allocatable.ephemeral-storage
kubectl get crd inferencepools.inference.networking.k8s.io leaderworkersets.leaderworkerset.x-k8s.io disaggregatedsets.disaggregatedset.x-k8s.io \
  gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
kubectl get gatewayclass gke-l7-rilb                   # or gke-l7-regional-external-managed
kubectl -n lws-system get deploy                       # LWS >= v0.11.1
kubectl -n <NAMESPACE> get gateway llm-d-gemma-gateway   # PROGRAMMED=True, has an ADDRESS
kubectl -n <NAMESPACE> get sa <SERVICE_ACCOUNT>
gcloud storage ls gs://models_registry/google__gemma_4_31b_it/ | head   # weights where the profile expects them
```

Expected: 3 nodes, `GPU` = 2 on each, ephemeral storage well above ~63 GB (weights are cached on local SSD once per node), all five CRDs and the GatewayClass present, Gateway programmed with an address.

**The Gateway.** The model gets its own Gateway, because its route is a catch-all (`/`) and two catch-alls on one Gateway conflict (the older wins, and `deploy.sh` stops with `Gateway already has catch-all "/" routes`). Create it once in the deployment namespace, with the same class as your other Gateways:

```yaml
# gemma-gateway.yaml  ->  kubectl apply -n <NAMESPACE> -f gemma-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llm-d-gemma-gateway
spec:
  gatewayClassName: gke-l7-rilb          # internal; gke-l7-regional-external-managed for external
  listeners:
    - name: default
      port: 80
      protocol: HTTP                     # same namespace as the route, so the default allowedRoutes is enough
```

```bash
kubectl -n <NAMESPACE> get gateway llm-d-gemma-gateway -w    # PROGRAMMED=True and an ADDRESS after a few minutes
```

To share a Gateway that already has a catch-all route instead, set `gateway.baseModel` and install IPP ([guide 06](06-multi-model-gateway.md)). Routes on specific paths (`/optimized-baseline`) do not conflict.

**ServiceAccounts.** Model-server pods run as `SERVICE_ACCOUNT`. The router chart also creates `<name>-epp` for its EPP; to reuse an existing account instead, set `ROUTER_SERVICE_ACCOUNT` in the env file (e.g. the same `SERVICE_ACCOUNT`). The chart's Roles and ClusterRole are then bound to that account.

---

## 2. Read the files

Both files are in the repo; this section explains them. Run everything from `pipeline/`.

### 2.1 Sizing component

```yaml
# file: combos/g4-pd-sizing/kustomization.yaml
# Sizes the P/D DisaggregatedSet for 3 x g4-standard-96 (2 x RTX PRO 6000 96 GB per node, no RDMA NICs).
# Layer on guides/pd-disaggregation/modelserver/gpu/vllm/base (NOT .../gke: that one asks DRA for
# mrdma.google.com NICs, which G4 does not have, so the pods would never schedule).
#
#   3 slices x (1 prefill TP=1 + 1 decode TP=1); ExclusiveSlice on hostname puts one slice per node,
#   so each node runs 1 prefill + 1 decode and the 140Gi prefill (CPU tier) pods never stack.
#   NIXL falls back to TCP between nodes; same-node pairs use CUDA IPC.
#   Decode rolls with maxSurge 0: all 6 GPUs are in use, there is no spare one to surge onto.
#
# Needs guides/recipes/modelserver/components/disaggregatedset-schema listed BEFORE this component.
# Args are patched by index; the `test` ops fail the render if upstream reorders them.
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  - target: {kind: DisaggregatedSet, name: pd-disagg-vllm}
    patch: |-
      - op: replace
        path: /spec/slices
        value: 3
      - op: add
        path: /spec/placementPolicy
        value: {type: ExclusiveSlice, topology: kubernetes.io/hostname}
      - op: test
        path: /spec/roles/1/name
        value: decode
      - op: test
        path: /spec/roles/1/spec/leaderWorkerTemplate/workerTemplate/spec/containers/0/args/2
        value: --tensor-parallel-size=4
      - op: replace
        path: /spec/roles/1/spec/leaderWorkerTemplate/workerTemplate/spec/containers/0/args/2
        value: --tensor-parallel-size=1
      - op: replace
        path: /spec/roles/1/spec/leaderWorkerTemplate/workerTemplate/spec/containers/0/resources/limits/nvidia.com~1gpu
        value: "1"
      - op: replace
        path: /spec/roles/1/spec/leaderWorkerTemplate/workerTemplate/spec/containers/0/resources/requests/nvidia.com~1gpu
        value: "1"
      - op: replace
        path: /spec/roles/1/spec/rolloutStrategy/rollingUpdateConfiguration
        value: {maxSurge: 0, maxUnavailable: 1}
  # GKE taints GPU nodes; the base overlay (unlike gke) carries no toleration.
  - patch: |-
      apiVersion: disaggregatedset.x-k8s.io/v1
      kind: DisaggregatedSet
      metadata:
        name: pd-disagg-vllm
      spec:
        roles:
          - name: prefill
            spec: &g4
              leaderWorkerTemplate:
                workerTemplate:
                  spec:
                    tolerations:
                      - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
          - name: decode
            spec: *g4
```

Prefill needs no sizing patch: upstream already runs it at TP=1 on 1 GPU. The CPU tier comes from the existing `combos/pd-tiered-cpu` (prefill: `MultiConnector` = NIXL producer + `OffloadingConnector` with 100 GiB, shm 110Gi, memory 140Gi).

### 2.2 Profile

```yaml
# profile: profiles/gemma-4-31b-pd-tiered-g4-gke.yaml
# Gemma 4 31B, P/D + CPU KV tier on prefill, on 3 x g4-standard-96 (2 x RTX PRO 6000 96 GB each).
# 3 x (1 prefill + 1 decode), TP=1 everywhere; KV moves over NIXL/TCP (G4 has no RDMA NICs).
# modelserver.kvCache (measured) sets the router's lruCapacityPerServer at render; peakPrefillThroughput
# calibrated: 5287 tok/s (combos/gemma-4-31b-g4/router.values.yaml).
model: google/gemma-4-31B-it
strategy: pd-tiered-g4                    # -> name gemma-4-31b-it-pd-tiered-g4-vllm
modelserver:
  overlay: guides/pd-disaggregation/modelserver/gpu/vllm/base
  image: docker.io/vllm/vllm-openai:v0.34.0
  args:
    - --max-model-len=65536               # KV cache holds 183,793 tokens (25.77 GiB) = 2.8 full-length requests
  components:
    - guides/recipes/modelserver/components/images/gpu-vllm/release   # base overlay ships no images
    - guides/recipes/modelserver/components/disaggregatedset-schema   # must come before the patches below
    - combos/pd-tiered-cpu                 # prefill: NIXL producer + CPU OffloadingConnector, 100 GiB
    - combos/g4-pd-sizing                  # decode TP=1, 3 slices one per node, GPU toleration
  kvCache:                               # sizes the router's GPU + CPU prefix index (docs/fine-tuning.md)
    # Measured 2026-11-22 from a prefill pod's vLLM v0.34.0 startup log (RTX PRO 6000, TP=1):
    gpuTokens: 183793                    # "GPU KV cache size: 183,793 tokens"
    bytesPerToken: 150551                 # "Available KV cache memory: 25.77 GiB" / 183793 (hybrid allocator;
                                         # the all-layers config.json formula gave 901120, 6x too high)
router:
  values:
    - guides/pd-disaggregation/router/pd-disaggregation.values.yaml
    - combos/gemma-4-31b-g4/router.values.yaml   # combo's values + calibrated peakPrefillThroughput (5287)
gateway:
  provider: gke                           # renders HealthCheckPolicy + GCPBackendPolicy (else every request 503s)
  name: llm-d-gemma-gateway               # its own Gateway: another model already owns "/" on llm-d-inference-gateway
  # no namespace: the Gateway lives in the deployment's NAMESPACE (env file), e.g. kserve-poc
  timeoutSec: 900                         # load balancer backend timeout (chart default 300s) for long generations
```

Order of `components` matters: the image component and `disaggregatedset-schema` first, then `pd-tiered-cpu` (patches prefill args by index), then `g4-pd-sizing`. Keep `gateway.provider: gke`: it makes the router render the `HealthCheckPolicy` and `GCPBackendPolicy` the GKE load balancer needs. To use agentgateway instead, set `provider: agentgateway`, `name: llm-d-inference-gateway` and `namespace: agentgateway-system` ([prerequisites §5](../prerequisites.md#5-a-gateway)).

### 2.3 Test

`test.sh` (the `pd-g4` checks) asserts what a cluster would otherwise reveal only at runtime: no RDMA DRA claims, 1 GPU and TP=1 on both roles, the CPU tier only on prefill, 3 slices placed one per node, and the GKE `HealthCheckPolicy` + `GCPBackendPolicy`.

---

## 3. Validate offline

```bash
./deploy.sh profiles/gemma-4-31b-pd-tiered-g4-gke.yaml --name      # gemma-4-31b-it-pd-tiered-g4-vllm
./deploy.sh profiles/gemma-4-31b-pd-tiered-g4-gke.yaml --dry-run
./test.sh                                                                     # ends with "all checks passed"
```

Look at what will be applied:

```bash
B=.build/gemma-4-31b-it-pd-tiered-g4-vllm/modelserver.yaml
yq -N 'select(.kind=="DisaggregatedSet") | .spec.slices, .spec.placementPolicy' $B
yq -N 'select(.kind=="DisaggregatedSet") | .spec.roles[] | .name + ": " +
  ([.spec.leaderWorkerTemplate.workerTemplate.spec.containers[] | select(.name=="modelserver") | .args[]
    | select(test("tensor-parallel|max-model-len|Offloading"))] | join(" "))' $B
```

Expected: `3`, `ExclusiveSlice` / `kubernetes.io/hostname`; both roles `--tensor-parallel-size=1 --max-model-len=65536`; only prefill mentions `OffloadingConnector`.

To prove the test catches the main mistake, switch the overlay to `.../vllm/gke` and run `./test.sh`: it must fail with `FAIL [pd-g4]: G4 has no RDMA NICs: no DRA claims allowed`. Switch it back.

---

## 4. Bundle the images (connected machine)

Air-gapped clusters only. `bundle.sh` locks and lists the five images from [1.2](#12-prerequisites-images) and caches the InferencePool CRD and router chart:

```bash
LWS_CHART=1 ./bundle.sh --env-file prod profiles/gemma-4-31b-pd-tiered-g4-gke.yaml   # LWS_CHART=1: also the LWS chart + image
grep -E 'vllm-openai:v0.34.0|disagg-sidecar|endpoint-picker:main|google-cloud-cli:slim|curl:8.11.1|lws/lws' .cache/images.lock   # 6 rows
```

Inside the air gap, install LWS from the bundle once per cluster, before the first deploy:

```bash
./install-lws.sh --env-file prod --dry-run     # check the image points at your GAR repo
./install-lws.sh --env-file prod
```

GitHub and the image registries on different machines? Run `BUNDLE_STEPS=sources` on the GitHub one and `BUNDLE_STEPS=images` on the registry one, with this profile on both ([air-gapped §2](../air-gapped.md#2-bundle-on-the-connected-machine)).

Mirror the new rows of `dist/images-to-mirror.tsv` (or use `IMAGE_REMOTES`), as in [air-gapped §4](../air-gapped.md#4-mirror-the-images). `ROUTER_CRDS=1` is not needed.

---

## 5. Deploy and verify

```bash
./deploy.sh --env-file prod profiles/gemma-4-31b-pd-tiered-g4-gke.yaml   # logs the env file, kubectl context and namespace first
```

Preflight stops early if LWS or the `DisaggregatedSet` CRD is missing. The first start downloads ~63 GB of weights to each node's local SSD; both pods on a node share that copy.

```bash
N=gemma-4-31b-it-pd-tiered-g4-vllm
kubectl get pods -n llm-d -l llm-d.ai/deployment=$N -L llm-d.ai/role -o wide   # 6 pods: 1 prefill + 1 decode per node
kubectl logs -n llm-d -l llm-d.ai/deployment=$N,llm-d.ai/role=prefill -c modelserver --tail=-1 | grep -iE 'KV cache size|connector|error' | head
kubectl logs -n llm-d -l llm-d.ai/deployment=$N,llm-d.ai/role=decode  -c modelserver --tail=-1 | grep -iE 'KV cache size|nixl|error' | head

IP=$(kubectl get gateway llm-d-gemma-gateway -n <NAMESPACE> -o jsonpath='{.status.addresses[0].value}')   # internal IP with gke-l7-rilb: call from inside the VPC
curl -s http://$IP/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "google/gemma-4-31B-it",
  "messages": [{"role": "user", "content": "Say hello in one word."}],
  "max_tokens": 32
}'
```

Check in the logs:
- **Each node** has one `prefill` and one `decode` pod (`-o wide` NODE column).
- **Prefill** starts with both connectors and no errors about the hybrid KV cache manager. Gemma mixes sliding-window and full attention, and the overlay keeps `--no-disable-hybrid-kv-cache-manager`. If vLLM refuses `MultiConnector`/`OffloadingConnector` with it, see [7](#7-troubleshooting).
- **`GPU KV cache size: N tokens`** on both roles. You need `N` for [6](#6-tune-before-production).

---

**Metrics (optional).** With `MONITORING=gmp` in the env file, the deploy also creates GKE Managed Prometheus `PodMonitoring` objects: `<name>-modelserver` for vLLM (`/metrics` on the `modelserver` port of every prefill and decode pod) and `<name>-epp` for the EPP (`metrics` port 9090). The EPP runs with `--metrics-endpoint-auth=false`, so neither needs a token. The cluster needs Managed Service for Prometheus enabled; preflight checks for the CRD.

```bash
kubectl -n <NAMESPACE> get podmonitoring                                  # <name>-modelserver and <name>-epp
kubectl -n <NAMESPACE> describe podmonitoring gemma-4-31b-it-pd-tiered-g4-vllm-modelserver | sed -n '/Status/,$p'   # ConfigurationCreateSuccess
```

Metrics then show up in Cloud Monitoring (Metrics Explorer, PromQL), e.g. `vllm:num_requests_running` and `vllm:num_requests_waiting` per pod.

## 6. Tune before production

The prefix index size (`lruCapacityPerServer`) is computed at render from `modelserver.kvCache`; the values in the profile are estimates from `config.json`. Replace them with the `kvCache: {...}` line the deploy prints for the prefill pod (`./deploy.sh <profile> --kv-cache` re-reads it), which is derived from:

| Profile key | How |
| --- | --- |
| `kvCache.gpuTokens` | `N` from `GPU KV cache size: N tokens` |
| `kvCache.bytesPerToken` | `Available KV cache memory` (bytes) ÷ `N` (TP=1) |

`peakPrefillThroughput` is calibrated: **5287 tok/s** (`calibrate.sh` against a prefill pod, `CHUNK_SIZE=8192`, 2026-11-21). It lives in `combos/gemma-4-31b-g4/router.values.yaml`, a copy of the combo's values that the profile uses instead of `combos/pd-tiered-cpu/router.values.yaml`. Re-run [fine-tuning.md](../fine-tuning.md)'s runbook if the model, GPU, TP or `--max-num-batched-tokens` changes.

Other knobs:
- **More KV room:** add `--quantization=fp8` to `modelserver.args` (weights ~31 GB → ~55 GB for KV), then update `kvCache` from the new startup log.
- **Longer context:** raise `--max-model-len` only if the log's KV size covers it.
- **Prefill vs decode split:** fixed at 3 + 3 by the slices. For e.g. 2 prefill + 4 decode, drop `placementPolicy`, set `slices: 1` and patch each role's `replicas`. You lose the one-per-node guarantee, so check that no node gets two 140Gi prefills.

---

## 7. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Pods `Pending`, events mention `ResourceClaim` / `mrdma.google.com` | The profile uses the `.../vllm/gke` overlay. Use `.../vllm/base` as in 2.2. |
| Pods `Pending`: `untolerated taint nvidia.com/gpu` | `combos/g4-pd-sizing` is missing from `components`, so there is no toleration. |
| Pods `Pending`: `Insufficient memory` | Two prefills on one node, or other pods using the RAM. Keep `placementPolicy`; check `kubectl describe node`. |
| Only some slices come up | Fewer than 3 schedulable G4 nodes (`ExclusiveSlice` needs one free node per slice). |
| Render: `test operation failed` | Upstream reordered the P/D args. Find the new index of `--tensor-parallel-size` / `--kv-transfer-config` and update the `test` + `replace` paths. |
| vLLM OOM / `max_model_len ... larger than the maximum number of tokens that can be stored in KV cache` | Lower `--max-model-len` or add `--quantization=fp8`. |
| vLLM rejects the connector with the hybrid KV cache manager | Replace `--no-disable-hybrid-kv-cache-manager` with `--disable-hybrid-kv-cache-manager` on both roles (a `modelserver.patches` file, or a `replace` op in `g4-pd-sizing`). Uses more KV memory for sliding-window layers; recompute [6](#6-tune-before-production). |
| High TTFT, decode waits on KV transfer | Cross-node NIXL over TCP. Compare with 6 aggregated replicas (see the note in [0](#0-layout-and-why)). |
| `Gateway llm-d-gemma-gateway not found` | Create it in the deployment namespace ([1.3](#13-check-the-cluster)), or point `gateway.name` / `gateway.namespace` at an existing one. |
| `Gateway already has catch-all "/" routes` | Another model owns `/` on that Gateway. Use this model's own Gateway, or `gateway.baseModel` + IPP. |
| Decode `Connection reset` under load | Keep-alive mismatch; keep upstream's `VLLM_HTTP_TIMEOUT_KEEP_ALIVE=120`. |

The general tables in [operations §6](../operations.md#6-troubleshooting) still apply (403 on `fetch-model`, `ImagePullBackOff`, images missing from the lock, ...).
