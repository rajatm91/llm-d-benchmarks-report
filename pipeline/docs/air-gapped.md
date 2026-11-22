# Air-gapped deploys

When the cluster (and the machine that runs `deploy.sh`) has no internet access, everything the render needs is prepared on a connected machine by `bundle.sh` and carried in as one tarball. Images go into your Artifact Registry; weights are already in GCS.

- [1. The flow](#1-the-flow)
- [2. Bundle on the connected machine](#2-bundle-on-the-connected-machine)
- [3. Choose the image layout](#3-choose-the-image-layout)
- [4. Mirror the images](#4-mirror-the-images)
- [5. LeaderWorkerSet](#5-leaderworkerset)
- [6. Deploy inside the air gap](#6-deploy-inside-the-air-gap)
- [7. Adding a profile or upgrading later](#7-adding-a-profile-or-upgrading-later)

## 1. The flow

| Step | Runs on | Needs access to | Command |
| --- | --- | --- | --- |
| 1. Bundle | connected machine | GitHub, ghcr.io, docker.io, quay.io, gcr.io | `./bundle.sh -e prod profiles/<name>.yaml` |
| 2. Mirror images | your mirroring host | internet + push to Artifact Registry | copy the rows of `dist/images-to-mirror.tsv` (or use `IMAGE_REMOTES`) |
| 3. Carry | — | — | move `dist/llm-d-bundle-*.tar.gz` inside |
| 4. Deploy | deploy machine or Jenkins agent | the cluster API only | `./deploy.sh -e prod profiles/<name>.yaml` |

The cluster's nodes pull images from Artifact Registry and weights from GCS themselves (Private Google Access). The deploy machine needs neither.

`IMAGE_REGISTRY`, `IMAGE_TEMPLATE` and `IMAGE_REMOTES` must have the **same values** for `bundle.sh` and `deploy.sh`. Keep them in one env file ([`envs/example.env`](../envs/example.env)) used by both.

## 2. Bundle on the connected machine

```bash
cp envs/example.env envs/prod.env          # set IMAGE_REGISTRY, IMAGE_TEMPLATE (and/or IMAGE_REMOTES)
./bundle.sh -e prod profiles/gemma-4-31b-llmd-1.0-vllm-0.34-agentgateway.yaml   # no profiles = all of them
```

`bundle.sh` needs no access to Artifact Registry, GCS or the cluster, and never pushes anything. It:

1. **Renders every profile**, which fills `.cache/` (pinned llm-d guides, router chart, InferencePool CRDs) and `.build/`.
2. **Locks image digests.** Every image in the renders, plus the smoke-test image, is resolved to a digest in `.cache/images.lock`. Moving tags (`:main`, `:latest`, `:slim`) are frozen there. Digests come from `docker buildx imagetools` if available, else straight from the registry with `curl` (so podman machines work).
3. **Writes the mirror list** `dist/images-to-mirror.tsv`: `SOURCE (repo@digest) <tab> TARGET (in your registry) <tab> ORIGINAL`.
4. **Packs** this directory with `.cache/` into `dist/llm-d-bundle-<llmd sha>-<date>.tar.gz`.

| Output | Used for |
| --- | --- |
| `.cache/llm-d-<sha>/` | pinned llm-d guides (overlays, router values) |
| `.cache/charts/<chart>-<version>/` | router Helm chart |
| `.cache/crds/` | InferencePool CRDs (and router / LWS extras when asked) |
| `.cache/images.lock` | every image the profiles use, pinned to a digest |
| `dist/images-to-mirror.tsv` | what to copy into your registry |
| `dist/llm-d-bundle-<sha>-<date>.tar.gz` | carry this inside |

Bundling a subset of profiles merges into the existing lock, so earlier profiles stay covered.

**GitHub and the registries on different machines?** Split the run with `BUNDLE_STEPS`, passing the same profiles to both:

```bash
# machine A (GitHub, ghcr.io charts)
BUNDLE_STEPS=sources ./bundle.sh profiles/<it>.yaml        # → dist/llm-d-sources-<sha>-<date>.tar.gz

# machine B (image registries; no GitHub)
tar -xzf llm-d-sources-<sha>-<date>.tar.gz -C pipeline && cd pipeline
BUNDLE_STEPS=images ./bundle.sh -e prod profiles/<it>.yaml # → digests, mirror list, final llm-d-bundle tarball
```

Carry the **final** `llm-d-bundle-*` tarball inside: only it has `.cache/images.lock`. Pass `ROUTER_CRDS=1` / `LWS_CHART=1` to both steps when you need them.

## 3. Choose the image layout

`IMAGE_TEMPLATE` says where each image lives inside `IMAGE_REGISTRY`. `bundle.sh` uses it for the mirror list and `deploy.sh` uses it (through `lib/images.sh`) to rewrite manifests. For `docker.io/vllm/vllm-openai:v0.34.0`:

| `IMAGE_TEMPLATE` | Becomes | Use when |
| --- | --- | --- |
| `{registry}/{host}/{path}@{digest}` (default) | `<registry>/docker.io/vllm/vllm-openai@sha256:…` | your copy preserves digests (all architectures copied as-is). Most reproducible. |
| `{registry}/{path}:{tag}` | `<registry>/vllm/vllm-openai:v0.34.0` | you copy by tag, or with `docker pull` + `docker push` (which changes multi-arch digests) |
| `{registry}/{name}:{tag}` | `<registry>/vllm-openai:v0.34.0` | flat repository. `bundle.sh` stops if two images would collide. |

Placeholders: `{registry}`, `{host}`, `{path}`, `{name}` (last path segment), `{tag}`, `{digest}`.

**Artifact Registry remote repos instead of copying.** With one remote (pull-through) repo per upstream host:

```bash
IMAGE_REMOTES='docker.io=asia-south1-docker.pkg.dev/<proj>/docker-io ghcr.io=asia-south1-docker.pkg.dev/<proj>/ghcr gcr.io=asia-south1-docker.pkg.dev/<proj>/gcr quay.io=asia-south1-docker.pkg.dev/<proj>/quay'
```

Images from those hosts become `<repo>/<upstream path>@<digest>` and are left off the mirror list. With all four mapped there is nothing to copy and `IMAGE_REGISTRY` is not needed. Digests are still locked, so deploys stay reproducible. Add `registry.k8s.io=<repo>` for LWS.

## 4. Mirror the images

Skip this if `IMAGE_REMOTES` covers every host. Otherwise, copy each row of `dist/images-to-mirror.tsv` with your own tooling (`crane copy`, `gcrane cp`, `skopeo copy --all`, ...):

```
SOURCE                                                   TARGET                                                                ORIGINAL
docker.io/vllm/vllm-openai@sha256:20fdb0…                us-docker.pkg.dev/my-project/llm-d/vllm/vllm-openai:v0.34.0           docker.io/vllm/vllm-openai:v0.34.0
ghcr.io/llm-d/llm-d-router-endpoint-picker@sha256:0241…  us-docker.pkg.dev/my-project/llm-d/llm-d/llm-d-router-endpoint-picker:v1.0.0  ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0
```

Copy from `SOURCE` (`repo@digest`), never from the original tag: tags move, and the digest is what was locked. For example:

```bash
tail -n +2 dist/images-to-mirror.tsv | while IFS=$'\t' read -r src dst _; do crane copy "$src" "$dst"; done
```

The node service account needs `roles/artifactregistry.reader` on the repository.

## 5. LeaderWorkerSet

P/D and wide-EP profiles need LWS on the cluster. Bundle it with the rest and install it from the bundle, once per cluster:

```bash
LWS_CHART=1 ./bundle.sh -e prod profiles/<p-d-profile>.yaml   # connected: chart → .cache/charts/lws-1.0.0/, image → lock + mirror list
./install-lws.sh -e prod --dry-run                            # inside: shows the mapped image and commands
./install-lws.sh -e prod                                      # CRDs + helm upgrade --install lws (enableDisaggregatedSet=true)
```

Its image (`registry.k8s.io/lws/lws`) is mapped like every other: `registry.k8s.io=<repo>` in `IMAGE_REMOTES`, or a row in the mirror list. `LWS_VERSION` picks another chart version. Safe to re-run.

## 6. Deploy inside the air gap

```bash
tar -xzf llm-d-bundle-<sha>-<date>.tar.gz -C pipeline        # brings .cache/ (guides, chart, CRDs, images.lock)
cd pipeline
kubectl apply -f .cache/crds/inference-extension-v1.yaml     # once per cluster, if GKE doesn't manage it
./deploy.sh -e prod profiles/<name>.yaml --dry-run           # review .build/<name>/: every image points at your registry
./deploy.sh -e prod profiles/<name>.yaml
```

`deploy.sh` reads everything from `.cache/` and needs no network beyond the cluster API. An image that is not in `images.lock` fails the render (`image ... is not in .cache/images.lock`) instead of failing later as `ImagePullBackOff`. `./test.sh` also checks the rewrite for every profile whenever `images.lock` exists.

## 7. Adding a profile or upgrading later

| Change | On the connected side | Inside |
| --- | --- | --- |
| New profile, same images | nothing, if `./deploy.sh --dry-run` renders inside | deploy |
| New profile or new `modelserver.image` | `./bundle.sh -e prod profiles/<new>.yaml`; mirror new rows | unpack the new tarball, deploy |
| New `llmdRef` / chart version | `./bundle.sh -e prod` (all affected profiles); mirror new rows | unpack, `./test.sh`, deploy |
| Router chart version change | as above | `./deploy.sh <profile> --delete` with the **old** render first: resources dropped by the new chart are not pruned |

Several llm-d versions can coexist in one bundle: each `llmdRef` gets its own `.cache/llm-d-<sha>/`.
