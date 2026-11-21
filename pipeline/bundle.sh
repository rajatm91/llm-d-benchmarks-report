#!/usr/bin/env bash
# Prepare everything an air-gapped deploy needs. Run on a machine WITH internet access.
#
#   ./bundle.sh                                   # all profiles
#   ./bundle.sh profiles/a.yaml profiles/b.yaml   # only these profiles
#   ./bundle.sh --help                            # this text
#   ./bundle.sh --env-file dev [profiles...]      # load envs/dev.env (or a path) first; -e for short
#
# Split across two machines (one reaches GitHub, the other the image registries):
#   machine A: BUNDLE_STEPS=sources ./bundle.sh   # guides, charts, CRDs -> $OUT/llm-d-sources-<sha>-<date>.tar.gz
#   machine B: tar -xzf llm-d-sources-*.tar.gz -C pipeline && cd pipeline
#              BUNDLE_STEPS=images ./bundle.sh    # no GitHub: digests, mirror list, final bundle tarball
#   Pass the same profiles (or none) on both machines.
#
# Optional environment:
#   IMAGE_REGISTRY=us-docker.pkg.dev/<proj>/<repo>  your registry (fills the target column of the mirror list)
#   IMAGE_TEMPLATE='{registry}/{name}:{tag}'        how images are laid out in it (see lib/images.sh); must be
#                                                   the same value deploy.sh gets inside the air gap
#   IMAGE_REMOTES='docker.io=<repo> ghcr.io=<repo>' Artifact Registry remote repos per upstream host: those
#                                                   images are pulled through, so they stay off the mirror list
#   ROUTER_CRDS=1                                   also fetch the llm-d-router CRDs (InferenceObjective,
#                                                   InferenceModelRewrite) for flow-control priorities
#   LWS_CHART=1 [LWS_VERSION=1.0.0]                 also bundle LeaderWorkerSet (P/D, wide-EP): its chart into
#                                                   .cache/charts/lws-<v>/, its image into the lock and mirror
#                                                   list; install it air-gapped with ./install-lws.sh
#   OUT=dist                                        where the tarball and mirror list go
#   BUNDLE_STEPS='sources images'                   which half to run (default: both)
#
# Result in $OUT:
#   llm-d-bundle-<llmd sha>-<date>.tar.gz   this directory, including .cache/:
#     .cache/llm-d-<sha>/              pinned llm-d guides
#     .cache/charts/<chart>-<version>/ router helm charts
#     .cache/crds/                     InferencePool CRDs (+ llm-d-router.yaml with ROUTER_CRDS=1)
#     .cache/charts/lws-<v>/           LeaderWorkerSet chart + CRDs (LWS_CHART=1)
#     .cache/images.lock               "<image> <digest>" for every image the profiles use
#   images-to-mirror.tsv                "<repo>@<digest> <tab> <target in your registry> <tab> <original>" per image:
#                                       copy each image from the first column to the second with your own tooling
# Model weights are not handled here: the garuda repo stores them in gs://models_registry.
# Inside the air gap: unpack, load the same env (envs/<env>.env), run ./deploy.sh as usual.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# shellcheck source=lib/images.sh
source lib/images.sh
# header comment above `set -euo pipefail`, without the leading "# "
[[ ${1:-} != -h && ${1:-} != --help ]] || { sed -n '2,/^set -euo pipefail/{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0; }
# shellcheck source=lib/env.sh
source "$(dirname "$0")/lib/env.sh"
env_args "$@"; set -- ${ARGS[@]+"${ARGS[@]}"}   # --env-file / -e anywhere: load + check; ARGS = the rest

PROFILES=("$@"); [[ ${#PROFILES[@]} -gt 0 ]] || PROFILES=(profiles/*.yaml)
IMAGE_REGISTRY=${IMAGE_REGISTRY:-}
OUT=${OUT:-dist}
INFERENCE_CRDS_URL=${INFERENCE_CRDS_URL:-https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/v1-manifests.yaml}
ROUTER_CRDS=${ROUTER_CRDS:-}
ROUTER_CRDS_URL=${ROUTER_CRDS_URL:-https://github.com/llm-d/llm-d-router/releases/download/v1.0.0/manifests.yaml}
LWS_CHART=${LWS_CHART:-}
LWS_VERSION=${LWS_VERSION:-1.0.0}
LWS_DIR=.cache/charts/lws-$LWS_VERSION
BUNDLE_STEPS=${BUNDLE_STEPS:-sources images}
step() { [[ " $BUNDLE_STEPS " == *" $1 "* ]]; }
step sources || step images || die "BUNDLE_STEPS must contain 'sources' and/or 'images', got '$BUNDLE_STEPS'"
# settings of the first profile (llm-d ref for the tarball name, smoke-test image)
eval "$(./deploy.sh "${PROFILES[0]}" --env)"

# ---- 1. render every profile: fetches llm-d + charts into .cache/, renders into .build/ ----
# Images are collected from these renders; deploy.sh re-renders inside with the real settings.
# With a .cache/ from the sources step this needs no network (a missing piece fails with a hint).
for p in "${PROFILES[@]}"; do
  log "rendering $p"
  IMAGE_REGISTRY= IMAGE_REMOTES= ./deploy.sh "$p" --dry-run >/dev/null   # upstream image names
done

if step sources; then
  mkdir -p .cache/crds
  log "fetching InferencePool CRDs"
  curl -fsSL "$INFERENCE_CRDS_URL" -o .cache/crds/inference-extension-v1.yaml
  if [[ -n $ROUTER_CRDS ]]; then
    log "fetching llm-d-router CRDs"
    curl -fsSL "$ROUTER_CRDS_URL" -o .cache/crds/llm-d-router.yaml
    # CRDs only: anything else would carry images that are not in the lock
    [[ $(yq -N '.kind' .cache/crds/llm-d-router.yaml | grep -v '^---$' | sort -u) == CustomResourceDefinition ]] ||
      die "$ROUTER_CRDS_URL holds more than CRDs"
  fi
  if [[ -n $LWS_CHART ]]; then
    log "pulling LeaderWorkerSet chart $LWS_VERSION"
    rm -rf "$LWS_DIR.tmp"; mkdir -p "$LWS_DIR.tmp"
    helm pull oci://registry.k8s.io/lws/charts/lws --version "$LWS_VERSION" --untar --untardir "$LWS_DIR.tmp" >/dev/null ||
      die "cannot pull the LWS chart $LWS_VERSION"
    rm -rf "$LWS_DIR"; mv "$LWS_DIR.tmp/lws" "$LWS_DIR"; rm -rf "$LWS_DIR.tmp"
  fi
fi

if ! step images; then
  mkdir -p "$OUT"
  TAR=$OUT/llm-d-sources-${LLMD_REF:0:7}-$(date +%Y%m%d).tar.gz
  log "packing $TAR"
  tar -czf "$TAR" --exclude="./$OUT" --exclude='./.git' --exclude='./.build' -C "$ROOT" .
  log "done: $TAR; on the registry machine: unpack into pipeline/, then BUNDLE_STEPS=images ./bundle.sh"
  exit 0
fi
[[ -f .cache/crds/inference-extension-v1.yaml ]] || die "no .cache/crds/: run BUNDLE_STEPS=sources ./bundle.sh first and unpack its tarball here"
[[ -z $ROUTER_CRDS || -f .cache/crds/llm-d-router.yaml ]] || die "ROUTER_CRDS=1 but no .cache/crds/llm-d-router.yaml: run the sources step with ROUTER_CRDS=1"
[[ -z $LWS_CHART || -f $LWS_DIR/Chart.yaml ]] || die "LWS_CHART=1 but no $LWS_DIR: run the sources step with LWS_CHART=1"

# ---- 2. lock image digests ------------------------------------------------------------------
IMAGES=$( { for p in "${PROFILES[@]}"; do n=$(./deploy.sh "$p" --name)
              yq -N '.. | select(tag == "!!map" and has("image")) | .image' ".build/$n/modelserver.yaml" ".build/$n/router.yaml"; done
            echo "$SMOKE_IMAGE"
            [[ -z $LWS_CHART ]] || helm template lws "$LWS_DIR" --set enableDisaggregatedSet=true |
              yq -N '.. | select(tag == "!!map" and has("image")) | .image'
          } | grep -v '^$' | while read -r i; do norm_image "$i"; done | sort -u)

# docker buildx when it is real Docker (uses your docker login / mirrors); if that fails (podman's `docker`
# has no `buildx imagetools`, or no docker at all), ask the registry directly with curl (public images).
digest() {
  local d
  d=$(docker buildx imagetools inspect "$1" --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"') && [[ $d == sha256:* ]] &&
    echo "$d" || registry_digest "$1"
}
log "resolving $(wc -l <<<"$IMAGES" | tr -d ' ') image digests"
: > .cache/images.lock.tmp
while read -r img; do
  d=$(digest "$img") || die "cannot resolve $img"
  [[ $d == sha256:* ]] || die "unexpected digest for $img: $d"
  echo "$img $d" >> .cache/images.lock.tmp
done <<<"$IMAGES"
# merge with an existing lock so bundling a subset of profiles keeps the other entries
touch .cache/images.lock
cat .cache/images.lock.tmp .cache/images.lock | awk '!seen[$1]++' | sort > .cache/images.lock.new   # new entries win
mv .cache/images.lock.new .cache/images.lock; rm -f .cache/images.lock.tmp

# ---- 3. mirror list: every locked image (all profiles bundled so far), in deploy.sh's layout ----
mkdir -p "$OUT"
REG_FOR_LIST=${IMAGE_REGISTRY:-<IMAGE_REGISTRY>}
# columns: copy FROM (repo@digest: every tool accepts it, unlike repo:tag@digest) / copy TO / original reference
# Images from hosts in IMAGE_REMOTES are pulled through Artifact Registry remote repos: nothing to copy.
{ printf 'SOURCE\tTARGET\tORIGINAL\n'
  while read -r img d; do
    [[ -z $(image_remote "${img%%/*}") ]] || continue
    r=${img%@*}; [[ ${r##*/} == *:* ]] && r=${r%:*}
    printf '%s@%s\t%s\t%s\n' "$r" "$d" "$(IMAGE_REGISTRY=$REG_FOR_LIST image_target "$img" "$d")" "$img"
  done < .cache/images.lock
} > "$OUT/images-to-mirror.tsv"
# a collision is one target fed by two different sources (same image under two tags is fine)
dups=$(tail -n +2 "$OUT/images-to-mirror.tsv" | cut -f1,2 | sort -u | cut -f2 | sort | uniq -d)
[[ -z $dups ]] || die "IMAGE_TEMPLATE maps different images to the same target: $(echo $dups); include {path} or {host}"
log "mirror list: $OUT/images-to-mirror.tsv ($(($(wc -l < "$OUT/images-to-mirror.tsv") - 1)) images to copy, template $IMAGE_TEMPLATE${IMAGE_REMOTES:+; the rest pull through IMAGE_REMOTES})"

# ---- 4. pack --------------------------------------------------------------------------------
TAR=$OUT/llm-d-bundle-${LLMD_REF:0:7}-$(date +%Y%m%d).tar.gz
log "packing $TAR"
tar -czf "$TAR" --exclude="./$OUT" --exclude='./.git' -C "$ROOT" .
log "done: $TAR ($(du -h "$TAR" | cut -f1)); copy the images per $OUT/images-to-mirror.tsv"
