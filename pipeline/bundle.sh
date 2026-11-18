#!/usr/bin/env bash
# Prepare everything an air-gapped deploy needs. Run on a machine WITH internet access.
#
#   ./bundle.sh                                   # all profiles: fill .cache/ + .build/, lock image digests, pack tarball
#   ./bundle.sh profiles/a.yaml profiles/b.yaml   # only these profiles
#
# Optional environment:
#   IMAGE_REGISTRY=us-docker.pkg.dev/<proj>/<repo>  your registry (fills the target column of the mirror list)
#   IMAGE_TEMPLATE='{registry}/{name}:{tag}'        how images are laid out in it (see lib/images.sh); must be
#                                                   the same value deploy.sh gets inside the air gap
#   PUSH_IMAGES=1                                   also copy the images there (needs push access; crane, gcrane,
#                                                   skopeo or docker buildx). Default: only write the mirror list.
#   OUT=dist                                        where the tarball and mirror list go
#
# Result: dist/llm-d-bundle-<llmd sha>-<date>.tar.gz with this directory, including .cache/:
#   .cache/llm-d-<sha>/              pinned llm-d guides
#   .cache/charts/<chart>-<version>/ router helm charts
#   .cache/crds/                     InferencePool CRDs
#   .cache/images.lock               "<image> <digest>" for every image the profiles use
#   .build/<name>/                   rendered manifests (for review; deploy.sh re-renders on the inside)
# and dist/images-to-mirror.tsv: "<repo>@<digest> <tab> <target in your registry> <tab> <original>" per image,
# to copy into GAR with your own tooling.
# Model weights are not handled here: the garuda repo downloads them into gs://models_registry.
# Inside the air gap: unpack, export IMAGE_REGISTRY, run ./deploy.sh as usual.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
PROFILES=("$@"); [[ ${#PROFILES[@]} -gt 0 ]] || PROFILES=(profiles/*.yaml)
IMAGE_REGISTRY=${IMAGE_REGISTRY:-}; IMAGE_REGISTRY=${IMAGE_REGISTRY%/}
PUSH_IMAGES=${PUSH_IMAGES:-}
# shellcheck source=lib/images.sh
source lib/images.sh
[[ -z $PUSH_IMAGES || -n $IMAGE_REGISTRY ]] || die "PUSH_IMAGES=1 needs IMAGE_REGISTRY"
OUT=${OUT:-dist}
INFERENCE_CRDS_URL=${INFERENCE_CRDS_URL:-https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/v1-manifests.yaml}

# ---- 1. render every profile: fetches llm-d + charts into .cache/, renders into .build/ ----
# Images are collected from these renders; deploy.sh re-renders inside with the real settings.
for p in "${PROFILES[@]}"; do
  log "rendering $p"
  IMAGE_REGISTRY= ./deploy.sh "$p" --dry-run >/dev/null
done

mkdir -p .cache/crds
log "fetching InferencePool CRDs"
curl -fsSL "$INFERENCE_CRDS_URL" -o .cache/crds/inference-extension-v1.yaml

# ---- 2. lock image digests, write the mirror list (optionally push) --------------------------
IMAGES=$( { for p in "${PROFILES[@]}"; do n=$(./deploy.sh "$p" --name)
              yq -N '.. | select(tag == "!!map" and has("image")) | .image' ".build/$n/modelserver.yaml" ".build/$n/router.yaml"; done
            echo "${SMOKE_IMAGE:-docker.io/curlimages/curl:8.11.1}"
          } | grep -v '^$' | while read -r i; do norm_image "$i"; done | sort -u)

if command -v crane >/dev/null; then T=crane; elif command -v gcrane >/dev/null; then T=gcrane
elif command -v skopeo >/dev/null; then T=skopeo; elif docker buildx version >/dev/null 2>&1; then T=buildx
else die "need one of crane, gcrane, skopeo or docker buildx to resolve/copy images"; fi
digest() {
  case $T in
    crane|gcrane) "$T" digest "$1" ;;
    skopeo) skopeo inspect --format '{{.Digest}}' "docker://$1" ;;
    buildx) docker buildx imagetools inspect "$1" --format '{{json .Manifest.Digest}}' | tr -d '"' ;;
  esac
}
copy() {   # multi-arch aware copy of $1 (by digest) to $2
  case $T in
    crane|gcrane) "$T" copy "$1" "$2" ;;
    skopeo) skopeo copy --all "docker://$1" "docker://$2" ;;
    buildx) docker buildx imagetools create -t "$2" "$1" ;;
  esac
}
log "resolving $(wc -l <<<"$IMAGES" | tr -d ' ') image digests with $T"
: > .cache/images.lock.tmp
while read -r img; do
  d=$(digest "$img") || die "cannot resolve $img"
  [[ $d == sha256:* ]] || die "unexpected digest for $img: $d"
  echo "$img $d" >> .cache/images.lock.tmp
  if [[ -n $PUSH_IMAGES ]]; then
    dst=$(image_target "$img" "$d"); dst=${dst%@*}             # push by tag; the digest is kept by the copy
    [[ ${dst##*/} == *:* ]] || dst=$dst:$(IMAGE_TEMPLATE='{tag}' image_target "$img" "$d")   # template without {tag}
    log "copying $img -> $dst"
    copy "${img%@*}@$d" "$dst" >/dev/null
  fi
done <<<"$IMAGES"
# merge with an existing lock so bundling a subset of profiles keeps the other entries
touch .cache/images.lock
cat .cache/images.lock.tmp .cache/images.lock | awk '!seen[$1]++' | sort > .cache/images.lock.new   # new entries win
mv .cache/images.lock.new .cache/images.lock; rm -f .cache/images.lock.tmp

# mirror list for every locked image (all profiles bundled so far), in the layout deploy.sh will use
mkdir -p "$OUT"
REG_FOR_LIST=${IMAGE_REGISTRY:-<IMAGE_REGISTRY>}
# columns: copy FROM (repo@digest: every tool accepts it, unlike repo:tag@digest) / copy TO / original reference
{ printf 'SOURCE\tTARGET\tORIGINAL\n'
  while read -r img d; do
    r=${img%@*}; [[ ${r##*/} == *:* ]] && r=${r%:*}
    printf '%s@%s\t%s\t%s\n' "$r" "$d" "$(IMAGE_REGISTRY=$REG_FOR_LIST image_target "$img" "$d")" "$img"
  done < .cache/images.lock
} > "$OUT/images-to-mirror.tsv"
dups=$(tail -n +2 "$OUT/images-to-mirror.tsv" | cut -f2 | sed 's/@.*//' | sort | uniq -d)
[[ -z $dups ]] || die "IMAGE_TEMPLATE maps different images to the same target: $(echo $dups); include {path} or {host}"
log "mirror list: $OUT/images-to-mirror.tsv ($(($(wc -l < "$OUT/images-to-mirror.tsv") - 1)) images, template $IMAGE_TEMPLATE)"

# ---- 3. pack -------------------------------------------------------------------------------
REF=$(yq -N '.llmdRef // ""' "${PROFILES[0]}"); REF=${REF:-$(sed -n 's/^LLMD_REF=\([0-9a-f]*\).*/\1/p' deploy.sh)}
TAR=$OUT/llm-d-bundle-${REF:0:7}-$(date +%Y%m%d).tar.gz
log "packing $TAR"
tar -czf "$TAR" --exclude="./$OUT" --exclude='./.git' -C "$ROOT" .
log "done: $TAR ($(du -h "$TAR" | cut -f1)); images locked in .cache/images.lock$([[ -n $PUSH_IMAGES ]] && echo ", copied to $IMAGE_REGISTRY" || echo "; copy them per $OUT/images-to-mirror.tsv")"
