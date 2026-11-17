#!/usr/bin/env bash
# Offline check: render every profile and assert the wiring a cluster would only reveal at runtime.
# All profiles render into the SAME namespace, so this also proves models can coexist there.
set -euo pipefail
cd "$(dirname "$0")"
fail() { echo "FAIL [$1]: $2" >&2; exit 1; }
SA=${SERVICE_ACCOUNT:-llm-d-modelserver}
export MODEL_BUCKET=${MODEL_BUCKET:-gs://llm-d-test-models}   # weights always come from GCS (garuda layout)
# garuda folder naming, spelled out independently of deploy.sh's implementation
folder() { python3 -c 'import re,sys; o,n=sys.argv[1].lower().split("/",1); print(re.sub(r"[^a-z0-9_]+","_",o)+"__"+re.sub(r"[^a-z0-9_]+","_",n))' "$1"; }
[[ $(folder google/gemma-4-31B-it) == google__gemma_4_31b_it ]] || fail layout "folder() disagrees with garuda's documented example"
WORKLOADS='.kind == "Deployment" or .kind == "LeaderWorkerSet" or .kind == "DisaggregatedSet"'
POD_LABELS='.. | select(tag == "!!map" and has("metadata") and (.spec | tag) == "!!map" and (.spec | has("containers"))) | .metadata.labels'
# exit 0 if every selector label is on the pod labels: matches <selector-json> <labels-json>
matches() { python3 -c 'import json,sys; s,l=json.loads(sys.argv[1]),json.loads(sys.argv[2]); sys.exit(any(l.get(k)!=v for k,v in s.items()))' "$1" "$2"; }

NAMES=()
for p in profiles/*.yaml; do
  NAME=$(./deploy.sh "$p" --name) || fail "$p" "name derivation failed"
  NAMES+=("$NAME")
  ( eval "$(./deploy.sh "$p" --env)"   # same YAML loader + defaults as deploy.sh
    [[ $NAME =~ ^[a-z0-9-]+-${STRATEGY}-(vllm|sglang|trtllm)$ ]] || fail "$NAME" "name does not follow <model>-<strategy>-<engine>"
    ./deploy.sh "$p" --dry-run >/dev/null 2>&1 || fail "$NAME" "render failed: ./deploy.sh $p --dry-run"
    B=.build/$NAME
    # pre-existing ServiceAccount only
    [[ -z $(yq -N 'select(.kind == "ServiceAccount") | .metadata.name' "$B/modelserver.yaml") ]] || fail "$NAME" "renders its own ServiceAccount"
    sas=$(yq -N '.. | select(tag == "!!map" and has("serviceAccountName")) | .serviceAccountName' "$B/modelserver.yaml" | sort -u)
    [[ $sas == "$SA" ]] || fail "$NAME" "pods use ServiceAccount(s) '$sas', want '$SA'"
    # pool selects every model-server pod of THIS deployment and nothing else in the manifest (e.g. DaemonSets)
    sel=$(yq -o=json -I=0 'select(.kind == "InferencePool") | .spec.selector.matchLabels' "$B/router.yaml")
    [[ $(yq -N '."llm-d.ai/deployment"' <<<"$sel") == "$NAME" ]] || fail "$NAME" "pool selector lacks llm-d.ai/deployment=$NAME: $sel"
    while read -r l; do matches "$sel" "$l" || fail "$NAME" "pool $sel misses pod template $l"; done \
      < <(yq -o=json -I=0 "select($WORKLOADS) | $POD_LABELS" "$B/modelserver.yaml")
    while read -r l; do [[ -z $l ]] || ! matches "$sel" "$l" || fail "$NAME" "pool also selects non-model-server pods $l"; done \
      < <(yq -o=json -I=0 "select(($WORKLOADS) | not) | $POD_LABELS" "$B/modelserver.yaml")
    # router plugin selectors that name a workload (rollout screener) must name one we render
    wls=$(yq -N "select($WORKLOADS) | .metadata.name" "$B/modelserver.yaml")
    for ref in $(grep -oE 'x-k8s\.io/name=[-a-z0-9]+' "$B/router.yaml" | cut -d= -f2 | sort -u); do
      grep -qx "$ref" <<<"$wls" || fail "$NAME" "router references workload '$ref' but render has: $(echo $wls)"
    done
    # GCS weights: every vLLM pod fetches first, loads offline, never needs the HF token
    v='.. | select(tag == "!!map" and has("containers")) | select([.containers[] | ((.command // []) + (.args // [])) | join(" ")] | any_c(test("vllm\\s+serve")))'
    [[ $(yq -N "$v | .initContainers[0].name" "$B/modelserver.yaml" | sort -u) == fetch-model ]] || fail "$NAME" "vLLM pod without fetch-model as first init container"
    want="models--${MODEL//\//--} ${MODEL_BUCKET%/}/$(folder "$MODEL")"
    [[ -z $DRAFT_MODEL ]] || want+=$'\n'"models--${DRAFT_MODEL//\//--} ${MODEL_BUCKET%/}/$(folder "$DRAFT_MODEL")"
    [[ $(yq -o=json -I=0 "$v | .initContainers[0].env[] | select(.name == \"MODELS\") | .value" "$B/modelserver.yaml" | sort -u) == "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$want")" ]] ||
      fail "$NAME" "fetch-model MODELS is not: $want"
    # model swap: every vLLM command runs MODEL, pods are labelled with it, no foreign model id left
    cmds=$(yq -N -o=json -I=0 "$v | .containers[] | select(((.command // []) + (.args // [])) | join(\" \") | test(\"vllm\\s+serve\")) | ((.command // []) + (.args // [])) | join(\" \")" "$B/modelserver.yaml")
    while read -r c; do [[ $c == *"$MODEL"* ]] || fail "$NAME" "vLLM command does not run $MODEL: ${c:0:160}"; done <<<"$cmds"
    [[ $(yq -N "select($WORKLOADS) | $POD_LABELS | .\"llm-d.ai/model\"" "$B/modelserver.yaml" | sort -u) == "${MODEL##*/}" ]] || fail "$NAME" "pod llm-d.ai/model label is not ${MODEL##*/}"
    # sizing + extra args land in every vLLM container
    if [[ -n $MS_TP ]]; then
      [[ $(grep -oE -- '--tensor-parallel-size=[0-9]+' <<<"$cmds" | sort -u) == "--tensor-parallel-size=$MS_TP" ]] || fail "$NAME" "TP flag is not $MS_TP"
      [[ $(yq -N "select(.kind == \"Deployment\") | .spec.template.spec.containers[].resources[] | to_entries[] | select(.key | test(\"gpu$\")) | .value" "$B/modelserver.yaml" | sort -u) == "$MS_TP" ]] || fail "$NAME" "GPU count is not $MS_TP"
    fi
    for a in $(yq -r '.[] | select(test("^--")) | sub("=.*"; "")' <<<"$MS_ARGS_JSON"); do
      [[ $(grep -cF -- "$a" <<<"$cmds") -eq $(wc -l <<<"$cmds") ]] || fail "$NAME" "arg $a missing from a vLLM container"
    done
    [[ $SPEC_SET != true ]] || [[ $(grep -c 'speculative-config' <<<"$cmds") -eq $(wc -l <<<"$cmds") ]] || fail "$NAME" "speculativeConfig not applied"
    # draft model: --speculative-config right after the positional model in every vLLM container
    if [[ -n $DRAFT_MODEL ]]; then
      cmds=$(yq -N -o=json -I=0 "$v | .containers[] | select(((.command // []) + (.args // [])) | join(\" \") | test(\"vllm\\s+serve\")) | ((.command // []) + (.args // [])) | join(\" \")" "$B/modelserver.yaml")
      while read -r c; do
        re="vllm serve[ \\\\n]+${MODEL}[ \\\\n].*--speculative-config"   # model stays first positional
        [[ $c =~ $re ]] || fail "$NAME" "spec config missing or model not first: ${c:0:200}"
        [[ $c == *"\\\"model\\\":\\\"$DRAFT_MODEL\\\""* ]] || fail "$NAME" "spec config lacks draft model $DRAFT_MODEL"
      done <<<"$cmds"
    fi
    [[ $(yq -N "$v | .containers[] | select(((.command // []) + (.args // [])) | join(\" \") | test(\"vllm\\s+serve\")) | (.env[] | select(.name == \"HF_HUB_OFFLINE\") | .value) + \":\" + (.volumeMounts[] | select(.name == \"model-cache\") | .mountPath + \":\" + (.readOnly | tostring))" "$B/modelserver.yaml" | sort -u) == "1:/model-cache:true" ]] || fail "$NAME" "vLLM container not offline / model-cache not mounted read-only"
    ! grep -q 'llm-d-hf-token' "$B/modelserver.yaml" || fail "$NAME" "still references the HF token secret"
    [[ -z $(yq -N "select(($WORKLOADS) | not) | .. | select(tag == \"!!map\" and has(\"initContainers\")) | .initContainers[] | select(.name == \"fetch-model\") | .name" "$B/modelserver.yaml") ]] || fail "$NAME" "fetch-model injected into a non-model-server pod"
    # HTTPRoute attaches to the existing Gateway and points at this release's pool
    r=$(yq -N 'select(.kind=="HTTPRoute") | .spec.parentRefs[0].namespace + "/" + .spec.parentRefs[0].name + " -> " + .spec.rules[0].backendRefs[0].name' "$B/router.yaml")
    [[ $r == "$GATEWAY_NAMESPACE/$GATEWAY_NAME -> $NAME" ]] || fail "$NAME" "bad HTTPRoute wiring: $r"
    [[ $GATEWAY_PROVIDER != gke ]] || yq -e 'select(.kind=="HealthCheckPolicy")' "$B/router.yaml" >/dev/null || fail "$NAME" "gke provider without HealthCheckPolicy"
    echo "ok  $NAME  route=$r" )
done

# shared namespace: no two deployments may produce the same kind/name
dups=$(for n in "${NAMES[@]}"; do yq -N '.kind + "/" + .metadata.name' ".build/$n/modelserver.yaml" ".build/$n/router.yaml"; done | grep -v '^/$' | sort | uniq -d)
[[ -z $dups ]] || fail shared-namespace "resource names collide across profiles: $dups"

# combo-specific: P/D + tiered keeps NIXL to decode, adds CPU offload on prefill only, keeps overlay volumes
B=.build/$(./deploy.sh profiles/pd-tiered-cpu-agentgateway.yaml --name)/modelserver.yaml
role() { yq -N "select(.kind==\"DisaggregatedSet\") | .spec.roles[] | select(.name==\"$1\") | .spec.leaderWorkerTemplate.workerTemplate.spec$2" "$B"; }
[[ $(role prefill '.containers[0].args[8]') == *'"NixlConnector","kv_role":"kv_producer"'*'"OffloadingConnector"'* ]] || fail pd-tiered "prefill connector not NIXL+Offloading"
[[ $(role decode '.containers[0].args[8]') != *Offloading* ]] || fail pd-tiered "decode should not offload"
[[ $(role prefill '.volumes[] | select(.name=="shm") | .emptyDir.sizeLimit') == 110Gi ]] || fail pd-tiered "shm not resized"
[[ $(role prefill '.volumes | length') == $(role decode '.volumes | length') ]] || fail pd-tiered "prefill lost volumes during merge"
W=.build/$(./deploy.sh profiles/wide-ep-gke.yaml --name)/router.yaml
[[ $(yq -N 'select(.kind=="InferencePool") | .spec.targetPorts | length' "$W") == 8 ]] || fail wide-ep "pool must target all 8 DP rank ports"
# modelserver.image: replaces the vLLM containers' image only; sidecars / init / helper containers keep theirs
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
imgs() { yq -N '.. | select(tag == "!!map" and has("containers")) | ((.initContainers // [])[], .containers[]) | .name + " " + .image' "$1" | sort; }
for p in profiles/pd-gke.yaml profiles/wide-ep-pd-tiered-glm-agentgateway.yaml; do
  n=$(./deploy.sh "$p" --name)
  ./deploy.sh "$p" --dry-run >/dev/null 2>&1; imgs ".build/$n/modelserver.yaml" > "$T/before"
  yq '.modelserver.image = "registry.test/vllm-custom:1.2.3"' "$p" > "$T/img.yaml"
  ./deploy.sh "$T/img.yaml" --dry-run >/dev/null 2>&1 || fail "$n" "render with modelserver.image failed"
  imgs ".build/$n/modelserver.yaml" > "$T/after"
  vllm=$(yq -N '.. | select(tag == "!!map" and has("containers")) | .containers[] | select(((.command // []) + (.args // [])) | join(" ") | test("vllm\\s+serve")) | .name' ".build/$n/modelserver.yaml" | sort -u)
  while read -r c img; do
    if grep -qx "$c" <<<"$vllm"; then [[ $img == registry.test/vllm-custom:1.2.3 ]] || fail "$n" "vLLM container $c kept $img"
    else grep -qx "$c $img" "$T/before" || fail "$n" "non-vLLM container $c changed to $img"; fi
  done < "$T/after"
done
echo "ok  modelserver.image overrides only vLLM containers"

# air-gapped mode (needs .cache/images.lock from ./bundle.sh): every image -> registry, pinned by digest
if [[ -f .cache/images.lock ]]; then
  for p in profiles/*.yaml; do
    n=$(./deploy.sh "$p" --name)
    IMAGE_REGISTRY=registry.test/llm-d ./deploy.sh "$p" --dry-run >/dev/null 2>&1 || fail "$n" "air-gapped render failed (image missing from .cache/images.lock? re-run ./bundle.sh)"
    bad=$(yq -N '.. | select(tag == "!!map" and has("image")) | .image' ".build/$n/modelserver.yaml" ".build/$n/router.yaml" | grep -v '^registry\.test/llm-d/.*@sha256:[0-9a-f]\{64\}$' || true)
    [[ -z $bad ]] || fail "$n" "images not mirrored/pinned: $(echo $bad)"
  done
  echo "ok  air-gapped image rewrite for all profiles"
fi
echo "all checks passed"
