# 06. Several models on one Gateway

Each deployment's HTTPRoute matches every path (`/`). Two such routes on one Gateway conflict: the oldest wins and the other model is unreachable. To serve several models behind one address, each route matches on a header instead, `X-Gateway-Base-Model-Name`, which the **Inference Payload Processor (IPP)** sets from the `"model"` field of the request body.

**You will deploy:** Qwen3.8-27B and Qwen3-32B on the same agentgateway Gateway; clients pick one with `"model"`.

Prerequisites: [guide 01](01-first-deployment.md) works on your cluster.

## 1. How it fits together

```
client  {"model": "Qwen/Qwen3.8-27B", ...}
  └─► Gateway ─► IPP (ext-proc): body "model" → header X-Gateway-Base-Model-Name, from its ConfigMaps
        ├─ HTTPRoute qwen3-8-27b-baseline-vllm   matches header = Qwen/Qwen3.8-27B ─► its InferencePool
        └─ HTTPRoute qwen3-32b-baseline-vllm     matches header = Qwen/Qwen3-32B   ─► its InferencePool
```

Without `gateway.baseModel`, preflight stops when the Gateway already has a catch-all route: `Gateway already has catch-all "/" routes (...)`.

## 2. Install IPP once per Gateway

```bash
git clone https://github.com/llm-d/llm-d-inference-payload-processor.git /tmp/ipp   # mirror it inside an air gap
helm install ipp /tmp/ipp/config/charts/payload-processor \
  --set provider.name=agentgateway \
  --set inferenceGateway.name=llm-d-inference-gateway \
  -n llm-d
```

Use `provider.name=gke` or `istio` for those Gateways.

## 3. Write one profile per model, each with `baseModel`

```yaml
# profile: profiles/qwen3.8-27b-shared-agentgateway.yaml
model: Qwen/Qwen3.8-27B
strategy: baseline
modelserver:
  overlay: guides/optimized-baseline/modelserver/gpu/vllm/base
  tensorParallel: 1
  args: [--enable-auto-tool-choice, --tool-call-parser=qwen3_coder, --reasoning-parser=qwen3]
router:
  values:
    - guides/optimized-baseline/router/optimized-baseline.values.yaml
gateway:
  provider: agentgateway
  name: llm-d-inference-gateway
  namespace: agentgateway-system
  baseModel: Qwen/Qwen3.8-27B             # route matches X-Gateway-Base-Model-Name: Qwen/Qwen3.8-27B
```

```yaml
# profile: profiles/qwen3-32b-shared-agentgateway.yaml
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
  baseModel: Qwen/Qwen3-32B
```

Save both under `profiles/`. **Every** model on the shared Gateway needs `baseModel`, including one that was there first. The second profile is guide 01's deployment plus `baseModel`: same name (`qwen3-32b-baseline-vllm`), so deploying it updates that deployment in place.

Check the route match:

```bash
./deploy.sh profiles/qwen3.8-27b-shared-agentgateway.yaml --dry-run
yq 'select(.kind=="HTTPRoute") | .spec.rules[].matches' .build/qwen3-8-27b-baseline-vllm/router.yaml
```

## 4. Register each model with IPP

One ConfigMap per model, in the IPP namespace:

```yaml
# ipp-models.yaml  →  kubectl apply -n llm-d -f ipp-models.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: qwen3-8-27b-model-mapping
  labels:
    inference.llm-d.ai/ipp-managed: "true"
data:
  baseModel: "Qwen/Qwen3.8-27B"            # the "model" value clients send
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: qwen3-32b-model-mapping
  labels:
    inference.llm-d.ai/ipp-managed: "true"
data:
  baseModel: "Qwen/Qwen3-32B"
```

## 5. Deploy and call both

```bash
./deploy.sh -e dev profiles/qwen3.8-27b-shared-agentgateway.yaml
./deploy.sh -e dev profiles/qwen3-32b-shared-agentgateway.yaml

IP=$(kubectl get gateway llm-d-inference-gateway -n agentgateway-system -o jsonpath='{.status.addresses[0].value}')
for m in Qwen/Qwen3.8-27B Qwen/Qwen3-32B; do
  curl -s http://$IP/v1/completions -H 'Content-Type: application/json' \
    -d "{\"model\": \"$m\", \"prompt\": \"Say hello.\", \"max_tokens\": 8}" | yq -p json '.model'
done
```

Each answer reports the model that served it.

**From Jenkins**, wrap deploys to one Gateway in a `lock` ([operations §5](../operations.md#5-run-it-from-jenkins)): preflight's route check and the apply are not atomic.

**Alternative:** give a model its own Gateway (as [guide 07](07-gemma-pd-tiered-g4.md) does). No IPP, but a separate address.
