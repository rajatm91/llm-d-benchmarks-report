# llm-d deploy pipeline

Deploy any Hugging Face model on Kubernetes with any [llm-d](https://github.com/llm-d/llm-d) serving strategy (or a combination of them) and register it with a Gateway you already run (agentgateway, GKE Gateway, Istio).

The pipeline does not copy llm-d's manifests. It renders the upstream `guides/` at a pinned commit, then rewrites the result so that:

- many models can share **one namespace** and **one Gateway**;
- weights come from **GCS** (stored there by the garuda repo), cached once per node, with no Hugging Face access;
- every image can come from **your Artifact Registry**, so the cluster can be **air-gapped**;
- the model, vLLM image, flags, TP and replicas are set in **one YAML profile**, whatever model the upstream guide was written for.

Upstream fixes come in by bumping one commit SHA.

```
client ─► Gateway (shared, pre-existing)
            └─ HTTPRoute <name> ─► InferencePool <name> ─► EPP <name>-epp     ← router half (llm-d router chart)
                                         └─ selects pods llm-d.ai/deployment=<name>
                                              └─ vLLM pods                     ← model-server half (llm-d guide overlay)
                                                   ├─ init: fetch-model  (GCS → node-local SSD)
                                                   └─ vllm serve <model> ...
```

## Quick start

```bash
# tools: kubectl (kustomize v5), helm >= 3.8, yq v4, git, python3
./deploy.sh profiles/baseline-agentgateway.yaml --dry-run   # render only, no cluster needed → .build/<name>/
./test.sh                                                  # offline checks for every profile (~10 s)

cp envs/example.env envs/dev.env                           # edit: KUBECONFIG, NAMESPACE, registry, bucket
./deploy.sh -e dev profiles/baseline-agentgateway.yaml     # preflight, apply, wait, smoke test
./deploy.sh -e dev profiles/baseline-agentgateway.yaml --delete
```

The cluster needs a few things in place first (GPU nodes, a Gateway, the InferencePool CRD, a namespace and ServiceAccount). [Guide 01](docs/guides/01-first-deployment.md) walks through all of it.

## Documentation

| Read | When |
| --- | --- |
| [Concepts](docs/concepts.md) | First. How a deployment is built, the llm-d strategies, naming, weights, combining strategies. |
| [Prerequisites](docs/prerequisites.md) | Before the first deploy. Tools for each machine, and one-time cluster setup. |
| [Configuration](docs/configuration.md) | When you change anything. Every environment setting and profile field, when to use it, and the upstream templates you can point at. |
| [Guides](docs/guides/README.md) | Step-by-step sample deployments, from a first baseline to wide-EP. |
| [Air-gapped deploys](docs/air-gapped.md) | When the cluster has no internet access. `bundle.sh`, image mirroring, `install-lws.sh`. |
| [Operations](docs/operations.md) | Validating, deploying, verifying, day-2 changes, Jenkins, troubleshooting. |
| [Fine-tuning](docs/fine-tuning.md) | After the first deploy of a new model or accelerator. Router calibration and prefix-cache sizing. |

## Commands

| Command | What it does | Needs |
| --- | --- | --- |
| `./deploy.sh <profile> --dry-run` | Render to `.build/<name>/{modelserver,router}.yaml` | network or `.cache/` |
| `./deploy.sh <profile>` | Render, preflight, apply, wait for Ready, smoke test, print measured KV cache | cluster |
| `./deploy.sh <profile> --delete` | Delete exactly what the render contains | cluster |
| `./deploy.sh <profile> --name` | Print the derived deployment name | — |
| `./deploy.sh <profile> --env` | Print every resolved setting | — |
| `./deploy.sh <profile> --kv-cache` | Read `modelserver.kvCache` values from the running pods' vLLM logs | cluster |
| `./test.sh` | Render every profile and check the wiring (selectors, names, images, args) | network or `.cache/` |
| `./bundle.sh [profiles...]` | Air gap: cache guides, charts and CRDs, lock image digests, write the mirror list, pack a tarball | internet |
| `./install-lws.sh` | Air gap: install LeaderWorkerSet from the bundle | cluster |
| `docs/check-guide.sh` | Check every YAML sample in `docs/guides/` against the pipeline | network or `.cache/` |

All of them take `--env-file <env>` (or `-e`), which loads `envs/<env>.env` or a path.

## Repository layout

```
deploy.sh            the step list: render → preflight → apply → wait → smoke test
bundle.sh            air gap, connected side: cache sources, lock images, pack
install-lws.sh       air gap: LeaderWorkerSet from the bundle
test.sh              offline render checks for every profile
profiles/*.yaml      one file per model deployment (what runs)
envs/example.env     template for one file per environment (where it runs)
combos/              this repo's kustomize components + router values for strategy combinations
lib/profile.sh       settings: defaults, environment, profile → variables, naming
lib/render.sh        render steps (overlay, rename, model swap, args, weights, router, images)
lib/yq/*.yq          one yq program per YAML edit
lib/cluster.sh       preflight, apply, wait, smoke test, delete, KV cache report
lib/images.sh        image naming for the mirror list and the rewrite
lib/fetch-model.sh   weights init container script (embedded verbatim in pods)
lib/env.sh           --env-file loading and typo checks
.cache/              (generated) pinned llm-d checkouts, charts, CRDs, images.lock
.build/<name>/       (generated) rendered manifests: exactly what gets applied
dist/                (generated) bundle tarballs and the image mirror list
```

Paths in a profile that start with `guides/` resolve inside the pinned llm-d checkout. Any other path resolves relative to this directory.
