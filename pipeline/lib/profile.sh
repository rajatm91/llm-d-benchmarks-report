# Settings: defaults, environment, then the profile. Sourced by deploy.sh.

# ---- defaults (a profile overrides these) ------------------------------------------
LLMD_REF=565373b741e90bffa27930b4669c6e1f222f6225   # llm-d/llm-d commit these profiles were written against
ROUTER_CHART_VERSION=v0
ROUTER_GATEWAY_CHART=oci://ghcr.io/llm-d/charts/llm-d-router-gateway
ROUTER_STANDALONE_CHART=oci://ghcr.io/llm-d/charts/llm-d-router-standalone
ROUTER_MODE=gateway            # gateway | standalone
GATEWAY_NAME=llm-d-inference-gateway
GATEWAY_NAMESPACE=""           # "" = same namespace as the deployment
GATEWAY_PROVIDER=none          # gke | agentgateway | istio | none  (selects HealthCheckPolicy / DestinationRule)
BASE_MODEL=""                  # set when several models share one Gateway (needs IPP, see README)
GATEWAY_TIMEOUT=""             # gateway.timeoutSec: request timeout; "" = chart's 300s
COMPONENTS=""; PATCHES=""; ROUTER_VALUES=""; ROUTER_SET=""
WAIT_TIMEOUT=60m
MODEL_ALIAS=""                 # short model slug when the HF name makes NAME too long
MODEL_GCS_URI=""               # "" = $MODEL_BUCKET/<folder of MODEL>
DRAFT_MODEL=""                 # HF id of a draft / EAGLE model for speculative decoding
SPEC_CONFIG='{"num_speculative_tokens": 5}'   # vLLM --speculative-config; "model" is filled from DRAFT_MODEL
MS_ARGS_JSON='[]'; MS_TP=""; MS_REPLICAS=""   # modelserver.args / tensorParallel / replicas
MS_IMAGE=""                    # modelserver.image: replaces the overlay's vLLM image

# ---- environment (the same for every profile; envs/<env>.env or Jenkins) ------------
NAMESPACE=${NAMESPACE:-llm-d}                           # shared by every model
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-llm-d-modelserver}   # pre-existing in NAMESPACE; model-server pods run as it
ROUTER_SERVICE_ACCOUNT=${ROUTER_SERVICE_ACCOUNT:-}      # "" = the router chart creates <name>-epp; else this pre-existing SA
MONITORING=${MONITORING:-}                              # "" | gmp: PodMonitoring for vLLM and the EPP (GKE Managed Prometheus)
MONITORING_INTERVAL=${MONITORING_INTERVAL:-15s}
[[ -z $MONITORING || $MONITORING == gmp ]] || die "MONITORING must be empty or gmp, got '$MONITORING'"
# Weights are already in GCS (stored by the garuda repo), one folder per model:
#   google/gemma-4-31B-it -> gs://models_registry/google__gemma_4_31b_it
MODEL_BUCKET=${MODEL_BUCKET:-gs://models_registry}
MODEL_CACHE_PATH=${MODEL_CACHE_PATH:-/mnt/stateful_partition/kube-ephemeral-ssd/llm-d-models}  # hostPath (GKE local SSD)
DOWNLOADER_IMAGE=${DOWNLOADER_IMAGE:-gcr.io/google.com/cloudsdktool/google-cloud-cli:slim}
SMOKE_IMAGE=${SMOKE_IMAGE:-docker.io/curlimages/curl:8.11.1}
# Air-gapped: every image is rewritten to a pull-through repo (IMAGE_REMOTES) or into IMAGE_REGISTRY
# per IMAGE_TEMPLATE. Both are read in lib/images.sh.
IMAGE_REGISTRY=${IMAGE_REGISTRY:-}                      # e.g. us-docker.pkg.dev/my-proj/llm-d

# load_profile: profile YAML -> the variables above, then the derived NAME
load_profile() {
  [[ -f $PROFILE ]] || die "profile not found: $PROFILE"
  yq -e 'tag == "!!map"' "$PROFILE" >/dev/null 2>&1 || die "$PROFILE is not a YAML mapping"

  # unknown keys are typos: fail instead of silently using a default
  local bad
  bad=$(yq -N '(keys - ["model","modelAlias","strategy","draftModel","speculativeConfig",
                        "modelserver","router","gateway","weights","llmdRef","waitTimeout"])
    + ((.modelserver // {}) | keys - ["overlay","components","patches","args","tensorParallel","replicas","image"] | map("modelserver." + .))
    + ((.router // {}) | keys - ["mode","values","set","chartVersion"] | map("router." + .))
    + ((.gateway // {}) | keys - ["provider","name","namespace","baseModel","timeoutSec"] | map("gateway." + .))
    + ((.weights // {}) | keys - ["gcsUri"] | map("weights." + .)) | .[]' "$PROFILE")
  [[ -z $bad ]] || die "unknown key(s) in $PROFILE: $(echo $bad)"

  # scalar -> var, list -> space-joined var, map -> JSON; absent keys keep the defaults
  eval "$(yq -N '
    [ ["MODEL", .model], ["MODEL_ALIAS", .modelAlias], ["STRATEGY", .strategy], ["DRAFT_MODEL", .draftModel],
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
      ["GATEWAY_NAMESPACE", .gateway.namespace], ["BASE_MODEL", .gateway.baseModel], ["GATEWAY_TIMEOUT", .gateway.timeoutSec],
      ["MODEL_GCS_URI", .weights.gcsUri], ["LLMD_REF", .llmdRef], ["WAIT_TIMEOUT", .waitTimeout] ]
    | .[] | select(.[1] != null) | .[0] + "=" + (.[1] | tostring | @sh)' "$PROFILE")"

  # speculativeConfig needs either a draftModel or a self-contained method (mtp, ngram, ...)
  [[ $(yq '.speculativeConfig != null and .draftModel == null and .speculativeConfig.method == null' "$PROFILE") == false ]] ||
    die "speculativeConfig needs draftModel, or a method that brings its own drafter (e.g. method: mtp)"
  SPEC_SET=$(yq '.speculativeConfig != null' "$PROFILE")
  : "${MODEL:?}" "${STRATEGY:?profile must set STRATEGY}" "${MODELSERVER_OVERLAY:?}"

  # naming standard: <model>-<strategy>-<engine>, engine from the overlay path
  MODEL_SLUG=$(slug "${MODEL_ALIAS:-${MODEL##*/}}")
  STRATEGY=$(slug "$STRATEGY")
  ENGINE=$(grep -oE '/(vllm|sglang|trtllm)/' <<<"/$MODELSERVER_OVERLAY/" | head -1 | tr -d /) || true
  [[ -n $ENGINE ]] || die "cannot tell the engine from $MODELSERVER_OVERLAY: the path must contain /vllm/, /sglang/ or /trtllm/"
  NAME=$MODEL_SLUG-$STRATEGY-$ENGINE
  # 40: helm release names cap at 53 and the chart/LWS append suffixes (-epp, -prefill-<hash>, ...)
  [[ $NAME =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#NAME} -le 40 ]] ||
    die "derived name '$NAME' must be a DNS label of at most 40 chars; set modelAlias"
  GATEWAY_NAMESPACE=${GATEWAY_NAMESPACE:-$NAMESPACE}
}

slug() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }

# print_env: the resolved settings as shell assignments (./deploy.sh <profile> --env; used by test.sh, bundle.sh)
print_env() {
  local v
  for v in NAME NAMESPACE SERVICE_ACCOUNT ROUTER_SERVICE_ACCOUNT MONITORING MODEL STRATEGY ENGINE DRAFT_MODEL SPEC_CONFIG MODELSERVER_OVERLAY COMPONENTS PATCHES \
           ROUTER_MODE ROUTER_VALUES MS_TP MS_REPLICAS MS_ARGS_JSON MS_IMAGE SPEC_SET GATEWAY_PROVIDER GATEWAY_NAME GATEWAY_NAMESPACE \
           BASE_MODEL GATEWAY_TIMEOUT MODEL_BUCKET LLMD_REF WAIT_TIMEOUT SMOKE_IMAGE; do
    printf '%s=%q\n' "$v" "${!v}"
  done
}
