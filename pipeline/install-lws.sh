#!/usr/bin/env bash
# Install LeaderWorkerSet (needed by P/D and wide-EP profiles) from the bundle. No network needed.
#
#   ./install-lws.sh --env-file dev             # CRDs + helm upgrade --install into lws-system
#   ./install-lws.sh --env-file dev --dry-run   # print the image and commands, change nothing
#   ./install-lws.sh --help                     # this text
#
# Needs .cache/charts/lws-<LWS_VERSION>/ and the LWS image in .cache/images.lock: run
# `LWS_CHART=1 ./bundle.sh ...` on the connected side. The image is mapped like every other image:
# through IMAGE_REMOTES (add registry.k8s.io=<remote repo>) or into IMAGE_REGISTRY per IMAGE_TEMPLATE,
# pinned to the locked digest. With neither set, the chart's upstream image is used (connected clusters).
# Installs with enableDisaggregatedSet=true (the P/D profiles use DisaggregatedSet). Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD; LIB=$ROOT/lib
log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
[[ ${1:-} != -h && ${1:-} != --help ]] || { sed -n '2,/^set -euo pipefail/{/^set /d;s/^# \{0,1\}//;p;}' "$0"; exit 0; }
# shellcheck source=lib/env.sh
source lib/env.sh
env_args "$@"; set -- ${ARGS[@]+"${ARGS[@]}"}
DRY=""; [[ $# -eq 0 ]] || [[ $# -eq 1 && $1 == --dry-run ]] && DRY=${1:-} || die "usage: ./install-lws.sh [--env-file <env>] [--dry-run]"
# shellcheck source=lib/images.sh
source lib/images.sh
# shellcheck source=lib/render.sh
source lib/render.sh    # mirror_image: the same lock lookup + mapping deploy.sh uses

LWS_VERSION=${LWS_VERSION:-1.0.0}
IMAGE_REGISTRY=${IMAGE_REGISTRY:-}
DIR=.cache/charts/lws-$LWS_VERSION
[[ -f $DIR/Chart.yaml ]] || die "no $DIR: run LWS_CHART=1 ./bundle.sh on the connected side and unpack its tarball here"
SET=(--set enableDisaggregatedSet=true)

img=$(helm template lws "$DIR" "${SET[@]}" | yq -N '.. | select(tag == "!!map" and has("image")) | .image' | sort -u)
[[ $(wc -l <<<"$img") -eq 1 ]] || die "expected one image in the LWS chart, got: $(echo $img)"
if [[ -n $IMAGE_REGISTRY || -n $IMAGE_REMOTES ]]; then
  t=$(mirror_image "$img") || exit 1
  # chart renders "<repository>:<tag>"; keep a digest as "<tag>@sha256:..." (the runtime pulls by digest)
  if [[ $t == *@* ]]; then
    base=${t%@*}; dig=${t#*@}
    if [[ ${base##*/} == *:* ]]; then repo=${base%:*}; tag=${base##*:}@$dig; else repo=$base; tag=${img##*:}@$dig; fi
  else
    repo=${t%:*}; tag=${t##*:}
  fi
  SET+=(--set "image.manager.repository=$repo" --set "image.manager.tag=$tag")
  log "LWS $LWS_VERSION image: $img -> $repo:$tag"
else
  log "LWS $LWS_VERSION image: $img (no IMAGE_REMOTES / IMAGE_REGISTRY: upstream)"
fi

CRDS=(kubectl apply --server-side --force-conflicts -f "$DIR/crds")
HELM=(helm upgrade --install lws "$DIR" --namespace lws-system --create-namespace "${SET[@]}" --wait --timeout 300s)
if [[ -n $DRY ]]; then
  printf '%q ' "${CRDS[@]}"; echo
  printf '%q ' "${HELM[@]}"; echo
  exit 0
fi
log "cluster: kubectl context $(kubectl config current-context 2>/dev/null || echo '<none>') (KUBECONFIG=${KUBECONFIG:-~/.kube/config})"
log "applying LWS CRDs"; "${CRDS[@]}"
log "installing LWS into lws-system"; "${HELM[@]}"
kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io disaggregatedsets.disaggregatedset.x-k8s.io >/dev/null
log "done: $(kubectl -n lws-system get deploy -o jsonpath='{range .items[*]}{.metadata.name} {.status.readyReplicas}/{.spec.replicas}{"\n"}{end}')"
