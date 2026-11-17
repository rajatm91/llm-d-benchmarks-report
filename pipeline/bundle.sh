#!/usr/bin/env bash
# Prepare everything an air-gapped deploy needs. Run on a machine WITH internet access.
#
#   ./bundle.sh                                   # all profiles: fill .cache/ + .build/, lock image digests, pack tarball
#   ./bundle.sh profiles/a.yaml profiles/b.yaml   # only these profiles
#
# Optional environment:
#   IMAGE_REGISTRY=us-docker.pkg.dev/<proj>/<repo>  also copy every image there (crane, gcrane, skopeo or docker buildx)
#   MODEL_BUCKET=gs://<bucket>                      also upload every profile's model (+ draft) weights there
#                                                   (needs hf + gcloud; skips models already uploaded)
#   OUT=dist                                        where the tarball goes
#
# Result: dist/llm-d-bundle-<llmd sha>-<date>.tar.gz with this directory, including .cache/:
#   .cache/llm-d-<sha>/              pinned llm-d guides
#   .cache/charts/<chart>-<version>/ router helm charts
#   .cache/crds/                     InferencePool CRDs
#   .cache/images.lock               "<image> <digest>" for every image the profiles use
#   .build/<name>/                   rendered manifests (for review; deploy.sh re-renders on the inside)
# Inside the air gap: unpack, export IMAGE_REGISTRY (and MODEL_BUCKET), run ./deploy.sh as usual.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
PROFILES=("$@"); [[ ${#PROFILES[@]} -gt 0 ]] || PROFILES=(profiles/*.yaml)
IMAGE_REGISTRY=${IMAGE_REGISTRY:-}; IMAGE_REGISTRY=${IMAGE_REGISTRY%/}
MODEL_BUCKET=${MODEL_BUCKET:-}; MODEL_BUCKET=${MODEL_BUCKET%/}
OUT=${OUT:-dist}
INFERENCE_CRDS_URL=${INFERENCE_CRDS_URL:-https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/v1-manifests.yaml}

# ---- 1. render every profile: fetches llm-d + charts into .cache/, renders into .build/ ----
# Render in bucket mode so the fetch-model init image is part of the image set. Images are
# collected from these renders; deploy.sh re-renders inside with the real settings.
for p in "${PROFILES[@]}"; do
  log "rendering $p"
  MODEL_BUCKET=${MODEL_BUCKET:-gs://bundle-placeholder} IMAGE_REGISTRY= ./deploy.sh "$p" --dry-run >/dev/null
done

mkdir -p .cache/crds
log "fetching InferencePool CRDs"
curl -fsSL "$INFERENCE_CRDS_URL" -o .cache/crds/inference-extension-v1.yaml

# ---- 2. lock image digests (and mirror) --------------------------------------------------
norm_image() { local i=$1 h=${1%%/*}; [[ $i == */* && ( $h == *.* || $h == *:* || $h == localhost ) ]] || { [[ $i == */* ]] && i=docker.io/$i || i=docker.io/library/$i; }; echo "$i"; }
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
  if [[ -n $IMAGE_REGISTRY ]]; then
    repo=${img%@*}; [[ ${repo##*/} == *:* ]] && repo=${repo%:*}
    tag=${img##*/}; [[ $tag == *:* && $img != *@* ]] && tag=${tag##*:} || tag=bundled
    log "copying $img -> $IMAGE_REGISTRY/$repo:$tag"
    copy "${img%@*}@$d" "$IMAGE_REGISTRY/$repo:$tag" >/dev/null   # tag too, so the mirror is browsable; deploy pins @digest
  fi
done <<<"$IMAGES"
# merge with an existing lock so bundling a subset of profiles keeps the other entries
touch .cache/images.lock
cat .cache/images.lock.tmp .cache/images.lock | awk '!seen[$1]++' | sort > .cache/images.lock.new   # new entries win
mv .cache/images.lock.new .cache/images.lock; rm -f .cache/images.lock.tmp

# ---- 3. model weights (optional) -----------------------------------------------------------
if [[ -n $MODEL_BUCKET ]]; then
  command -v gcloud >/dev/null || die "MODEL_BUCKET set but gcloud is missing"
  if command -v hf >/dev/null; then HF=(hf); else HF=(uvx --from huggingface_hub hf); fi
  MODELS=$(for p in "${PROFILES[@]}"; do eval "$(./deploy.sh "$p" --env)"; echo "$MODEL"; [[ -z $DRAFT_MODEL ]] || echo "$DRAFT_MODEL"; done | sort -u)
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  while read -r m; do
    if gcloud storage ls "$MODEL_BUCKET/$m/config.json" >/dev/null 2>&1; then log "weights present: $MODEL_BUCKET/$m"; continue; fi
    log "uploading $m -> $MODEL_BUCKET/$m"
    "${HF[@]}" download "$m" --local-dir "$TMP/$m" --exclude ".cache/*" >/dev/null
    gcloud storage rsync --recursive "$TMP/$m" "$MODEL_BUCKET/$m"
    rm -rf "${TMP:?}/$m"
  done <<<"$MODELS"
fi

# ---- 4. pack -------------------------------------------------------------------------------
mkdir -p "$OUT"
REF=$(yq -N '.llmdRef // ""' "${PROFILES[0]}"); REF=${REF:-$(sed -n 's/^LLMD_REF=\([0-9a-f]*\).*/\1/p' deploy.sh)}
TAR=$OUT/llm-d-bundle-${REF:0:7}-$(date +%Y%m%d).tar.gz
log "packing $TAR"
tar -czf "$TAR" --exclude="./$OUT" --exclude='./.git' -C "$ROOT" .
log "done: $TAR ($(du -h "$TAR" | cut -f1)); images locked in .cache/images.lock$([[ -n $IMAGE_REGISTRY ]] && echo ", mirrored to $IMAGE_REGISTRY")"
