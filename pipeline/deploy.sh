#!/usr/bin/env bash
# Reusable llm-d deploy pipeline.
#
#   ./deploy.sh profiles/<name>.yaml            # render + deploy + wait + smoke test
#   ./deploy.sh profiles/<name>.yaml --dry-run  # render only (no cluster needed), output in .build/<name>/
#   ./deploy.sh profiles/<name>.yaml --delete   # tear down router + model servers
#   ./deploy.sh profiles/<name>.yaml --name     # print the derived deployment name
#   ./deploy.sh profiles/<name>.yaml --env      # print the resolved settings as shell assignments
#   ./deploy.sh profiles/<name>.yaml --kv-cache # print modelserver.kvCache measured from the running pods' vLLM logs
#   ./deploy.sh --help                          # this text
#
# Load the environment settings with --env-file (or -e), anywhere on the line:
#   ./deploy.sh --env-file dev profiles/<name>.yaml   # envs/dev.env; a path works too
# The file wins over the shell; names that are not settings (typos) stop the run.
#
# A profile (profiles/*.yaml, every field in docs/configuration.md) picks an upstream llm-d
# model-server overlay plus optional components/patches, the router values, and the Gateway.
# Environment-wide settings (namespace, ServiceAccount, bucket, registry) come from the
# environment: see envs/example.env and lib/profile.sh.
#
# Code: lib/profile.sh (settings), lib/render.sh (render steps; YAML edits in lib/yq/*.yq),
# lib/cluster.sh (preflight, apply, wait, smoke test), lib/images.sh (air-gap image names).
set -euo pipefail

# header comment above `set -euo pipefail`, without the leading "# "
help() { sed -n '2,/^set -euo pipefail/{/^set /d;s/^# \{0,1\}//;p;}' "$0"; }
usage() { help >&2; exit 1; }
log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ ${1:-} != -h && ${1:-} != --help ]] || { help; exit 0; }
# shellcheck source=lib/env.sh
source "$(dirname "$0")/lib/env.sh"
env_args "$@"; set -- ${ARGS[@]+"${ARGS[@]}"}   # --env-file / -e anywhere: load + check; ARGS = the rest
[[ $# -ge 1 && $# -le 2 ]] || usage
MODE=${2:-deploy}
[[ $MODE =~ ^(deploy|--dry-run|--delete|--name|--env|--kv-cache)$ ]] || usage
PROFILE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
ROOT=$(cd "$(dirname "$0")" && pwd)
LIB=$ROOT/lib
# shellcheck source=lib/profile.sh
source "$LIB/profile.sh"
# shellcheck source=lib/render.sh
source "$LIB/render.sh"
# shellcheck source=lib/cluster.sh
source "$LIB/cluster.sh"
# shellcheck source=lib/images.sh
source "$LIB/images.sh"

load_profile
case $MODE in
  --name) echo "$NAME"; exit 0 ;;
  --env)  print_env;    exit 0 ;;
  --kv-cache) kv_cache_report; exit 0 ;;
esac

LLMD=$ROOT/.cache/llm-d-$LLMD_REF     # pinned llm-d checkout (guides/)
BUILD=$ROOT/.build/$NAME
MS=$BUILD/modelserver.yaml
ROUTER=$BUILD/router.yaml

# ---- render ----
fetch_llmd
render_modelservers    # overlay + components + patches
share_namespace        # unique names and labels, so models can share one namespace
set_vllm_image         # modelserver.image
swap_model             # profile model instead of the overlay's
set_size               # modelserver.tensorParallel / replicas
add_vllm_args          # modelserver.args + speculative decoding
add_weights_fetch      # init container: weights from GCS to the node, vLLM offline
add_vllm_monitoring    # MONITORING=gmp: PodMonitoring for the vLLM pods
render_router          # chart + values, pool selects only this deployment
mirror_images          # air-gapped: every image -> IMAGE_REGISTRY

case $MODE in
  --dry-run) log "rendered to $BUILD/{modelserver,router}.yaml"; exit 0 ;;
esac
log "cluster: kubectl context $(kubectl config current-context 2>/dev/null || echo '<none>') (KUBECONFIG=${KUBECONFIG:-~/.kube/config}), namespace $NAMESPACE"
[[ $MODE != --delete ]] || { delete_all; exit 0; }

# ---- deploy ----
preflight
apply_all
wait_ready
smoke_test
kv_cache_report        # measured modelserver.kvCache, to copy into the profile
