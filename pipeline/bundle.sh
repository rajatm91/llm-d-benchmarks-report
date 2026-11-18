#!/usr/bin/env bash
# Prepare everything an air-gapped deploy needs. Run on a machine WITH internet access.
#
#   ./bundle.sh                                   # all profiles
#   ./bundle.sh profiles/a.yaml profiles/b.yaml   # only these profiles
#
# Optional environment:
#   IMAGE_REGISTRY=us-docker.pkg.dev/<proj>/<repo>  your registry (fills the target column of the mirror list)
#   IMAGE_TEMPLATE='{registry}/{name}:{tag}'        how images are laid out in it (see lib/images.sh); must be
#                                                   the same value deploy.sh gets inside the air gap
#   IMAGE_REMOTES='docker.io=<repo> ghcr.io=<repo>' Artifact Registry remote repos per upstream host: those
#                                                   images are pulled through, so they stay off the mirror list
#   ROUTER_CRDS=1                                   also fetch the llm-d-router CRDs (InferenceObjective,
#                                                   InferenceModelRewrite) for flow-control priorities
#   OUT=dist                                        where the tarball and mirror list go
#
# Result in $OUT:
#   llm-d-bundle-<llmd sha>-<date>.tar.gz   this directory, including .cache/:
#     .cache/llm-d-<sha>/              pinned llm-d guides
#     .cache/charts/<chart>-<version>/ router helm charts
#     .cache/crds/                     InferencePool CRDs (+ llm-d-router.yaml with ROUTER_CRDS=1)
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

PROFILES=("$@"); [[ ${#PROFILES[@]} -gt 0 ]] || PROFILES=(profiles/*.yaml)
IMAGE_REGISTRY=${IMAGE_REGISTRY:-}
OUT=${OUT:-dist}
INFERENCE_CRDS_URL=${INFERENCE_CRDS_URL:-https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/v1-manifests.yaml}
ROUTER_CRDS=${ROUTER_CRDS:-}
ROUTER_CRDS_URL=${ROUTER_CRDS_URL:-https://github.com/llm-d/llm-d-router/releases/download/v1.0.0/manifests.yaml}
# settings of the first profile (llm-d ref for the tarball name, smoke-test image)
eval "$(./deploy.sh "${PROFILES[0]}" --env)"

# ---- 1. render every profile: fetches llm-d + charts into .cache/, renders into .build/ ----
# Images are collected from these renders; deploy.sh re-renders inside with the real settings.
for p in "${PROFILES[@]}"; do
  log "rendering $p"
  IMAGE_REGISTRY= IMAGE_REMOTES= ./deploy.sh "$p" --dry-run >/dev/null   # upstream image names
done

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

# ---- 2. lock image digests ------------------------------------------------------------------
IMAGES=$( { for p in "${PROFILES[@]}"; do n=$(./deploy.sh "$p" --name)
              yq -N '.. | select(tag == "!!map" and has("image")) | .image' ".build/$n/modelserver.yaml" ".build/$n/router.yaml"; done
            echo "$SMOKE_IMAGE"
          } | grep -v '^$' | while read -r i; do norm_image "$i"; done | sort -u)

docker buildx version >/dev/null 2>&1 || die "need docker buildx to resolve image digests"
digest() { docker buildx imagetools inspect "$1" --format '{{json .Manifest.Digest}}' | tr -d '"'; }
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
