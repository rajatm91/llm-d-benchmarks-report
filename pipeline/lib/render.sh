# Rendering: upstream llm-d templates -> $BUILD/modelserver.yaml + $BUILD/router.yaml. Sourced by deploy.sh.
# Each function edits the render in place; deploy.sh calls them in order.

# yq selectors shared by the edits. lib/yq/*.yq programs refer to them as @NAME@.
WORKLOADS='.kind == "Deployment" or .kind == "LeaderWorkerSet" or .kind == "DisaggregatedSet"'
VLLM_CTR='((.command // []) + (.args // [])) | join(" ") | test("vllm\s+serve")'           # a container running `vllm serve`
VLLM_POD=".. | select(tag == \"!!map\" and has(\"containers\")) | select([.containers[] | $VLLM_CTR] | any_c(.))"  # a pod spec with one
POD_META='.. | select(tag == "!!map" and has("metadata") and (.spec | tag) == "!!map" and (.spec | has("containers"))) | .metadata'
LABELS="select($WORKLOADS) | (.metadata, ($POD_META)) | .labels"                      # workload + pod template labels

# yq_edit <program> <file>: run lib/yq/<program>.yq on <file> in place; inputs come in as env vars
yq_edit() {
  local prog; prog=$(<"$LIB/yq/$1.yq")
  prog=${prog//@WORKLOADS@/$WORKLOADS}; prog=${prog//@VLLM_CTR@/$VLLM_CTR}
  prog=${prog//@VLLM_POD@/$VLLM_POD};   prog=${prog//@LABELS@/$LABELS}
  yq -i "$prog" "$2"
}
helper() { python3 "$LIB/helpers.py" "$@"; }
# Paths starting with guides/ are upstream llm-d files; anything else is relative to this pipeline.
abs() { case $1 in /*) echo "$1";; guides/*) echo "$LLMD/$1";; *) echo "$ROOT/$1";; esac; }
# vLLM command text of every model-server container, one JSON string per container
vllm_cmds() { yq -o=json -I=0 "$VLLM_POD | .containers[] | select($VLLM_CTR) | ((.command // []) + (.args // [])) | join(\" \")" "$MS"; }

OFFLINE_HINT="no network? run ./bundle.sh on a connected machine and copy its .cache/ here"

# Everything fetched lands in .cache/, so a .cache/ copied from ./bundle.sh needs no network.
fetch_llmd() {
  [[ ! -d $LLMD/guides ]] || return 0
  log "fetching llm-d@$LLMD_REF"
  rm -rf "$LLMD"; git init -q "$LLMD"
  git -C "$LLMD" fetch -q --depth 1 https://github.com/llm-d/llm-d.git "$LLMD_REF" || { rm -rf "$LLMD"; die "cannot fetch llm-d@$LLMD_REF; $OFFLINE_HINT"; }
  git -C "$LLMD" checkout -q FETCH_HEAD
}

# upstream overlay + modelserver.components + modelserver.patches, through kustomize
render_modelservers() {
  rm -rf "$BUILD"; mkdir -p "$BUILD/overlay"
  local k=$BUILD/overlay/kustomization.yaml c p
  {
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "resources: [\"$(helper relpath "$(abs "$MODELSERVER_OVERLAY")" "$BUILD/overlay")\"]"
    if [[ -n $COMPONENTS ]]; then
      echo "components:"; for c in $COMPONENTS; do echo "  - \"$(helper relpath "$(abs "$c")" "$BUILD/overlay")\""; done
    fi
    if [[ -n $PATCHES ]]; then
      echo "patches:"   # kustomize only loads patch files from inside the overlay root, so copy them in
      for p in $PATCHES; do cp "$(abs "$p")" "$BUILD/overlay/"; echo "  - path: $(basename "$p")"; done
    fi
  } > "$k"
  log "rendering model servers ($MODELSERVER_OVERLAY)"
  kubectl kustomize "$BUILD/overlay" > "$MS"
  ! grep -q 'REPLACE_' "$MS" ||
    die "unresolved REPLACE_ placeholder in model-server render; pick an overlay that sets images (e.g. .../gke or .../base with an image component)"
}

# Upstream overlays use fixed resource names and guide-wide labels, so two models in one namespace
# would overwrite each other and one pool would select both. Rename every resource, drop upstream
# ServiceAccounts (pods run as the pre-existing one), and label pods with llm-d.ai/deployment=$NAME.
share_namespace() {
  local n; n=$(yq -N "select($WORKLOADS) | .kind" "$MS" | wc -l | tr -d ' ')
  [[ $n -ge 1 ]] || die "no model-server workload in render"
  OLD_WORKLOADS=$(yq -N "select($WORKLOADS) | .metadata.name" "$MS")   # router values may reference these
  MULTI=$([[ $n -gt 1 ]] && echo true || echo false) NAME=$NAME SA=$SERVICE_ACCOUNT STRATEGY=$STRATEGY ENGINE=$ENGINE \
    MODEL_SLUG=$MODEL_SLUG yq_edit shared-namespace "$MS"
  NEEDS_LWS=$(yq -N 'select(.kind == "LeaderWorkerSet" or .kind == "DisaggregatedSet") | .kind' "$MS" | head -1)
}

# modelserver.image. Runs before the air-gap rewrite, so bundle.sh locks it and IMAGE_REGISTRY pins it.
set_vllm_image() {
  [[ -n $MS_IMAGE ]] || return 0
  [[ $MS_IMAGE != *[[:space:]]* && ( ${MS_IMAGE##*/} == *:?* || $MS_IMAGE == *@sha256:* ) ]] ||
    die "modelserver.image must name a tag or digest (e.g. docker.io/vllm/vllm-openai:v0.32.0), got: $MS_IMAGE"
  log "vLLM image: $MS_IMAGE"
  IMG=$MS_IMAGE yq_edit vllm-image "$MS"
}

# Overlays hard-code their reference model and its model-specific flags (tool/reasoning parsers,
# chat template). When the profile's model differs, swap the id everywhere vLLM is started and
# drop those flags; the profile adds the new model's own flags via modelserver.args.
swap_model() {
  # the reference model: pods are labelled llm-d.ai/model=<name>, and vLLM starts with <org>/<name>
  # somewhere in the command (not always first: GLM puts flags before it)
  local label up
  label=$(yq -N "select($WORKLOADS) | .. | select(tag == \"!!map\" and has(\"llm-d.ai/model\")) | .\"llm-d.ai/model\"" "$MS" | sort -u)
  up=$(vllm_cmds | helper reference_model "$label")
  [[ -n $up && $(wc -l <<<"$up") -eq 1 ]] ||
    die "cannot find the reference model of $MODELSERVER_OVERLAY (label llm-d.ai/model=$(echo $label), found: $(echo $up)); use modelserver.patches"
  [[ $up != "$MODEL" ]] || return 0

  log "model swap: $up -> $MODEL (dropping $up-specific parser/chat-template flags)"
  local flags='tool-call-parser|reasoning-parser|chat-template|chat-template-content-format'
  UP=$up MODEL=$MODEL MLABEL=${MODEL##*/} \
    UP_RE='(?P<pre>^|[\s'"'"'"=@])'$(helper re_escape "$up")'(?P<end>[\s'"'"'"\\]|$)' \
    UP_REPL="\${pre}${MODEL//\$/\$\$}\${end}" \
    DROP_RE='[ \t]+--(?:'$flags')(?:=|[ \t]+)[^\s\\]+|[ \t]+--enable-auto-tool-choice' \
    DROP_LIST='^--(?:'$flags')=.*$|^--enable-auto-tool-choice$' \
    yq_edit model-swap "$MS"
  ! vllm_cmds | grep -qE -- '--(tool-call-parser|reasoning-parser|chat-template)[ \\"]' ||
    die "could not drop $up-specific flags (space-separated list args?); use modelserver.patches"
}

# modelserver.tensorParallel / replicas. Aggregated overlays only; P/D and wide-EP size per role via patches.
set_size() {
  [[ -n $MS_TP || -n $MS_REPLICAS ]] || return 0
  [[ -z $NEEDS_LWS ]] || die "modelserver.tensorParallel/replicas only apply to aggregated (Deployment) overlays; use modelserver.patches for P/D and wide-EP"
  if [[ -n $MS_TP ]]; then
    [[ $MS_TP =~ ^[1-9][0-9]*$ ]] || die "modelserver.tensorParallel must be a positive integer"
    # no TP flag in the overlay: add one with the other extra args
    vllm_cmds | grep -qE -- '--tensor-parallel-size|(^|[ "])-tp[ =]' ||
      MS_ARGS_JSON=$(yq -o=json -I=0 ". + [\"--tensor-parallel-size=$MS_TP\"]" <<<"$MS_ARGS_JSON")
    TP=$MS_TP yq_edit tensor-parallel "$MS"
  fi
  [[ -z $MS_REPLICAS ]] || REPLICAS=$MS_REPLICAS yq -i '(select(.kind == "Deployment") | .spec.replicas) = env(REPLICAS)' "$MS"
}

# modelserver.args, plus --speculative-config for draftModel / speculativeConfig
add_vllm_args() {
  if [[ -n $DRAFT_MODEL || $SPEC_SET == true ]]; then
    ! vllm_cmds | grep -qE 'speculative[-_]config' ||
      die "$MODELSERVER_OVERLAY already configures speculative decoding (e.g. MTP); drop draftModel or use another overlay"
    local spec; spec=$(helper speculative_config "$SPEC_CONFIG" "$DRAFT_MODEL") || die "speculativeConfig is not valid: $SPEC_CONFIG"
    [[ -z $NEEDS_LWS || -z $DRAFT_MODEL ]] || log "WARN: draft-model speculative decoding with P/D or wide-EP is not covered by the upstream guides; validate before production"
    MS_ARGS_JSON=$(SPEC=$spec yq -o=json -I=0 '. + ["--speculative-config", strenv(SPEC)]' <<<"$MS_ARGS_JSON")
  fi
  [[ $MS_ARGS_JSON != "[]" ]] || return 0

  ARGS=$MS_ARGS_JSON RE='(?P<pre>\s)'$(helper re_escape "$MODEL")'(?P<end>[\s\\]|$)' \
    REPL="\${pre}${MODEL//\$/\$\$} $(helper shell_args "$MS_ARGS_JSON")\${end}" yq_edit vllm-args "$MS"
  # List-form containers just get the args appended. Script-form ones (bash -c "... vllm serve <model> ...") get
  # them inserted after the model id, which goes wrong if the id is missing or appears twice in the script:
  # the inserted text must appear exactly once per `vllm serve` in those scripts. Repeating a flag the overlay
  # already sets is fine (vLLM keeps the last value).
  local scripts ins
  scripts=$(yq -N "$VLLM_POD | .containers[] | select($VLLM_CTR) | ((.command // [])[], (.args // [])[]) | select(test(\"vllm\\\\s+serve\"))" "$MS")
  ins="$MODEL $(helper shell_args "$MS_ARGS_JSON")"
  [[ $(grep -oF -- "$ins" <<<"$scripts" | wc -l) -eq $(grep -oE 'vllm[[:space:]]+serve' <<<"$scripts" | wc -l) ]] ||
    die "extra vLLM args must land exactly once per 'vllm serve' in script-form containers (model id missing or repeated in the script?); use modelserver.patches"
}

# Weights from GCS. lib/fetch-model.sh lays each model out as a Hugging Face cache entry
# (hub/models--<org>--<name>/snapshots/<rev>), so overlays keep passing HF ids unchanged and vLLM
# resolves them offline. One download per node (hostPath + flock), shared by every pod on it.
# lib/fetch-model.sh is embedded verbatim in the pod spec: editing it restarts every model server.
add_weights_fetch() {
  local model_uri=${MODEL_GCS_URI:-${MODEL_BUCKET%/}/$(gcs_folder "$MODEL")} draft_uri="" u
  [[ -z $DRAFT_MODEL ]] || draft_uri=${MODEL_BUCKET%/}/$(gcs_folder "$DRAFT_MODEL")
  for u in $model_uri $draft_uri; do [[ $u == gs://?* ]] || die "weights URI must be gs://..., got '$u' (MODEL_BUCKET / weights.gcsUri)"; done
  # one "<hf-cache-repo-dir> <gs-uri>" line per model
  local models="models--${MODEL//\//--} $model_uri"
  [[ -z $DRAFT_MODEL ]] || models+=$'\n'"models--${DRAFT_MODEL//\//--} $draft_uri"
  MODELS=$models HP=$MODEL_CACHE_PATH IMG=$DOWNLOADER_IMAGE FETCH=$(<"$LIB/fetch-model.sh") yq_edit fetch-model "$MS"
}
# garuda's folder name for an HF id: google/gemma-4-31B-it -> google__gemma_4_31b_it
gcs_folder() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's#/#__#; s/[^a-z0-9_]+/_/g'; }

# llm-d router chart + base values + router.values + the pool/gateway settings + router.set
render_router() {
  # Pin the pool's guide label to what the pods carry (values files set one; helm can't null a subchart default).
  local guide; guide=$(yq -N "select($WORKLOADS) | .metadata.labels.\"llm-d.ai/guide\"" "$MS" | grep -v '^null$' | sort -u)
  [[ $(wc -l <<<"$guide") -eq 1 && -n $guide ]] || die "expected one llm-d.ai/guide label on workloads, got: $guide"
  # Router values reference upstream workload names (e.g. the rollout screener's
  # disaggregatedset.x-k8s.io/name=<name> selector); map them to the new names.
  paste -d' ' <(echo "$OLD_WORKLOADS") <(yq -N "select($WORKLOADS) | .metadata.name" "$MS") |
    while read -r o n; do echo "s#(x-k8s\\.io/name=)$o([^-a-z0-9]|\$)#\\1$n\\2#g"; done > "$BUILD/rename.sed"

  local args=(-n "$NAMESPACE" -f "$LLMD/guides/recipes/router/base.values.yaml") i=0 v s chart
  for v in $ROUTER_VALUES; do i=$((i+1))
    sed -E -f "$BUILD/rename.sed" "$(abs "$v")" > "$BUILD/values-$i.yaml"; args+=(-f "$BUILD/values-$i.yaml")
  done
  # the pool selects only this deployment's model-server pods (guide labels are shared across models)
  args+=(--set-string "router.modelServers.matchLabels.llm-d\.ai/guide=$guide"
         --set-string "router.modelServers.matchLabels.llm-d\.ai/deployment=$NAME")
  if [[ $ROUTER_MODE == gateway ]]; then
    chart=$ROUTER_GATEWAY_CHART
    args+=(--set "provider.name=$GATEWAY_PROVIDER" --set httpRoute.create=true
           --set "httpRoute.inferenceGatewayName=$GATEWAY_NAME"
           --set "httpRoute.inferenceGatewayNamespace=$GATEWAY_NAMESPACE")
    [[ -z $BASE_MODEL ]] || args+=(--set-string "httpRoute.baseModel=$BASE_MODEL")
  else
    chart=$ROUTER_STANDALONE_CHART
  fi
  # MONITORING=gmp: EPP /metrics without auth (--metrics-endpoint-auth=false), so no token ServiceAccount, Secret
  # or cluster RBAC is needed; the chart then renders no PodMonitoring for it, add_epp_monitoring adds one
  [[ $MONITORING != gmp ]] || args+=(--set router.monitoring.prometheus.auth.enabled=false)
  # gateway.timeoutSec: non-GKE providers take it as the HTTPRoute timeout; GKE's GCPBackendPolicy below
  if [[ -n $GATEWAY_TIMEOUT ]]; then
    [[ $GATEWAY_TIMEOUT =~ ^[1-9][0-9]*$ ]] || die "gateway.timeoutSec must be a whole number of seconds, got '$GATEWAY_TIMEOUT'"
    args+=(--set "httpRoute.requestTimeout=${GATEWAY_TIMEOUT}s")
  fi
  for s in $ROUTER_SET; do args+=(--set "$s"); done

  local dir=$ROOT/.cache/charts/$(basename "$chart")-$ROUTER_CHART_VERSION
  if [[ ! -f $dir/Chart.yaml ]]; then
    log "pulling $chart:$ROUTER_CHART_VERSION into .cache/charts"
    rm -rf "$dir.tmp"; mkdir -p "$dir.tmp"
    helm pull "$chart" --version "$ROUTER_CHART_VERSION" --untar --untardir "$dir.tmp" >/dev/null || die "cannot pull $chart; $OFFLINE_HINT"
    rm -rf "$dir"; mv "$dir.tmp/$(basename "$chart")" "$dir"; rm -rf "$dir.tmp"
  fi
  drop_mac_junk "$dir"
  log "rendering router ($chart:$ROUTER_CHART_VERSION, pool selector llm-d.ai/deployment=$NAME)"
  helm template "$NAME" "$dir" "${args[@]}" > "$ROUTER"
  # label everything the router render creates, so it can be found / deleted as one unit
  # (objects only: helm emits empty "---" documents for templates that render nothing; labelling those
  #  would turn them into kind-less objects that kubectl apply rejects: "apiVersion not set, kind not set")
  NAME=$NAME yq -i '(select(.kind != null) | .metadata.labels."llm-d.ai/deployment") = strenv(NAME)' "$ROUTER"
  use_router_sa
  add_epp_monitoring
  # the chart hard-codes timeoutSec: 300 in its GCPBackendPolicy templates (GKE load balancer backend timeout)
  if [[ -n $GATEWAY_TIMEOUT ]] && yq -e 'select(.kind == "GCPBackendPolicy")' "$ROUTER" >/dev/null 2>&1; then
    T=$GATEWAY_TIMEOUT yq -i '(select(.kind == "GCPBackendPolicy") | .spec.default.timeoutSec) = (strenv(T) | tonumber)' "$ROUTER"
    log "gateway timeout: GCPBackendPolicy timeoutSec=$GATEWAY_TIMEOUT"
  fi
}

# MONITORING=gmp: PodMonitoring for the EPP's metrics port (auth disabled above), selecting the EPP pods the same
# way its Deployment does
add_epp_monitoring() {
  [[ $MONITORING == gmp ]] || return 0
  local sel
  sel=$(yq -o=json -I=0 'select(.kind == "Deployment") | .spec.selector.matchLabels' "$ROUTER")
  [[ -n $sel && $sel != null && $(wc -l <<<"$sel") -eq 1 ]] || die "MONITORING=gmp: expected one EPP Deployment in the router render"
  yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[].ports[] | select(.name == "metrics")' "$ROUTER" >/dev/null 2>&1 ||
    die "MONITORING=gmp: the EPP container has no port named metrics"
  yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[].args[] | select(. == "--metrics-endpoint-auth=false")' "$ROUTER" >/dev/null 2>&1 ||
    die "MONITORING=gmp: the EPP still requires auth on /metrics (router chart ignored monitoring.prometheus.auth.enabled=false)"
  log "MONITORING=gmp: PodMonitoring $NAME-epp scrapes the EPP's /metrics (auth disabled)"
  { echo "---"
    NAME=$NAME SEL=$sel INTERVAL=$MONITORING_INTERVAL yq -n '
      .apiVersion = "monitoring.googleapis.com/v1" | .kind = "PodMonitoring" |
      .metadata.name = strenv(NAME) + "-epp" | .metadata.labels."llm-d.ai/deployment" = strenv(NAME) |
      .spec.selector.matchLabels = (strenv(SEL) | from_json) | .spec.selector.matchLabels style="" |
      .spec.endpoints = [{"port": "metrics", "path": "/metrics", "interval": strenv(INTERVAL)}]'
  } >> "$ROUTER"
}

# ROUTER_SERVICE_ACCOUNT: the router uses a pre-existing ServiceAccount instead of creating its own. The chart
# has no option for it, so drop every ServiceAccount it renders (<name>-epp) and point the EPP Deployment and
# RBAC binding subjects at the given one. The chart's Roles/ClusterRoles are still created and bound to it.
# Never retargets a service-account-token Secret: that would mint a long-lived token for the operator's existing
# account (e.g. one with Workload Identity access). Such a render is refused instead.
use_router_sa() {
  [[ -n $ROUTER_SERVICE_ACCOUNT ]] || return 0
  local old; old=$(yq -N 'select(.kind == "ServiceAccount") | .metadata.name' "$ROUTER" | sort -u)
  [[ -n $old ]] || die "router render has no ServiceAccount to replace with $ROUTER_SERVICE_ACCOUNT"
  local tok; tok=$(OLD=$(echo $old) yq -N '(strenv(OLD) | split(" ")) as $old |
    select(.kind == "Secret" and .type == "kubernetes.io/service-account-token" and
           ([.metadata.annotations."kubernetes.io/service-account.name"] - $old | length) == 0) | .metadata.name' "$ROUTER")
  [[ -z $tok ]] || die "router render has a token Secret ($(echo $tok)) for a ServiceAccount ROUTER_SERVICE_ACCOUNT would replace; refusing to mint a token for $ROUTER_SERVICE_ACCOUNT. Use MONITORING=gmp (EPP metrics without auth) instead of the chart's token-based monitoring, or unset ROUTER_SERVICE_ACCOUNT"
  log "router uses existing ServiceAccount $ROUTER_SERVICE_ACCOUNT (not creating $(echo $old))"
  OLD=$(echo $old) SA=$ROUTER_SERVICE_ACCOUNT yq -i '
    (strenv(OLD) | split(" ")) as $old |
    select(.kind != "ServiceAccount" or ([.metadata.name] - $old | length) == 1) |
    (.. | select(tag == "!!map" and has("serviceAccountName") and ([.serviceAccountName] - $old | length) == 0) | .serviceAccountName) = strenv(SA) |
    (select(has("subjects")) | .subjects[] | select(.kind == "ServiceAccount" and ([.name] - $old | length) == 0) | .name) = strenv(SA)' "$ROUTER"
  local o; for o in $old; do
    ! grep -qxF -- "$o" <(yq -N '.. | select(tag == "!!map") | (.serviceAccountName // ""), ((.subjects // [])[] | select(.kind == "ServiceAccount") | .name), (.metadata.annotations."kubernetes.io/service-account.name" // ""), (select(.kind == "ServiceAccount") | .metadata.name)' "$ROUTER") ||
      die "router render still refers to ServiceAccount $o"
  done
}

# MONITORING=gmp: GKE Managed Prometheus scrapes vLLM. One PodMonitoring per deployment selects its model-server
# pods and scrapes every port of the vLLM containers (one per DP rank on wide-EP) except KV transfer / supervisor.
# vLLM's /metrics needs no auth. (The EPP's PodMonitoring comes from the router chart, see render_router.)
add_vllm_monitoring() {
  [[ $MONITORING == gmp ]] || return 0
  local ports; ports=$(yq -N "$VLLM_POD | .containers[] | select($VLLM_CTR) | (.ports // [])[] | .name // \"\"" "$MS" |
    grep -vE '^(nixl.*|supervisor)?$' | sort -u)
  [[ -n $ports ]] || die "MONITORING=gmp: the vLLM containers have no named ports to scrape; add a port name with modelserver.patches"
  log "MONITORING=gmp: PodMonitoring $NAME-modelserver scrapes /metrics on port(s) $(echo $ports)"
  { echo "---"
    NAME=$NAME PORTS=$(echo $ports) INTERVAL=$MONITORING_INTERVAL yq -n '
      .apiVersion = "monitoring.googleapis.com/v1" | .kind = "PodMonitoring" |
      .metadata.name = strenv(NAME) + "-modelserver" | .metadata.labels."llm-d.ai/deployment" = strenv(NAME) |
      .spec.selector.matchLabels."llm-d.ai/deployment" = strenv(NAME) |
      .spec.endpoints = [strenv(PORTS) | split(" ")[] | {"port": ., "path": "/metrics", "interval": strenv(INTERVAL)}]'
  } >> "$MS"
}

# Air-gapped (IMAGE_REGISTRY and/or IMAGE_REMOTES set): every image -> its remote repo, or IMAGE_REGISTRY
# per IMAGE_TEMPLATE (lib/images.sh); always pinned to the digest in .cache/images.lock
mirror_images() {
  [[ -n $IMAGE_REGISTRY || -n $IMAGE_REMOTES ]] || return 0
  local f img new
  for f in "$MS" "$ROUTER"; do
    while read -r img; do
      [[ -n $img ]] || continue
      new=$(mirror_image "$img") || exit 1
      OLD=$img NEW=$new yq -i '(.. | select(tag == "!!map" and has("image") and .image == strenv(OLD)) | .image) = strenv(NEW)' "$f"
    done < <(yq -N '.. | select(tag == "!!map" and has("image")) | .image' "$f" | sort -u)
  done
  SMOKE_IMAGE=$(mirror_image "$SMOKE_IMAGE") || exit 1
}
mirror_image() {
  local src dig; src=$(norm_image "$1")
  dig=$(awk -v s="$src" '$1 == s { print $2 }' "$ROOT/.cache/images.lock" 2>/dev/null)
  [[ -n $dig ]] || die "image $src is not in .cache/images.lock; re-run ./bundle.sh (with this profile) on a connected machine"
  [[ -n $IMAGE_REGISTRY || -n $(image_remote "${src%%/*}") ]] ||
    die "image $src: no remote repo for ${src%%/*} in IMAGE_REMOTES, and no IMAGE_REGISTRY to mirror it into"
  image_target "$src" "$dig"
}
