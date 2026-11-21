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
CMD='((.command // []) + (.args // [])) | join(" ")'                 # a container's command line
VLLM_CTR="$CMD | test(\"vllm\\\\s+serve\")"                         # a container running `vllm serve`
VLLM_POD=".. | select(tag == \"!!map\" and has(\"containers\")) | select([.containers[] | $VLLM_CTR] | any_c(.))"
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
    v=$VLLM_POD
    [[ $(yq -N "$v | .initContainers[0].name" "$B/modelserver.yaml" | sort -u) == fetch-model ]] || fail "$NAME" "vLLM pod without fetch-model as first init container"
    want="models--${MODEL//\//--} ${MODEL_BUCKET%/}/$(folder "$MODEL")"
    [[ -z $DRAFT_MODEL ]] || want+=$'\n'"models--${DRAFT_MODEL//\//--} ${MODEL_BUCKET%/}/$(folder "$DRAFT_MODEL")"
    [[ $(yq -o=json -I=0 "$v | .initContainers[0].env[] | select(.name == \"MODELS\") | .value" "$B/modelserver.yaml" | sort -u) == "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$want")" ]] ||
      fail "$NAME" "fetch-model MODELS is not: $want"
    # model swap: every vLLM command runs MODEL, pods are labelled with it, no foreign model id left
    cmds=$(yq -N -o=json -I=0 "$v | .containers[] | select($VLLM_CTR) | $CMD" "$B/modelserver.yaml")
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
      while read -r c; do
        re="vllm serve[ \\\\n]+${MODEL}[ \\\\n].*--speculative-config"   # model stays first positional
        [[ $c =~ $re ]] || fail "$NAME" "spec config missing or model not first: ${c:0:200}"
        [[ $c == *"\\\"model\\\":\\\"$DRAFT_MODEL\\\""* ]] || fail "$NAME" "spec config lacks draft model $DRAFT_MODEL"
      done <<<"$cmds"
    fi
    [[ $(yq -N "$v | .containers[] | select($VLLM_CTR) | (.env[] | select(.name == \"HF_HUB_OFFLINE\") | .value) + \":\" + (.volumeMounts[] | select(.name == \"model-cache\") | .mountPath + \":\" + (.readOnly | tostring))" "$B/modelserver.yaml" | sort -u) == "1:/model-cache:true" ]] || fail "$NAME" "vLLM container not offline / model-cache not mounted read-only"
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
# G4 sizing: plain nvidia.com/gpu (no RDMA DRA claims), 1 GPU / TP=1 per role, one slice per node, offload on prefill
B=.build/$(./deploy.sh profiles/gemma-4-31b-pd-tiered-g4-gke.yaml --name)/modelserver.yaml
[[ -z $(yq -N 'select(.kind=="ResourceClaimTemplate") | .metadata.name' "$B") && -z $(role prefill '.resourceClaims // ""') ]] || fail pd-g4 "G4 has no RDMA NICs: no DRA claims allowed"
for r in prefill decode; do
  [[ $(role $r '.containers[] | select(.name=="modelserver") | .resources.limits."nvidia.com/gpu"') == 1 ]] || fail pd-g4 "$r must request 1 GPU"
  [[ $(role $r '.containers[] | select(.name=="modelserver") | .args[]' | grep -c -- '--tensor-parallel-size=1') == 1 ]] || fail pd-g4 "$r must run TP=1"
done
[[ $(role prefill '.containers[] | select(.name=="modelserver") | .args[]') == *OffloadingConnector* ]] || fail pd-g4 "prefill lost the CPU tier"
[[ $(yq -N 'select(.kind=="DisaggregatedSet") | (.spec.slices | tostring) + " " + .spec.placementPolicy.topology' "$B") == "3 kubernetes.io/hostname" ]] || fail pd-g4 "want 3 slices, one per node"
[[ $(yq -N 'select(.kind=="HealthCheckPolicy" or .kind=="GCPBackendPolicy") | .kind' "${B%/*}/router.yaml" | sort -u | wc -l) -eq 2 ]] || fail pd-g4 "GKE Gateway needs HealthCheckPolicy + GCPBackendPolicy (provider: gke)"
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
  vllm=$(yq -N "$VLLM_POD | .containers[] | select($VLLM_CTR) | .name" ".build/$n/modelserver.yaml" | sort -u)
  while read -r c img; do
    if grep -qx "$c" <<<"$vllm"; then [[ $img == registry.test/vllm-custom:1.2.3 ]] || fail "$n" "vLLM container $c kept $img"
    else grep -qx "$c $img" "$T/before" || fail "$n" "non-vLLM container $c changed to $img"; fi
  done < "$T/after"
done
echo "ok  modelserver.image overrides only vLLM containers"
# model swap on script-form overlays (bash -c "... vllm serve <model> ..."): the id is replaced inside the script
for p in profiles/tiered-cpu-gke.yaml profiles/wide-ep-gke.yaml; do
  up=$(yq .model "$p")
  yq '.model = "test-org/Swapped-Model-7B"' "$p" > "$T/swap.yaml"
  n=$(./deploy.sh "$T/swap.yaml" --name)
  ./deploy.sh "$T/swap.yaml" --dry-run >/dev/null 2>&1 || fail "$n" "render with a swapped model failed"
  cmds=$(yq -N -o=json -I=0 "$VLLM_POD | .containers[] | select($VLLM_CTR) | $CMD" ".build/$n/modelserver.yaml")
  while read -r c; do
    [[ $c == *"vllm serve"* && $c == *test-org/Swapped-Model-7B* ]] || fail "$n" "script does not serve the swapped model: ${c:0:160}"
    [[ $c != *"$up"* ]] || fail "$n" "script still mentions $up"
  done <<<"$cmds"
done
echo "ok  model swap inside script-form overlays"

# --help: header text on stdout, exit 0, no network or profile needed
for s in deploy.sh bundle.sh; do
  for f in -h --help; do
    out=$(./$s $f) || fail "$s" "$f should exit 0"
    [[ $out == *"./$s --help"* && $out != *"set -euo"* && $out != "#"* ]] || fail "$s" "$f prints the wrong text"
  done
done
echo "ok  deploy.sh and bundle.sh --help"
# --env-file: loads and exports the file (wins over the shell); typos in the file or the shell stop the run
P=profiles/gemma-4-31b-pd-tiered-g4-gke.yaml
printf 'NAMESPACE=from-file\nexport SERVICE_ACCOUNT=sa-file\n' > "$T/ok.env"
[[ $(NAMESPACE=from-shell ./deploy.sh "$P" --env --env-file "$T/ok.env" 2>/dev/null | grep -E '^(NAMESPACE|SERVICE_ACCOUNT)=') == $'NAMESPACE=from-file\nSERVICE_ACCOUNT=sa-file' ]] ||
  fail env-file "--env-file values not loaded or not winning over the shell"
printf 'IMAGE_REMOTE=docker.io=x\n' > "$T/typo.env"
[[ $(./deploy.sh -e "$T/typo.env" "$P" --name 2>&1) == *"did you mean IMAGE_REMOTES"* ]] || fail env-file "typo in env file not caught"
[[ $(BUNDLE_STEP=images ./deploy.sh "$P" --name 2>&1) == *"did you mean BUNDLE_STEPS"* ]] || fail env-file "typo in shell env not caught"
! ./deploy.sh -e no-such-env "$P" --name >/dev/null 2>&1 || fail env-file "missing env file should fail"
printf "IMAGE_REMOTES= 'docker.io=r/d'\n" > "$T/space.env"   # bash would run the value as a command, leaving it unset
[[ $(./deploy.sh -e "$T/space.env" "$P" --name 2>&1) == *"line 1: space after '='"* ]] || fail env-file "space after = not caught"
./deploy.sh -e envs/example.env "$P" --name >/dev/null 2>&1 || fail env-file "envs/example.env must load cleanly"
echo "ok  --env-file loading and typo checks"

# install-lws.sh (needs .cache/charts/lws-1.0.0 + its lock entry from LWS_CHART=1 ./bundle.sh): image mapped and digest-pinned
if [[ -f .cache/charts/lws-1.0.0/Chart.yaml ]] && grep -q '^registry.k8s.io/lws/lws:' .cache/images.lock 2>/dev/null; then
  out=$(IMAGE_REGISTRY= IMAGE_REMOTES='registry.k8s.io=reg.test/k8s' ./install-lws.sh --dry-run 2>/dev/null)
  [[ $out == *"image.manager.repository=reg.test/k8s/lws/lws"* && $out == *"image.manager.tag=v1.0.0@sha256:"* &&
     $out == *"enableDisaggregatedSet=true"* && $out == *"-f .cache/charts/lws-1.0.0/crds"* ]] || fail install-lws "dry run wrong: $out"
  ! IMAGE_REGISTRY= IMAGE_REMOTES='docker.io=x' ./install-lws.sh --dry-run >/dev/null 2>&1 || fail install-lws "unmapped registry.k8s.io should fail"
  echo "ok  install-lws.sh maps and pins the LWS image"
fi
for f in -h --help; do [[ $(./install-lws.sh $f) == *"./install-lws.sh --env-file dev --dry-run"* ]] || fail install-lws "$f"; done

# bundle.sh split: an unknown step is refused before any network access
! BUNDLE_STEPS=bogus ./bundle.sh >/dev/null 2>&1 || fail bundle "BUNDLE_STEPS=bogus should fail"
echo "ok  bundle.sh rejects unknown BUNDLE_STEPS"

# air-gapped mode (needs .cache/images.lock from ./bundle.sh): every image -> registry, pinned by digest
if [[ -f .cache/images.lock ]]; then
  for p in profiles/*.yaml; do
    n=$(./deploy.sh "$p" --name)
    IMAGE_REGISTRY=registry.test/llm-d ./deploy.sh "$p" --dry-run >/dev/null 2>&1 || fail "$n" "air-gapped render failed (image missing from .cache/images.lock? re-run ./bundle.sh)"
    bad=$(yq -N '.. | select(tag == "!!map" and has("image")) | .image' ".build/$n/modelserver.yaml" ".build/$n/router.yaml" | grep -v '^registry\.test/llm-d/.*@sha256:[0-9a-f]\{64\}$' || true)
    [[ -z $bad ]] || fail "$n" "images not mirrored/pinned: $(echo $bad)"
  done
  echo "ok  air-gapped image rewrite for all profiles"
  # custom layout: IMAGE_TEMPLATE drives both the mirror list (bundle.sh) and this rewrite, via lib/images.sh
  for p in profiles/*.yaml; do
    n=$(./deploy.sh "$p" --name)
    IMAGE_REGISTRY=registry.test/llm-d IMAGE_TEMPLATE='{registry}/{path}:{tag}' ./deploy.sh "$p" --dry-run >/dev/null 2>&1 || fail "$n" "render with IMAGE_TEMPLATE failed"
    bad=$(yq -N '.. | select(tag == "!!map" and has("image")) | .image' ".build/$n/modelserver.yaml" ".build/$n/router.yaml" | grep -v '^registry\.test/llm-d/[^@]*:[^/@]*$' || true)
    [[ -z $bad ]] || fail "$n" "IMAGE_TEMPLATE not applied: $(echo $bad)"
  done
  echo "ok  IMAGE_TEMPLATE layout for all profiles"
  # Artifact Registry remote repos (IMAGE_REMOTES): upstream path kept, host -> its repo, pinned by digest
  R=asia-south1-docker.pkg.dev/p
  remotes="docker.io=$R/dh ghcr.io=$R/gh gcr.io=$R/gc quay.io=$R/qy"
  for p in profiles/*.yaml; do
    n=$(./deploy.sh "$p" --name)
    IMAGE_REMOTES=$remotes ./deploy.sh "$p" --dry-run >/dev/null 2>&1 || fail "$n" "render with IMAGE_REMOTES failed"
    imgs=$(yq -N '.. | select(tag == "!!map" and has("image")) | .image' ".build/$n/modelserver.yaml" ".build/$n/router.yaml")
    bad=$(grep -vE "^$R/(dh|gh|gc|qy)/[^@]+@sha256:[0-9a-f]{64}$" <<<"$imgs" || true)
    [[ -z $bad ]] || fail "$n" "images not pulled through remote repos: $(echo $bad)"
    ! grep -qE "^$R/(dh|gh|gc|qy)/(docker\.io|ghcr\.io|gcr\.io|quay\.io)/" <<<"$imgs" || fail "$n" "remote repo path still contains the upstream host"
  done
  n=$(./deploy.sh profiles/gemma-4-31b-llmd-1.0-vllm-0.34-agentgateway.yaml --name)
  grep -q "^ *image: $R/dh/vllm/vllm-openai@sha256:" ".build/$n/modelserver.yaml" || fail "$n" "vLLM not from the docker.io remote repo"
  grep -q "^ *image: $R/gh/llm-d/llm-d-router-endpoint-picker@sha256:" ".build/$n/router.yaml" || fail "$n" "EPP not from the ghcr.io remote repo"
  # mixed: hosts without a remote repo still go to IMAGE_REGISTRY; with neither, the render stops
  IMAGE_REMOTES="ghcr.io=$R/gh" IMAGE_REGISTRY=registry.test/llm-d ./deploy.sh profiles/gemma-4-31b-llmd-1.0-vllm-0.34-agentgateway.yaml --dry-run >/dev/null 2>&1 || fail "$n" "mixed render failed"
  grep -q "^ *image: $R/gh/llm-d/llm-d-router-endpoint-picker@" ".build/$n/router.yaml" && grep -q '^ *image: registry.test/llm-d/docker.io/vllm/vllm-openai@' ".build/$n/modelserver.yaml" ||
    fail "$n" "mixed IMAGE_REMOTES + IMAGE_REGISTRY not split by host"
  ! IMAGE_REMOTES="ghcr.io=$R/gh" ./deploy.sh profiles/gemma-4-31b-llmd-1.0-vllm-0.34-agentgateway.yaml --dry-run >/dev/null 2>&1 || fail "$n" "unmapped host without IMAGE_REGISTRY should fail"
  echo "ok  IMAGE_REMOTES pull-through for all profiles"
fi
echo "all checks passed"
