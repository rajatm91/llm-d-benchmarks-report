#!/usr/bin/env bash
# Reusable llm-d deploy pipeline.
#
#   ./deploy.sh profiles/<name>.yaml            # render + deploy + wait + smoke test
#   ./deploy.sh profiles/<name>.yaml --dry-run  # render only (no cluster needed), output in .build/<name>/
#   ./deploy.sh profiles/<name>.yaml --delete   # tear down router + model servers
#   ./deploy.sh profiles/<name>.yaml --name     # print the derived deployment name
#   ./deploy.sh profiles/<name>.yaml --env      # print the resolved settings as shell assignments
#
# A profile (YAML, schema in README / profiles/*.yaml) picks one upstream llm-d model-server
# overlay, optional kustomize components/patches layered on it (this is how strategies are
# combined), the router values to layer, and the existing Gateway to attach to.
#
# Environment-wide settings come from the environment (Jenkins): NAMESPACE, SERVICE_ACCOUNT,
# MODEL_BUCKET, MODEL_CACHE_PATH, DOWNLOADER_IMAGE, IMAGE_REGISTRY. Every model shares one namespace and
# one pre-existing ServiceAccount; all resources are named <model>-<strategy>-<engine>.
set -euo pipefail

usage() { sed -n 2,16p "$0" >&2; exit 1; }
[[ $# -ge 1 ]] || usage
PROFILE=$1; MODE=${2:-deploy}
ROOT=$(cd "$(dirname "$0")" && pwd)
PROFILE=$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")

# ---- defaults (profiles override) -------------------------------------------
LLMD_REF=565373b741e90bffa27930b4669c6e1f222f6225   # llm-d/llm-d commit these profiles were written against
ROUTER_CHART_VERSION=v0
ROUTER_GATEWAY_CHART=oci://ghcr.io/llm-d/charts/llm-d-router-gateway
ROUTER_STANDALONE_CHART=oci://ghcr.io/llm-d/charts/llm-d-router-standalone
ROUTER_MODE=gateway            # gateway | standalone
GATEWAY_NAME=llm-d-inference-gateway
GATEWAY_NAMESPACE=""           # "" = same namespace as the deployment
GATEWAY_PROVIDER=none          # gke | agentgateway | istio | none  (selects HealthCheckPolicy / DestinationRule)
BASE_MODEL=""                  # set when several models share one Gateway (needs IPP, see README)
COMPONENTS=""; PATCHES=""; ROUTER_VALUES=""; ROUTER_SET=""
WAIT_TIMEOUT=60m
NAMESPACE=${NAMESPACE:-llm-d}                           # shared by every model (override from env / Jenkins)
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-llm-d-modelserver}   # pre-existing in NAMESPACE; model-server pods run as it
NAME_TEMPLATE='{model}-{strategy}-{engine}'
MODEL_ALIAS=""                 # short model slug when the HF name makes NAME too long
ENGINE=""                      # "" = inferred from MODELSERVER_OVERLAY (vllm | sglang | trtllm)
# Weights are already in GCS (downloaded and stored by the garuda repo), one folder per model:
#   gs://models_registry/<org>__<name>  with the HF id lowercased and other non-alphanumerics -> "_"
#   e.g. google/gemma-4-31B-it -> gs://models_registry/google__gemma_4_31b_it
# An init container copies it to node-local disk once per node; vLLM loads it offline.
MODEL_BUCKET=${MODEL_BUCKET:-gs://models_registry}      # env / Jenkins
MODEL_GCS_URI=""                                        # "" = $MODEL_BUCKET/<folder of MODEL>; weights.gcsUri overrides
MODEL_CACHE_PATH=${MODEL_CACHE_PATH:-/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models}  # hostPath (GKE local SSD)
DOWNLOADER_IMAGE=${DOWNLOADER_IMAGE:-gcr.io/google.com/cloudsdktool/google-cloud-cli:slim}
SMOKE_IMAGE=${SMOKE_IMAGE:-docker.io/curlimages/curl:8.11.1}
# Air-gapped: every image (model servers, router, init, smoke test) is rewritten into your registry:
# IMAGE_REGISTRY + IMAGE_TEMPLATE (default {registry}/{host}/{path}@{digest}; see lib/images.sh).
IMAGE_REGISTRY=${IMAGE_REGISTRY:-}                      # e.g. us-docker.pkg.dev/my-proj/llm-d
DRAFT_MODEL=""                                          # HF id of a draft / EAGLE model for speculative decoding
DRAFT_GCS_URI=""                                        # "" = $MODEL_BUCKET/<folder of DRAFT_MODEL>
SPEC_CONFIG='{"num_speculative_tokens": 5}'             # vLLM --speculative-config; "model" is filled from DRAFT_MODEL
MS_ARGS_JSON='[]'; MS_TP=""; MS_REPLICAS=""                # modelserver.args / tensorParallel / replicas
MS_IMAGE=""                                             # modelserver.image: replaces the overlay's vLLM image

log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- load profile (YAML -> the variables below) ----------------------------------
[[ -f $PROFILE ]] || die "profile not found: $PROFILE"
yq -e 'tag == "!!map"' "$PROFILE" >/dev/null 2>&1 || die "$PROFILE is not a YAML mapping"
# unknown keys are typos: fail instead of silently using a default
BAD=$(yq -N '(keys - ["model","modelAlias","strategy","engine","nameTemplate","draftModel","speculativeConfig",
                      "modelserver","router","gateway","weights","llmdRef","waitTimeout"])
  + ((.modelserver // {}) | keys - ["overlay","components","patches","args","tensorParallel","replicas","image"] | map("modelserver." + .))
  + ((.router // {}) | keys - ["mode","values","set","chartVersion"] | map("router." + .))
  + ((.gateway // {}) | keys - ["provider","name","namespace","baseModel"] | map("gateway." + .))
  + ((.weights // {}) | keys - ["gcsUri","draftGcsUri"] | map("weights." + .)) | .[]' "$PROFILE")
[[ -z $BAD ]] || die "unknown key(s) in $PROFILE: $(echo $BAD)"
# scalar -> var, list -> space-joined var, map -> JSON; absent keys keep the defaults above
eval "$(yq -N '
  [ ["MODEL", .model], ["MODEL_ALIAS", .modelAlias], ["STRATEGY", .strategy], ["ENGINE", .engine],
    ["NAME_TEMPLATE", .nameTemplate], ["DRAFT_MODEL", .draftModel],
    ["SPEC_CONFIG", (.speculativeConfig | select(. != null) | @json)],
    ["MODELSERVER_OVERLAY", .modelserver.overlay],
    ["COMPONENTS", (.modelserver.components | select(. != null) | join(" "))],
    ["PATCHES", (.modelserver.patches | select(. != null) | join(" "))],
    ["MS_ARGS_JSON", (.modelserver.args | select(. != null) | @json)],
    ["MS_TP", .modelserver.tensorParallel], ["MS_REPLICAS", .modelserver.replicas], ["MS_IMAGE", .modelserver.image],
    ["ROUTER_MODE", .router.mode], ["ROUTER_CHART_VERSION", .router.chartVersion],
    ["ROUTER_VALUES", (.router.values | select(. != null) | join(" "))],
    ["ROUTER_SET", (.router.set | select(. != null) | join(" "))],
    ["GATEWAY_PROVIDER", .gateway.provider], ["GATEWAY_NAME", .gateway.name],
    ["GATEWAY_NAMESPACE", .gateway.namespace], ["BASE_MODEL", .gateway.baseModel],
    ["MODEL_GCS_URI", .weights.gcsUri], ["DRAFT_GCS_URI", .weights.draftGcsUri],
    ["LLMD_REF", .llmdRef], ["WAIT_TIMEOUT", .waitTimeout] ]
  | .[] | select(.[1] != null) | .[0] + "=" + (.[1] | tostring | @sh)' "$PROFILE")"
# speculativeConfig needs either a draftModel or a self-contained method (mtp, ngram, ...)
[[ $(yq '.speculativeConfig != null and .draftModel == null and .speculativeConfig.method == null' "$PROFILE") == false ]] ||
  die "speculativeConfig needs draftModel, or a method that brings its own drafter (e.g. method: mtp)"
SPEC_SET=$(yq '.speculativeConfig != null' "$PROFILE")
: "${MODEL:?}" "${STRATEGY:?profile must set STRATEGY}" "${MODELSERVER_OVERLAY:?}"

# ---- naming standard ------------------------------------------------------------
slug() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }
MODEL_SLUG=$(slug "${MODEL_ALIAS:-${MODEL##*/}}")
STRATEGY=$(slug "$STRATEGY")
[[ -n $ENGINE ]] || ENGINE=$(grep -oE '/(vllm|sglang|trtllm)/' <<<"/$MODELSERVER_OVERLAY/" | head -1 | tr -d /) || true
[[ -n $ENGINE ]] || die "cannot infer ENGINE from $MODELSERVER_OVERLAY; set ENGINE in the profile"
NAME=$(sed "s/{model}/$MODEL_SLUG/g; s/{strategy}/$STRATEGY/g; s/{engine}/$ENGINE/g" <<<"$NAME_TEMPLATE")
# 40: helm release names cap at 53 and the chart/LWS append suffixes (-epp, -prefill-<hash>, ...)
[[ $NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#NAME} -le 40 ]] ||
  die "derived name '$NAME' must be a DNS label of at most 40 chars; set MODEL_ALIAS (or NAME_TEMPLATE)"
GATEWAY_NAMESPACE=${GATEWAY_NAMESPACE:-$NAMESPACE}
[[ $MODE == --name ]] && { echo "$NAME"; exit 0; }
if [[ $MODE == --env ]]; then
  for v in NAME NAMESPACE SERVICE_ACCOUNT MODEL STRATEGY ENGINE DRAFT_MODEL SPEC_CONFIG MODELSERVER_OVERLAY COMPONENTS PATCHES \
           ROUTER_MODE ROUTER_VALUES MS_TP MS_REPLICAS MS_ARGS_JSON MS_IMAGE SPEC_SET GATEWAY_PROVIDER GATEWAY_NAME GATEWAY_NAMESPACE BASE_MODEL MODEL_BUCKET LLMD_REF WAIT_TIMEOUT; do
    printf '%s=%q\n' "$v" "${!v}"; done
  exit 0
fi

LLMD=$ROOT/.cache/llm-d-$LLMD_REF
BUILD=$ROOT/.build/$NAME

# ---- 1. fetch pinned llm-d ----------------------------------------------------
# Everything fetched lands in .cache/, so a .cache/ copied from ./bundle.sh needs no network.
OFFLINE_HINT="no network? run ./bundle.sh on a connected machine and copy its .cache/ here"
if [[ ! -d $LLMD/guides ]]; then
  log "fetching llm-d@$LLMD_REF"
  rm -rf "$LLMD"; git init -q "$LLMD"
  git -C "$LLMD" fetch -q --depth 1 https://github.com/llm-d/llm-d.git "$LLMD_REF" || { rm -rf "$LLMD"; die "cannot fetch llm-d@$LLMD_REF; $OFFLINE_HINT"; }
  git -C "$LLMD" checkout -q FETCH_HEAD
fi

# ---- 2. render model servers: upstream overlay + components + patches ---------
rm -rf "$BUILD"; mkdir -p "$BUILD/overlay"
# Paths starting with guides/ are upstream llm-d files; anything else is relative to this pipeline.
abs() { case $1 in /*) echo "$1";; guides/*) echo "$LLMD/$1";; *) echo "$ROOT/$1";; esac; }
# kustomize refuses absolute resource/component paths
rel() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$(abs "$1")" "$BUILD/overlay"; }
{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources: [\"$(rel "$MODELSERVER_OVERLAY")\"]"
  if [[ -n $COMPONENTS ]]; then
    echo "components:"; for c in $COMPONENTS; do echo "  - \"$(rel "$c")\""; done
  fi
  if [[ -n $PATCHES ]]; then
    echo "patches:"   # kustomize only loads patch files from inside the overlay root, so copy them in
    for p in $PATCHES; do cp "$(abs "$p")" "$BUILD/overlay/"; echo "  - path: $(basename "$p")"; done
  fi
} > "$BUILD/overlay/kustomization.yaml"
log "rendering model servers ($MODELSERVER_OVERLAY)"
kubectl kustomize "$BUILD/overlay" > "$BUILD/modelserver.yaml"
grep -q 'REPLACE_' "$BUILD/modelserver.yaml" && die "unresolved REPLACE_ placeholder in model-server render; pick an overlay that sets images (e.g. .../gke or .../base with an image component)"

# Shared namespace: upstream overlays use fixed resource names and guide-wide labels, so two
# models would overwrite each other and one pool would select both. Rename every resource to
# the naming standard, drop upstream ServiceAccounts (pods run as the pre-existing one), and
# label model-server pods with llm-d.ai/deployment=$NAME, which is what the InferencePool selects.
WORKLOADS='.kind == "Deployment" or .kind == "LeaderWorkerSet" or .kind == "DisaggregatedSet"'
N_WORKLOADS=$(yq -N "select($WORKLOADS) | .kind" "$BUILD/modelserver.yaml" | wc -l | tr -d ' ')
[[ $N_WORKLOADS -ge 1 ]] || die "no model-server workload in render"
# one workload -> $NAME; several (e.g. prefill + decode Deployments) -> $NAME-<role>
WL_NAME='strenv(NAME)'; [[ $N_WORKLOADS -gt 1 ]] && WL_NAME='strenv(NAME) + "-" + (.metadata.labels."llm-d.ai/role" // .metadata.name)'
OLD_WL=$(yq -N "select($WORKLOADS) | .metadata.name" "$BUILD/modelserver.yaml")
POD_META='.. | select(tag == "!!map" and has("metadata") and (.spec | tag) == "!!map" and (.spec | has("containers"))) | .metadata'
LABELS="select($WORKLOADS) | (.metadata, ($POD_META)) | .labels"
NAME=$NAME SA=$SERVICE_ACCOUNT STRATEGY=$STRATEGY ENGINE=$ENGINE MODEL_SLUG=$MODEL_SLUG yq -i "
  select(.kind != \"ServiceAccount\") |
  (select($WORKLOADS) | .metadata.name) = $WL_NAME |
  (select(($WORKLOADS) | not) | .metadata.name) |= strenv(NAME) + \"-\" + . |
  (.. | select(tag == \"!!map\" and has(\"serviceAccountName\")) | .serviceAccountName) = strenv(SA) |
  (.. | select(tag == \"!!map\" and has(\"resourceClaimTemplateName\")) | .resourceClaimTemplateName) |= strenv(NAME) + \"-\" + . |
  ($LABELS) |= (. // {}) * {\"llm-d.ai/deployment\": strenv(NAME), \"llm-d.ai/strategy\": strenv(STRATEGY)} |
  ($LABELS | .\"llm-d.ai/model\") |= (. // strenv(MODEL_SLUG)) |
  ($LABELS | .\"llm-d.ai/engine-type\") |= (. // strenv(ENGINE)) |
  (select(.kind == \"Deployment\") | .spec.selector.matchLabels.\"llm-d.ai/deployment\") = strenv(NAME)
" "$BUILD/modelserver.yaml"

NEEDS_LWS=$(yq -N 'select(.kind == "LeaderWorkerSet" or .kind == "DisaggregatedSet") | .kind' "$BUILD/modelserver.yaml" | head -1)
VLLM_CTR='((.command // []) + (.args // [])) | join(" ") | test("vllm\s+serve")'
VLLM_POD=".. | select(tag == \"!!map\" and has(\"containers\")) | select([.containers[] | $VLLM_CTR] | any_c(.))"

# ---- vLLM image override (modelserver.image) ----------------------------------------
# Only containers that run `vllm serve`; sidecars and init containers keep their images. Applied
# before the air-gap rewrite, so bundle.sh locks/mirrors it and IMAGE_REGISTRY pins it by digest.
if [[ -n $MS_IMAGE ]]; then
  [[ $MS_IMAGE != *[[:space:]]* && ( ${MS_IMAGE##*/} == *:?* || $MS_IMAGE == *@sha256:* ) ]] ||
    die "modelserver.image must name a tag or digest (e.g. docker.io/vllm/vllm-openai:v0.32.0), got: $MS_IMAGE"
  log "vLLM image: $MS_IMAGE"
  IMG=$MS_IMAGE yq -i "($VLLM_POD | .containers[] | select($VLLM_CTR) | .image) = strenv(IMG)" "$BUILD/modelserver.yaml"
fi

# vLLM command text of every model-server container, one JSON string per container
vllm_cmds() { yq -o=json -I=0 "$VLLM_POD | .containers[] | select($VLLM_CTR) | ((.command // []) + (.args // [])) | join(\" \")" "$BUILD/modelserver.yaml"; }
# The overlay's reference model: every overlay labels its pods llm-d.ai/model=<name> and starts
# vLLM with <org>/<name> somewhere in the command (not always first: GLM puts flags before it).
UP_LABEL=$(yq -N "select($WORKLOADS) | .. | select(tag == \"!!map\" and has(\"llm-d.ai/model\")) | .\"llm-d.ai/model\"" "$BUILD/modelserver.yaml" | sort -u)
UP_MODEL=$(vllm_cmds | python3 -c '
import json,re,sys
lbl=sys.argv[1]
print("\n".join(sorted({m for l in sys.stdin for m in re.findall(r"[A-Za-z0-9_.-]+/" + re.escape(lbl) + r"(?![A-Za-z0-9_.-])", json.loads(l))})))' "$UP_LABEL")
[[ -n $UP_MODEL && $(wc -l <<<"$UP_MODEL") -eq 1 ]] ||
  die "cannot find the reference model of $MODELSERVER_OVERLAY (label llm-d.ai/model=$(echo $UP_LABEL), found: $(echo $UP_MODEL)); use modelserver.patches"
reesc() { python3 -c 'import re,sys; print(re.escape(sys.argv[1]))' "$1"; }

# ---- model swap: any HF model on any overlay ----------------------------------------
# Overlays hard-code their reference model and its model-specific flags (tool/reasoning parsers,
# chat template). When the profile's model differs, swap the id everywhere vLLM is started and
# drop those flags; the profile adds the new model's own flags via modelserver.args.
if [[ $UP_MODEL != "$MODEL" ]]; then
  log "model swap: $UP_MODEL -> $MODEL (dropping $UP_MODEL-specific parser/chat-template flags)"
  UP_RE='(?P<pre>^|[\s'"'"'"=@])'$(reesc "$UP_MODEL")'(?P<end>[\s'"'"'"\\]|$)'
  UP_REPL="\${pre}${MODEL//\$/\$\$}\${end}"
  DROP_RE='[ \t]+--(?:tool-call-parser|reasoning-parser|chat-template|chat-template-content-format)(?:=|[ \t]+)[^\s\\]+|[ \t]+--enable-auto-tool-choice'
  DROP_LIST='^--(?:tool-call-parser|reasoning-parser|chat-template|chat-template-content-format)=.*$|^--enable-auto-tool-choice$'
  UP=$UP_MODEL MODEL=$MODEL UP_RE=$UP_RE UP_REPL=$UP_REPL DROP_RE=$DROP_RE DROP_LIST=$DROP_LIST MLABEL=${MODEL##*/} yq -i "
    ($VLLM_POD | .containers[] | select($VLLM_CTR)) |= (
      (.command[], .args[]) |= (sub(strenv(UP_RE), strenv(UP_REPL)) | sub(strenv(DROP_RE), \"\")) |
      (.args[] | select(. == strenv(UP))) = strenv(MODEL) |
      .args = [(.args // [])[] | select(test(strenv(DROP_LIST)) | not)] | del(.args | select(length == 0))
    ) |
    ($LABELS | select(has(\"llm-d.ai/model\")) | .\"llm-d.ai/model\") = strenv(MLABEL) |
    (select(.kind == \"Deployment\") | .spec.selector.matchLabels | select(has(\"llm-d.ai/model\")) | .\"llm-d.ai/model\") = strenv(MLABEL)
  " "$BUILD/modelserver.yaml"
  ! vllm_cmds | grep -qE -- '--(tool-call-parser|reasoning-parser|chat-template)[ \\"]' ||
    die "could not drop $UP_MODEL-specific flags (space-separated list args?); use modelserver.patches"
fi

# ---- sizing (aggregated overlays only; P/D and wide-EP size per role via patches) ---
if [[ -n $MS_TP || -n $MS_REPLICAS ]]; then
  [[ -z $NEEDS_LWS ]] || die "modelserver.tensorParallel/replicas only apply to aggregated (Deployment) overlays; use modelserver.patches for P/D and wide-EP"
  if [[ -n $MS_TP ]]; then
    [[ $MS_TP =~ ^[1-9][0-9]*$ ]] || die "modelserver.tensorParallel must be a positive integer"
    vllm_cmds | grep -qE -- '--tensor-parallel-size|(^|[ "])-tp[ =]' || MS_ARGS_JSON=$(yq -o=json -I=0 ". + [\"--tensor-parallel-size=$MS_TP\"]" <<<"$MS_ARGS_JSON")
    TP=$MS_TP yq -i "
      ($VLLM_POD | .containers[] | select($VLLM_CTR)) |= (
        (.command[], .args[]) |= sub(\"--tensor-parallel-size(?:=|[ \\\\t]+)[0-9]+\", \"--tensor-parallel-size=\" + strenv(TP)) |
        (.resources.limits, .resources.requests) |= with_entries(if (.key | test(\"gpu$\")) then .value = env(TP) else . end)
      )" "$BUILD/modelserver.yaml"
  fi
  [[ -z $MS_REPLICAS ]] || REPLICAS=$MS_REPLICAS yq -i '(select(.kind == "Deployment") | .spec.replicas) = env(REPLICAS)' "$BUILD/modelserver.yaml"
fi

# ---- extra vLLM args: modelserver.args + draft-model speculative decoding ------------
# Speculative decoding: a separate draft model (draft_model / EAGLE heads; an HF id like MODEL,
# from the same GCS bucket as the model), or a method with a
# built-in drafter (speculativeConfig.method: mtp / ngram) when the profile sets only that.
if [[ -n $DRAFT_MODEL || $SPEC_SET == true ]]; then
  ! vllm_cmds | grep -qE 'speculative[-_]config' ||
    die "$MODELSERVER_OVERLAY already configures speculative decoding (e.g. MTP); drop draftModel or use another overlay"
  SPEC=$(python3 -c 'import json,sys; c=json.loads(sys.argv[1]); c.update({"model": sys.argv[2]} if sys.argv[2] else {}); print(json.dumps(c, separators=(",", ":")))' \
    "$SPEC_CONFIG" "$DRAFT_MODEL") || die "speculativeConfig is not valid: $SPEC_CONFIG"
  [[ -z $NEEDS_LWS || -z $DRAFT_MODEL ]] || log "WARN: draft-model speculative decoding with P/D or wide-EP is not covered by the upstream guides; validate before production"
  MS_ARGS_JSON=$(SPEC=$SPEC yq -o=json -I=0 '. + ["--speculative-config", strenv(SPEC)]' <<<"$MS_ARGS_JSON")
fi
if [[ $MS_ARGS_JSON != "[]" ]]; then
  # list-form overlays: appended to args. Script-form (bash -c "exec vllm serve <model> \ ..."):
  # shell-quoted and inserted right after the model, since vLLM wants `vllm serve <model> --flags`.
  ARGS_SH=$(python3 -c 'import json,shlex,sys; print(" ".join(shlex.quote(a) for a in json.loads(sys.argv[1])).replace("$", "$$"))' "$MS_ARGS_JSON")
  RE='(?P<pre>\s)'$(reesc "$MODEL")'(?P<end>[\s\\]|$)'
  ARGS=$MS_ARGS_JSON RE=$RE REPL="\${pre}${MODEL//\$/\$\$} $ARGS_SH\${end}" yq -i "
    ($VLLM_POD | .containers[] | select($VLLM_CTR)) |= (
      if ([(.command // [])[], (.args // [])[]] | any_c(test(\"vllm\\\\s+serve\")))
      then (.command[], .args[]) |= sub(strenv(RE), strenv(REPL))
      else .args = (.args // []) + (strenv(ARGS) | from_json)
      end)
  " "$BUILD/modelserver.yaml"
  FIRST=$(yq -r '.[0]' <<<"$MS_ARGS_JSON")
  [[ $(vllm_cmds | grep -oF -- "${FIRST%%=*}" | wc -l) -eq $(vllm_cmds | grep -oE 'vllm[[:space:]]+serve' | wc -l) ]] ||
    die "extra vLLM args must land exactly once per 'vllm serve' (model id appears elsewhere in the script?); use modelserver.patches"
fi

# Weights from GCS. The init container lays each model out as a Hugging Face cache entry
# (hub/models--<org>--<name>/snapshots/<rev>), so every overlay keeps passing HF ids unchanged
# (in args or inside its bash script) and vLLM resolves them offline from local disk.
# hostPath + flock + marker: one download per node, shared by every pod/rank on it, survives restarts.
# garuda's folder name for an HF id: google/gemma-4-31B-it -> google__gemma_4_31b_it
gcs_folder() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's#/#__#; s/[^a-z0-9_]+/_/g'; }
MODEL_GCS_URI=${MODEL_GCS_URI:-${MODEL_BUCKET%/}/$(gcs_folder "$MODEL")}
DRAFT_GCS_URI=${DRAFT_GCS_URI:-${DRAFT_MODEL:+${MODEL_BUCKET%/}/$(gcs_folder "$DRAFT_MODEL")}}
{
  for u in $MODEL_GCS_URI $DRAFT_GCS_URI; do [[ $u == gs://?* ]] || die "weights URI must be gs://..., got '$u' (MODEL_BUCKET / weights.gcsUri)"; done
  # one "<hf-cache-repo-dir> <gs-uri>" line per model
  MODELS="models--${MODEL//\//--} $MODEL_GCS_URI"
  [[ -z $DRAFT_MODEL ]] || MODELS+=$'\n'"models--${DRAFT_MODEL//\//--} $DRAFT_GCS_URI"
  # shellcheck disable=SC2016  # expanded in the container
  FETCH='set -eu
while read -r REPO SRC; do
  D=/model-cache/hub/$REPO
  REV=$(printf %s "$SRC" | sha1sum | cut -c1-40)   # new GCS path => new snapshot
  mkdir -p "$D/refs" "$D/snapshots/$REV"
  (
    flock 9                                        # pods on the same node wait for one download
    if [ ! -f "$D/.complete-$REV" ]; then
      echo "fetching $SRC"; gcloud storage rsync --recursive "${SRC%/}" "$D/snapshots/$REV"
      [ -f "$D/snapshots/$REV/config.json" ] || { echo "ERROR: no config.json at the top of $SRC (expected the model repo files there)"; exit 1; }
      touch "$D/.complete-$REV"
    fi
    printf %s "$REV" > "$D/refs/main"
  ) 9>"$D/.lock"
  echo "ready: $D/snapshots/$REV"
done <<EOF
$MODELS
EOF'
  MODELS=$MODELS HP=$MODEL_CACHE_PATH IMG=$DOWNLOADER_IMAGE FETCH=$FETCH yq -i "
    ($VLLM_POD) |= (
      .initContainers = [{
        \"name\": \"fetch-model\", \"image\": strenv(IMG), \"command\": [\"/bin/bash\", \"-c\", strenv(FETCH)],
        \"env\": [{\"name\": \"MODELS\", \"value\": strenv(MODELS)}],
        \"resources\": {\"requests\": {\"cpu\": \"4\", \"memory\": \"4Gi\"}, \"limits\": {\"memory\": \"8Gi\"}},
        \"volumeMounts\": [{\"name\": \"model-cache\", \"mountPath\": \"/model-cache\"}]
      }] + (.initContainers // []) |
      .volumes = [(.volumes // [])[] | select(.name != \"model-cache\")] + [{\"name\": \"model-cache\", \"hostPath\": {\"path\": strenv(HP), \"type\": \"DirectoryOrCreate\"}}] |
      (.containers[] | select($VLLM_CTR)) |= (
        .env = [(.env // [])[] | select(.name | test(\"^(HF_TOKEN|HF_HOME|HF_HUB_OFFLINE|TRANSFORMERS_OFFLINE)$\") | not)]
               + [{\"name\": \"HF_HOME\", \"value\": \"/model-cache\"}, {\"name\": \"HF_HUB_OFFLINE\", \"value\": \"1\"}, {\"name\": \"TRANSFORMERS_OFFLINE\", \"value\": \"1\"},
                  {\"name\": \"HF_MODULES_CACHE\", \"value\": \"/tmp/hf-modules\"}] |
        # read-only: only fetch-model writes the shared node cache, so one model server can't tamper with another's weights
        .volumeMounts = (.volumeMounts // []) + [{\"name\": \"model-cache\", \"mountPath\": \"/model-cache\", \"readOnly\": true}]
      )
    )
  " "$BUILD/modelserver.yaml"
}
# values files carry a guide label in the pool selector; pin it to what the pods carry (helm can't null a subchart default)
POOL_GUIDE=$(yq -N "select($WORKLOADS) | .metadata.labels.\"llm-d.ai/guide\"" "$BUILD/modelserver.yaml" | grep -v '^null$' | sort -u)
[[ $(wc -l <<<"$POOL_GUIDE") -eq 1 && -n $POOL_GUIDE ]] || die "expected one llm-d.ai/guide label on workloads, got: $POOL_GUIDE"
# Router values reference upstream workload names (e.g. the rollout screener's
# disaggregatedset.x-k8s.io/name=<name> selector); map them to the new names.
paste -d' ' <(echo "$OLD_WL") <(yq -N "select($WORKLOADS) | .metadata.name" "$BUILD/modelserver.yaml") |
  while read -r o n; do echo "s#(x-k8s\\.io/name=)$o([^-a-z0-9]|\$)#\\1$n\\2#g"; done > "$BUILD/rename.sed"

# ---- 3. render router ----------------------------------------------------------
HELM_ARGS=(-n "$NAMESPACE" -f "$LLMD/guides/recipes/router/base.values.yaml")
i=0; for v in $ROUTER_VALUES; do i=$((i+1))
  sed -E -f "$BUILD/rename.sed" "$(abs "$v")" > "$BUILD/values-$i.yaml"; HELM_ARGS+=(-f "$BUILD/values-$i.yaml"); done
# pool selects only this deployment's model-server pods (guide labels are shared across models)
HELM_ARGS+=(--set-string "router.modelServers.matchLabels.llm-d\.ai/guide=$POOL_GUIDE"
            --set-string "router.modelServers.matchLabels.llm-d\.ai/deployment=$NAME")
if [[ $ROUTER_MODE == gateway ]]; then
  CHART=$ROUTER_GATEWAY_CHART
  HELM_ARGS+=(--set "provider.name=$GATEWAY_PROVIDER" --set httpRoute.create=true
              --set "httpRoute.inferenceGatewayName=$GATEWAY_NAME"
              --set "httpRoute.inferenceGatewayNamespace=$GATEWAY_NAMESPACE")
  [[ -n $BASE_MODEL ]] && HELM_ARGS+=(--set-string "httpRoute.baseModel=$BASE_MODEL")
else
  CHART=$ROUTER_STANDALONE_CHART
fi
for s in $ROUTER_SET; do HELM_ARGS+=(--set "$s"); done
CHART_DIR=$ROOT/.cache/charts/$(basename "$CHART")-$ROUTER_CHART_VERSION
if [[ ! -f $CHART_DIR/Chart.yaml ]]; then
  log "pulling $CHART:$ROUTER_CHART_VERSION into .cache/charts"
  rm -rf "$CHART_DIR.tmp"; mkdir -p "$CHART_DIR.tmp"
  helm pull "$CHART" --version "$ROUTER_CHART_VERSION" --untar --untardir "$CHART_DIR.tmp" >/dev/null || die "cannot pull $CHART; $OFFLINE_HINT"
  rm -rf "$CHART_DIR"; mv "$CHART_DIR.tmp/$(basename "$CHART")" "$CHART_DIR"; rm -rf "$CHART_DIR.tmp"
fi
log "rendering router ($CHART:$ROUTER_CHART_VERSION, pool selector llm-d.ai/deployment=$NAME)"
helm template "$NAME" "$CHART_DIR" "${HELM_ARGS[@]}" > "$BUILD/router.yaml"
# label everything the router render creates, so it can be found / deleted as one unit
NAME=$NAME yq -i '.metadata.labels."llm-d.ai/deployment" = strenv(NAME)' "$BUILD/router.yaml"

# ---- image rewrite (air-gapped) ---------------------------------------------------
# Each image -> $IMAGE_REGISTRY per IMAGE_TEMPLATE (lib/images.sh); digests from .cache/images.lock.
# shellcheck source=lib/images.sh
source "$ROOT/lib/images.sh"
mirror_image() {
  local src; src=$(norm_image "$1")
  local dig; dig=$(awk -v s="$src" '$1 == s { print $2 }' "$ROOT/.cache/images.lock" 2>/dev/null)
  [[ -n $dig ]] || die "image $src is not in .cache/images.lock; re-run ./bundle.sh (with this profile) on a connected machine"
  image_target "$src" "$dig"
}
if [[ -n $IMAGE_REGISTRY ]]; then
  IMAGE_REGISTRY=${IMAGE_REGISTRY%/}
  for f in "$BUILD/modelserver.yaml" "$BUILD/router.yaml"; do
    while read -r img; do
      [[ -z $img ]] && continue
      new=$(mirror_image "$img") || exit 1
      OLD=$img NEW=$new yq -i '(.. | select(tag == "!!map" and has("image") and .image == strenv(OLD)) | .image) = strenv(NEW)' "$f"
    done < <(yq -N '.. | select(tag == "!!map" and has("image")) | .image' "$f" | sort -u)
  done
  SMOKE_IMAGE=$(mirror_image "$SMOKE_IMAGE") || exit 1
fi

if [[ $MODE == --dry-run ]]; then log "rendered to $BUILD/{modelserver,router}.yaml"; exit 0; fi

if [[ $MODE == --delete ]]; then
  kubectl delete -n "$NAMESPACE" -f "$BUILD/modelserver.yaml" --ignore-not-found
  kubectl delete -n "$NAMESPACE" -f "$BUILD/router.yaml" --ignore-not-found
  exit 0
fi
[[ $MODE == deploy ]] || usage

# ---- 4. preflight --------------------------------------------------------------
log "preflight"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || die "namespace $NAMESPACE not found (shared namespace is pre-created)"
kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" >/dev/null 2>&1 ||
  die "ServiceAccount $NAMESPACE/$SERVICE_ACCOUNT not found (model-server pods run as this pre-existing SA)"
kubectl get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1 ||
  die "InferencePool CRD missing. Install: kubectl apply -f $ROOT/.cache/crds/inference-extension-v1.yaml (from bundle.sh), or let GKE >=1.34.0-gke.1626000 with Gateway API enabled manage it"
if [[ -n $NEEDS_LWS ]]; then
  kubectl get crd leaderworkersets.leaderworkerset.x-k8s.io >/dev/null 2>&1 ||
    die "$NEEDS_LWS needs the LWS controller (>=v0.11.1, --set enableDisaggregatedSet=true). See $LLMD/guides/pd-disaggregation/README.md#prerequisites"
  [[ $NEEDS_LWS != DisaggregatedSet ]] || kubectl get crd disaggregatedsets.disaggregatedset.x-k8s.io >/dev/null 2>&1 ||
    die "DisaggregatedSet CRD missing: reinstall LWS with --set enableDisaggregatedSet=true"
fi
if [[ $ROUTER_MODE == gateway ]]; then
  GW=$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o yaml 2>/dev/null) ||
    die "Gateway $GATEWAY_NAMESPACE/$GATEWAY_NAME not found. Create one: kubectl apply -k $LLMD/guides/recipes/gateway/<agentgateway|gke-l7-rilb|gke-l7-regional-external-managed> -n $GATEWAY_NAMESPACE"
  if [[ $GATEWAY_NAMESPACE != "$NAMESPACE" ]]; then
    FROM=$(yq '[.spec.listeners[].allowedRoutes.namespaces.from // "Same"] | unique | join(",")' <<<"$GW")
    [[ $FROM == *All* || $FROM == *Selector* ]] ||
      die "Gateway listeners only allow routes from: $FROM. Set allowedRoutes.namespaces.from: All (or a Selector matching $NAMESPACE)"
    [[ $FROM == *All* ]] || log "WARN: Gateway uses a namespace Selector; make sure namespace $NAMESPACE matches it"
  fi
  # Two catch-all "/" routes on one Gateway conflict (oldest wins). Shared gateways need BASE_MODEL.
  OTHERS=$(kubectl get httproute -A -o yaml | yq -N ".items[] | select(.spec.parentRefs[].name == \"$GATEWAY_NAME\")
    | select(.metadata.name != \"$NAME\" or .metadata.namespace != \"$NAMESPACE\") | .metadata.namespace + \"/\" + .metadata.name" | sort -u)
  [[ -z $OTHERS || -n $BASE_MODEL ]] ||
    die "Gateway already has routes ($(tr '\n' ' ' <<<"$OTHERS")); set BASE_MODEL and install IPP so routes match on X-Gateway-Base-Model-Name"
fi

# ---- 5. apply ------------------------------------------------------------------
# The chart has no hooks or lookups, so its render is exactly what helm would install: apply the
# reviewed/archived manifest itself (same as the model servers) instead of re-rendering in helm.
log "applying router"
kubectl apply -n "$NAMESPACE" --server-side -f "$BUILD/router.yaml"
kubectl rollout status deployment -n "$NAMESPACE" -l "llm-d.ai/deployment=$NAME" --timeout=10m
log "applying model servers"
kubectl apply -n "$NAMESPACE" --server-side -f "$BUILD/modelserver.yaml"

# ---- 6. wait -------------------------------------------------------------------
if [[ $ROUTER_MODE == gateway ]]; then
  log "waiting for HTTPRoute to be accepted by $GATEWAY_NAMESPACE/$GATEWAY_NAME"
  kubectl wait httproute/"$NAME" -n "$NAMESPACE" --timeout=5m \
    --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True
fi
log "waiting up to $WAIT_TIMEOUT for model-server pods (llm-d.ai/deployment=$NAME); large models take a while"
until kubectl get pod -n "$NAMESPACE" -l "llm-d.ai/deployment=$NAME" -o name | grep -q .; do sleep 5; done
kubectl wait pod -n "$NAMESPACE" -l "llm-d.ai/deployment=$NAME" --for=condition=Ready --timeout="$WAIT_TIMEOUT"

# ---- 7. smoke test through the front door --------------------------------------
if [[ $ROUTER_MODE == gateway ]]; then
  IP=$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.status.addresses[0].value}')
else
  IP=$(kubectl get service "$NAME-epp" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
fi
log "smoke test via http://$IP/v1/completions"
kubectl run "smoke-$NAME" --rm -i --restart=Never -n "$NAMESPACE" --image="$SMOKE_IMAGE" -- \
  curl -sS --fail-with-body -m 300 "http://$IP/v1/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"Say hello.\",\"max_tokens\":16}"
log "done: $NAME serving $MODEL at http://$IP"
