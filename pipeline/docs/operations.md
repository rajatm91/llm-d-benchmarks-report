# Operations

Validating, deploying, verifying and changing deployments, running the pipeline from Jenkins, and fixing what breaks.

- [1. Validate offline](#1-validate-offline)
- [2. Deploy](#2-deploy)
- [3. Verify and call the model](#3-verify-and-call-the-model)
- [4. Day-2 operations](#4-day-2-operations)
- [5. Run it from Jenkins](#5-run-it-from-jenkins)
- [6. Troubleshooting](#6-troubleshooting)

## 1. Validate offline

None of these need a cluster:

```bash
./deploy.sh profiles/<name>.yaml --name       # derived name, e.g. qwen3-8-27b-baseline-vllm
./deploy.sh profiles/<name>.yaml --env        # every resolved setting
./deploy.sh -e prod profiles/<name>.yaml --dry-run
less .build/<name>/{modelserver,router}.yaml  # exactly what will be applied
./test.sh                                     # every profile, ~10 s; ends with "all checks passed"
docs/check-guide.sh                           # every YAML sample in docs/guides/ still renders
```

`--dry-run` stops at the first problem: an unknown key, a name over 40 characters, an image missing from the bundle, a draft model on an MTP overlay, `tensorParallel` on P/D, an upstream arg reorder caught by a combo's `test` op.

`test.sh` renders every profile into one namespace and checks the wiring that would otherwise only fail at runtime:
- the pool selects exactly this deployment's pods, and no names collide;
- the route points at the right Gateway, with the provider's objects;
- weights are fetched from GCS and loaded offline;
- model, TP, args and speculative config reached every vLLM container;
- the prefix index is sized from `modelserver.kvCache`;
- with `.cache/images.lock` present, every image is mirrored and digest-pinned.

Run both scripts after every profile change and every `llmdRef` bump.

## 2. Deploy

```bash
./deploy.sh -e prod profiles/<name>.yaml
```

The first log lines name the env file, the kubectl context and the namespace. **Check them**: `deploy.sh` has no cluster setting of its own and uses kubectl's current context. Giving each environment its own `KUBECONFIG` file (as `envs/example.env` does) removes the risk.

The run then: renders, runs preflight (namespace, ServiceAccount, CRDs, LWS, Gateway, conflicting routes), applies the router and waits for the EPP, applies the model servers, waits for the HTTPRoute and every pod (up to `waitTimeout`), sends one completion through the Gateway, and prints the measured `kvCache` line. Step details: [concepts §3](concepts.md#3-what-deploysh-does).

Re-running with the same profile is safe: `kubectl apply --server-side` updates in place.

## 3. Verify and call the model

```bash
N=$(./deploy.sh profiles/<name>.yaml --name)
kubectl get pods,inferencepool,httproute -n llm-d -l llm-d.ai/deployment=$N
kubectl logs -n llm-d -l llm-d.ai/deployment=$N -c fetch-model --tail=5      # "ready: /model-cache/hub/..."
kubectl get httproute $N -n llm-d -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'

IP=$(kubectl get gateway llm-d-inference-gateway -n agentgateway-system -o jsonpath='{.status.addresses[0].value}')
curl -s http://$IP/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "<HF id from the profile>",
  "messages": [{"role": "user", "content": "Say hello in one word."}],
  "max_tokens": 32
}'
```

Clients always send the **Hugging Face model id**, even though weights come from GCS. A `gke-l7-rilb` Gateway has an internal address: call it from inside the VPC.

`./deploy.sh -e prod profiles/<name>.yaml --kv-cache` re-reads the measured KV cache sizes from the running pods ([fine-tuning.md](fine-tuning.md)).

With `MONITORING=gmp`, metrics such as `vllm:num_requests_running` and `vllm:num_requests_waiting` appear in Cloud Monitoring (Metrics Explorer, PromQL). `kubectl get podmonitoring -n llm-d` lists `<name>-modelserver` and `<name>-epp`.

## 4. Day-2 operations

| Task | How |
| --- | --- |
| Change flags, replicas or TP | Edit the profile, `--dry-run`, then `./deploy.sh <profile>`. |
| Upgrade vLLM for one model | Set `modelserver.image`. Air-gapped: `./bundle.sh profiles/<it>.yaml` and mirror the new row first. Only that model's vLLM containers change. |
| New weights for the same model | Have garuda store them in a **new folder**, set `weights.gcsUri`, redeploy. Nodes cache by path, so new files under an old path are not picked up. |
| Add a model | Check `gcloud storage ls gs://models_registry/<folder>/config.json`, write a profile ([guide 02](guides/02-bring-your-own-model.md)), validate, bundle if air-gapped, deploy. |
| Tune the router after first deploy | [fine-tuning.md](fine-tuning.md) |
| Remove a deployment | `./deploy.sh <profile> --delete`. Removes exactly the rendered objects; namespace, ServiceAccount and Gateway stay. |
| Upgrade llm-d | Change `llmdRef` (or `LLMD_REF` in `lib/profile.sh`), run `./test.sh` and `docs/check-guide.sh`, re-bundle. Upstream moves fail the render before anything reaches a cluster. |
| Change router chart version | `--delete` with the **old** render first. Resources dropped by the new chart are not pruned. |
| Free node disk | Delete old model folders under `$MODEL_CACHE_PATH/hub/` on the node. The cache is never evicted. |

## 5. Run it from Jenkins

The bundle tarball is the job's input; the agent needs no internet access.

```groovy
// Jenkinsfile (sample)
pipeline {
  agent { label 'llm-d-deployer' }            // kubectl, helm, yq, git, python3
  parameters {
    string(name: 'PROFILE', defaultValue: 'qwen3.8-27b-baseline-agentgateway', description: 'profiles/<PROFILE>.yaml')
    choice(name: 'ACTION', choices: ['dry-run', 'deploy', 'delete'])
    choice(name: 'CLUSTER', choices: ['gpu-staging', 'gpu-prod'])
  }
  environment {
    NAMESPACE      = 'llm-d'
    IMAGE_REGISTRY = 'us-docker.pkg.dev/<project>/llm-d'
    IMAGE_TEMPLATE = '{registry}/{path}:{tag}'   // same as when bundle.sh wrote the mirror list
    MODEL_BUCKET   = 'gs://models_registry'
  }
  options { timeout(time: 3, unit: 'HOURS') }
  stages {
    stage('Unpack bundle') {
      steps { copyArtifacts projectName: 'llm-d-bundle', selector: lastSuccessful(), target: 'bundle'
              sh 'tar -xzf bundle/dist/llm-d-bundle-*.tar.gz -C pipeline ./.cache' }
    }
    stage('Validate') { steps { dir('pipeline') { sh './test.sh' } } }
    stage('Render') {
      steps { dir('pipeline') {
        sh "./deploy.sh profiles/${params.PROFILE}.yaml --dry-run"
        archiveArtifacts artifacts: '.build/**/*.yaml'          // exactly what gets applied
      } }
    }
    stage('Approve') {
      when { expression { params.ACTION != 'dry-run' && params.CLUSTER == 'gpu-prod' } }
      steps { input message: "${params.ACTION} ${params.PROFILE} on ${params.CLUSTER}?" }
    }
    stage('Apply') {
      when { expression { params.ACTION != 'dry-run' } }
      steps { dir('pipeline') {
        withCredentials([file(credentialsId: "kubeconfig-${params.CLUSTER}", variable: 'KUBECONFIG')]) {
          lock("gateway-${params.CLUSTER}") {                   // preflight checks shared Gateway routes
            sh "./deploy.sh profiles/${params.PROFILE}.yaml ${params.ACTION == 'delete' ? '--delete' : ''}"
          }
        }
      } }
    }
  }
}
```

The per-cluster kubeconfig credential plays the role of the env file's `KUBECONFIG`. The `lock` serializes deploys to one Gateway, because preflight's route-conflict check is read-then-write.

## 6. Troubleshooting

### Render and preflight

| Symptom | Cause and fix |
| --- | --- |
| `unknown key(s) in ...` | Typo in the profile; the message names the key. |
| `not a setting: X (did you mean Y?)` | Typo in the env file or shell. |
| `derived name ... at most 40 chars` | Set `modelAlias`. |
| `image ... is not in .cache/images.lock` | The profile uses an image the bundle lacks. `./bundle.sh profiles/<it>.yaml` on the connected side. |
| `cannot fetch llm-d` / `cannot pull ...chart` | No network and no `.cache/`. Unpack the bundle into `pipeline/`. |
| Render: `test operation failed` | Upstream reordered args a combo patches by index. Find the new index and update the `test` + `replace` paths in the combo. |
| `WARNING: modelserver.kvCache.{...} not set` | Fine for a first deploy. Copy the `kvCache` line the deploy prints into the profile ([fine-tuning.md](fine-tuning.md)). |
| `namespace ... not found` / `ServiceAccount ... not found` | [prerequisites §7](prerequisites.md#7-namespace-serviceaccount-and-bucket-access), or set `NAMESPACE` / `SERVICE_ACCOUNT`. |
| `InferencePool CRD missing` | [prerequisites §4](prerequisites.md#4-gateway-api-and-inferencepool-crd). |
| `... needs the LWS controller` / `DisaggregatedSet CRD missing` | Install LWS with `enableDisaggregatedSet=true` ([prerequisites §6](prerequisites.md#6-leaderworkerset-pd-and-wide-ep-only)). |
| `Gateway ... not found` | Create it ([prerequisites §5](prerequisites.md#5-a-gateway)) or fix `gateway.name` / `gateway.namespace`. |
| `Gateway listeners only allow routes from: Same` | Set `allowedRoutes.namespaces.from: All` (or a Selector) on the Gateway. |
| `Gateway already has catch-all "/" routes` | Another model owns `/`. Use a separate Gateway, or `gateway.baseModel` + IPP ([guide 06](guides/06-multi-model-gateway.md)). |

### Pods

| Symptom | Cause and fix |
| --- | --- |
| `Init:0/1`, `fetch-model` log shows 403 | SA can't read the bucket: Workload Identity binding, Private Google Access ([prerequisites §7](prerequisites.md#7-namespace-serviceaccount-and-bucket-access)). |
| `fetch-model`: `no config.json at the top of gs://...` | Folder name or layout differs. `gcloud storage ls` it; set `weights.gcsUri` if garuda used another name. |
| `fetch-model` "fetching" for a long time | Expected on a node's first download. Other pods on the node wait on its lock. |
| `ImagePullBackOff` | Node SA lacks `artifactregistry.reader`, or the image isn't at the referenced path. Compare `kubectl describe pod` with `dist/images-to-mirror.tsv`; check `IMAGE_REGISTRY` / `IMAGE_TEMPLATE` matched between bundle and deploy. |
| Pending: insufficient `nvidia.com/gpu` or ephemeral storage | Not enough free GPUs or local SSD. Check `tensorParallel × replicas` against the pool, and model size against local SSD. |
| Pending: `untolerated taint nvidia.com/gpu` | `base` overlays carry no GPU toleration. Add one with `modelserver.patches`. |
| Pending: `ResourceClaim` / `mrdma.google.com` | A `gke` P/D overlay asks for RDMA NICs the nodes lack. Use `base` ([guide 07](guides/07-gemma-pd-tiered-g4.md)). |
| vLLM `unrecognized arguments` or parser errors after a model swap | Put the new model's parser and chat-template flags in `modelserver.args`. |
| vLLM OOM / `max_model_len ... larger than ... KV cache` | Raise `tensorParallel`, lower `--max-model-len` / `--gpu-memory-utilization`, add `--quantization=fp8`, or drop the draft model. |

### Traffic

| Symptom | Cause and fix |
| --- | --- |
| Every request returns **503** on GKE | `gateway.provider` is not `gke`, so no `HealthCheckPolicy`. Set it and redeploy. |
| Deploy waits at `HTTPRoute ... Accepted` | The Gateway doesn't allow routes from `NAMESPACE`, or its controller isn't running. |
| Long requests cut off at 5 minutes | Raise `gateway.timeoutSec`. |
| P/D: decode `Connection reset` under load | Keep-alive mismatch. Keep upstream's `VLLM_HTTP_TIMEOUT_KEEP_ALIVE=120` if you patch the env. |
| Router hit ratio (`llm_d_epp_prefix_indexer_hit_ratio`) far above vLLM's own | Prefix index oversized. Set `modelserver.kvCache` from the measured values ([fine-tuning.md](fine-tuning.md)). |
