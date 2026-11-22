# 01. First deployment: Qwen3-32B on the optimized baseline

This guide takes a GKE cluster with GPU nodes to a model answering requests through an llm-d Gateway. It uses the simplest strategy, the **optimized baseline**: aggregated vLLM pods behind a router that scores by prefix-cache affinity and token load. It is the right default for any dense model.

**You will deploy:** `Qwen/Qwen3-32B`, 2 replicas × TP=2 (4 GPUs), behind agentgateway. **Time:** about 30 minutes, most of it the first weights download.

| Step | Who | |
| --- | --- | --- |
| [1. Install the tools](#1-install-the-tools) | you | once |
| [2. Prepare the cluster](#2-prepare-the-cluster) | cluster admin | once per cluster |
| [3. Check the weights](#3-check-the-weights) | you | once per model |
| [4. Write the env file](#4-write-the-env-file) | you | once per cluster |
| [5. Read the profile](#5-read-the-profile) | you | once per model |
| [6. Render and validate](#6-render-and-validate) | you | every change |
| [7. Deploy](#7-deploy) | you | every change |
| [8. Call the model](#8-call-the-model) | anyone | |
| [9. Next steps and clean-up](#9-next-steps-and-clean-up) | you | |

## 1. Install the tools

On the machine that runs `deploy.sh`: `kubectl` ≥ 1.27, `helm` ≥ 3.8, `yq` v4 (mikefarah), `git`, `python3` ([prerequisites §1](../prerequisites.md#1-tools)).

```bash
kubectl version --client && helm version --short && yq --version && git --version && python3 --version
```

## 2. Prepare the cluster

Do these once per cluster. Details and alternatives are in [prerequisites.md](../prerequisites.md).

**2.1 GPU nodes.** A node pool with at least 4 H100 or H200 GPUs in total and local SSD as ephemeral storage (Qwen3-32B is about 65 GB).

```bash
kubectl get nodes -L cloud.google.com/gke-accelerator \
  -o custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu,EPH:.status.allocatable.ephemeral-storage
```

**2.2 InferencePool CRD.** Managed by GKE ≥ 1.34.0-gke.1626000 with the Gateway API enabled. Otherwise:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/v1-manifests.yaml
```

**2.3 agentgateway and a Gateway.**

```bash
AGENTGATEWAY_VERSION=v1.1.0
helm upgrade --install agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --namespace agentgateway-system --create-namespace --version ${AGENTGATEWAY_VERSION}
helm upgrade --install agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --create-namespace --version ${AGENTGATEWAY_VERSION} \
  --set inferenceExtension.enabled=true
```

```yaml
# gateway-agentgateway.yaml  →  kubectl apply -n agentgateway-system -f gateway-agentgateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llm-d-inference-gateway
spec:
  gatewayClassName: agentgateway
  listeners:
    - name: default
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
```

```bash
kubectl get gateway -n agentgateway-system llm-d-inference-gateway   # PROGRAMMED=True, an ADDRESS
```

**2.4 Namespace, ServiceAccount, bucket access.**

```yaml
# llm-d-namespace.yaml  →  kubectl apply -f llm-d-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: llm-d
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: llm-d-modelserver
  namespace: llm-d
```

```bash
PROJECT_ID=<project>; PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
gcloud storage buckets add-iam-policy-binding gs://models_registry --role=roles/storage.objectViewer \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${PROJECT_ID}.svc.id.goog/subject/ns/llm-d/sa/llm-d-modelserver"
```

## 3. Check the weights

The garuda repo stores weights in GCS; this pipeline only reads them. The folder is the HF id, lowercased, `/` → `__`, other punctuation → `_`:

```bash
gcloud storage ls gs://models_registry/qwen__qwen3_32b/config.json
```

If it is missing, have garuda store the model first.

## 4. Write the env file

The env file says **where** to deploy. Copy the template and keep only what you need:

```bash
cp envs/example.env envs/dev.env
```

```bash
# envs/dev.env
KUBECONFIG=$HOME/.kube/llm-d-dev      # a kubeconfig holding only this cluster
NAMESPACE=llm-d
SERVICE_ACCOUNT=llm-d-modelserver
MODEL_BUCKET=gs://models_registry
# no IMAGE_REGISTRY: a connected cluster pulls from public registries
```

```bash
gcloud container clusters get-credentials <cluster> --region <region>   # with KUBECONFIG=$HOME/.kube/llm-d-dev exported
```

## 5. Read the profile

The profile says **what** to deploy. This one ships with the repo:

```yaml
# profile: profiles/baseline-agentgateway.yaml
model: Qwen/Qwen3-32B
strategy: baseline
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

| Line | Meaning |
| --- | --- |
| `model` | HF id. Picks the GCS folder; clients send it as `model`. |
| `strategy` | Middle part of the name: `qwen3-32b-baseline-vllm`. |
| `modelserver.overlay` | Upstream llm-d overlay: aggregated vLLM `Deployment`, 2 replicas × TP=2, written for Qwen3-32B. |
| `router.values` | The same guide's router config: prefix-cache affinity + token load. |
| `gateway` | The Gateway from step 2.3. |

Every field: [configuration.md §4](../configuration.md#4-profile-fields).

## 6. Render and validate

No cluster needed:

```bash
./deploy.sh profiles/baseline-agentgateway.yaml --name       # qwen3-32b-baseline-vllm
./deploy.sh -e dev profiles/baseline-agentgateway.yaml --dry-run
ls .build/qwen3-32b-baseline-vllm/                           # modelserver.yaml router.yaml
./test.sh
```

The first render clones llm-d at the pinned commit into `.cache/` and pulls the router chart. Look through the two files: they are exactly what gets applied. Things to spot:

```bash
B=.build/qwen3-32b-baseline-vllm
yq 'select(.kind=="Deployment") | .metadata.name' $B/modelserver.yaml                          # qwen3-32b-baseline-vllm
yq 'select(.kind=="Deployment") | .spec.template.spec.initContainers[].name' $B/modelserver.yaml # fetch-model
yq 'select(.kind=="InferencePool") | .spec.selector' $B/router.yaml                             # llm-d.ai/deployment: qwen3-32b-baseline-vllm
```

## 7. Deploy

```bash
./deploy.sh -e dev profiles/baseline-agentgateway.yaml
```

Watch the first lines: they name the env file, kubectl context and namespace. Then:

1. **Preflight** checks the namespace, ServiceAccount, CRD and Gateway.
2. **Router** (EPP, InferencePool, HTTPRoute) is applied; the script waits for the EPP.
3. **Model servers** are applied. On each node, `fetch-model` copies the weights to local SSD once; vLLM then loads them offline.
4. **Wait** for the route to be accepted and every pod to be Ready (up to 60 minutes).
5. **Smoke test**: one completion through the Gateway.
6. **KV cache report**: a `kvCache: {...}` line per pod. Not needed for this strategy; see [fine-tuning.md](../fine-tuning.md) for when it is.

In another terminal:

```bash
kubectl get pods -n llm-d -l llm-d.ai/deployment=qwen3-32b-baseline-vllm -w
kubectl logs -n llm-d -l llm-d.ai/deployment=qwen3-32b-baseline-vllm -c fetch-model -f
```

## 8. Call the model

```bash
IP=$(kubectl get gateway llm-d-inference-gateway -n agentgateway-system -o jsonpath='{.status.addresses[0].value}')
curl -s http://$IP/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "Qwen/Qwen3-32B",
  "messages": [{"role": "user", "content": "Say hello in one word."}],
  "max_tokens": 32
}'
```

Any OpenAI-compatible client works with `base_url=http://$IP/v1`.

## 9. Next steps and clean-up

- Calibrate the router for your accelerator before production: [fine-tuning.md](../fine-tuning.md).
- Serve your own model: [guide 02](02-bring-your-own-model.md).
- Day-2 changes and troubleshooting: [operations.md](../operations.md).

Remove the deployment (the namespace, ServiceAccount and Gateway stay):

```bash
./deploy.sh -e dev profiles/baseline-agentgateway.yaml --delete
```
