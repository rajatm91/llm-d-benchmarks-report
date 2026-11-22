# Cluster steps: preflight, apply, wait, smoke test, delete. Sourced by deploy.sh.
# deploy.sh has no cluster setting of its own: everything goes to kubectl's current context.

# Fail before applying anything when a prerequisite is missing, with the fix in the message.
preflight() {
  log "preflight"
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || die "namespace $NAMESPACE not found (shared namespace is pre-created)"
  kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" >/dev/null 2>&1 ||
    die "ServiceAccount $NAMESPACE/$SERVICE_ACCOUNT not found (model-server pods run as this pre-existing SA)"
  [[ -z $ROUTER_SERVICE_ACCOUNT ]] || kubectl get serviceaccount "$ROUTER_SERVICE_ACCOUNT" -n "$NAMESPACE" >/dev/null 2>&1 ||
    die "ServiceAccount $NAMESPACE/$ROUTER_SERVICE_ACCOUNT not found (ROUTER_SERVICE_ACCOUNT: the router EPP runs as this pre-existing SA)"
  has_crd inferencepools.inference.networking.k8s.io ||
    die "InferencePool CRD missing. Install: kubectl apply -f $ROOT/.cache/crds/inference-extension-v1.yaml (from bundle.sh), or let GKE >=1.34.0-gke.1626000 with Gateway API enabled manage it"
  ! yq -e 'select(.kind == "PodMonitoring")' "$MS" "$ROUTER" >/dev/null 2>&1 || has_crd podmonitorings.monitoring.googleapis.com ||
    die "MONITORING=gmp but the PodMonitoring CRD is missing: enable Managed Service for Prometheus on the cluster (gcloud container clusters update <c> --enable-managed-prometheus)"
  if yq -e 'select(.kind == "InferenceObjective")' "$ROUTER" >/dev/null 2>&1; then
    has_crd inferenceobjectives.llm-d.ai ||
      die "InferenceObjective CRD missing (router.inferenceObjectives). Install: kubectl apply -f $ROOT/.cache/crds/llm-d-router.yaml (from ROUTER_CRDS=1 ./bundle.sh)"
  fi
  if [[ -n $NEEDS_LWS ]]; then
    has_crd leaderworkersets.leaderworkerset.x-k8s.io ||
      die "$NEEDS_LWS needs the LWS controller (>=v0.11.1, --set enableDisaggregatedSet=true). See $LLMD/guides/pd-disaggregation/README.md#prerequisites"
    [[ $NEEDS_LWS != DisaggregatedSet ]] || has_crd disaggregatedsets.disaggregatedset.x-k8s.io ||
      die "DisaggregatedSet CRD missing: reinstall LWS with --set enableDisaggregatedSet=true"
  fi
  [[ $ROUTER_MODE != gateway ]] || preflight_gateway
}
has_crd() { kubectl get crd "$1" >/dev/null 2>&1; }

preflight_gateway() {
  local gw from others
  gw=$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o yaml 2>/dev/null) ||
    die "Gateway $GATEWAY_NAMESPACE/$GATEWAY_NAME not found. Create one: kubectl apply -k $LLMD/guides/recipes/gateway/<agentgateway|gke-l7-rilb|gke-l7-regional-external-managed> -n $GATEWAY_NAMESPACE"
  if [[ $GATEWAY_NAMESPACE != "$NAMESPACE" ]]; then
    from=$(yq '[.spec.listeners[].allowedRoutes.namespaces.from // "Same"] | unique | join(",")' <<<"$gw")
    [[ $from == *All* || $from == *Selector* ]] ||
      die "Gateway listeners only allow routes from: $from. Set allowedRoutes.namespaces.from: All (or a Selector matching $NAMESPACE)"
    [[ $from == *All* ]] || log "WARN: Gateway uses a namespace Selector; make sure namespace $NAMESPACE matches it"
  fi
  # Our route is a catch-all (PathPrefix "/"). Another catch-all on the same Gateway conflicts (oldest wins);
  # routes on specific paths (/optimized-baseline) or with header matches coexist (longest match wins).
  [[ -n $BASE_MODEL ]] && return 0
  others=$(kubectl get httproute -A -o yaml | catchall_routes)
  [[ -z $others ]] ||
    die "Gateway already has catch-all \"/\" routes ($(tr '\n' ' ' <<<"$others")); set gateway.baseModel and install IPP so routes match on X-Gateway-Base-Model-Name"
}
# catchall_routes < HTTPRouteList: ns/name of other routes on $GATEWAY_NAME that match every request
# (a rule with no matches, or a match on path "/" without headers)
catchall_routes() {
  GW=$GATEWAY_NAME NAME=$NAME NS=$NAMESPACE yq -N '.items[]
    | select(.spec.parentRefs[].name == strenv(GW))
    | select(.metadata.name != strenv(NAME) or .metadata.namespace != strenv(NS))
    | select([.spec.rules[] | (.matches // [{}])[] | select((.path.value // "/") == "/" and ((.headers // []) | length) == 0)] | length > 0)
    | .metadata.namespace + "/" + .metadata.name' | sort -u
}

# The chart has no hooks or lookups, so its render is exactly what helm would install: apply the
# reviewed/archived manifest itself (same as the model servers) instead of re-rendering in helm.
apply_all() {
  log "applying router"
  kubectl apply -n "$NAMESPACE" --server-side -f "$ROUTER"
  kubectl rollout status deployment -n "$NAMESPACE" -l "llm-d.ai/deployment=$NAME" --timeout=10m
  log "applying model servers"
  kubectl apply -n "$NAMESPACE" --server-side -f "$MS"
}

wait_ready() {
  if [[ $ROUTER_MODE == gateway ]]; then
    log "waiting for HTTPRoute to be accepted by $GATEWAY_NAMESPACE/$GATEWAY_NAME"
    kubectl wait httproute/"$NAME" -n "$NAMESPACE" --timeout=5m \
      --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True
  fi
  log "waiting up to $WAIT_TIMEOUT for model-server pods (llm-d.ai/deployment=$NAME); large models take a while"
  until kubectl get pod -n "$NAMESPACE" -l "llm-d.ai/deployment=$NAME" -o name | grep -q .; do sleep 5; done
  kubectl wait pod -n "$NAMESPACE" -l "llm-d.ai/deployment=$NAME" --for=condition=Ready --timeout="$WAIT_TIMEOUT"
}

# One completion through the front door (Gateway, or the EPP Service in standalone mode)
smoke_test() {
  local ip
  if [[ $ROUTER_MODE == gateway ]]; then
    ip=$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.status.addresses[0].value}')
  else
    ip=$(kubectl get service "$NAME-epp" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
  fi
  log "smoke test via http://$ip/v1/completions"
  kubectl run "smoke-$NAME" --rm -i --restart=Never -n "$NAMESPACE" --image="$SMOKE_IMAGE" -- \
    curl -sS --fail-with-body -m 300 "http://$ip/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Say hello.\",\"max_tokens\":16}"
  log "done: $NAME serving $MODEL at http://$ip"
}

# Removes exactly what was rendered; the ServiceAccount, namespace and Gateway stay.
delete_all() {
  kubectl delete -n "$NAMESPACE" -f "$MS" --ignore-not-found
  kubectl delete -n "$NAMESPACE" -f "$ROUTER" --ignore-not-found
}

# modelserver.kvCache measured from each model-server pod's vLLM startup log (docs/fine-tuning.md):
#   gpuTokens     = "GPU KV cache size: N tokens" (logged per engine = per DP rank = per router endpoint)
#   bytesPerToken = sum of every rank's "Available KV cache memory: X GiB" / sum of N (covers TP and DP)
kv_cache_report() {
  local pod found=
  for pod in $(kubectl get pod -n "$NAMESPACE" -l "llm-d.ai/deployment=$NAME" -o name); do
    kubectl logs -n "$NAMESPACE" "$pod" --all-containers 2>/dev/null | kv_cache_from_log "${pod#pod/}" && found=1
  done
  [[ -n $found ]] || { log "kvCache: no 'GPU KV cache size' line in any model-server log yet (still starting, or logs rotated)"; return 0; }
  log "kvCache: profile has {gpuTokens: ${KV_GPU_TOKENS:-unset}, bytesPerToken: ${KV_BYTES_PER_TOKEN:-unset}}; P/D: use the prefill pod's line"
}

# vLLM log on stdin -> "<label>: kvCache: {...}"; exit 1 when the log has no KV cache lines
kv_cache_from_log() {
  awk -v pod="$1" '
    /GPU KV cache size:/ { s = $0; sub(/.*GPU KV cache size: */, "", s); gsub(/,/, "", s); n = s + 0
                           tok += n; if (!min || n < min) min = n }
    /Available KV cache memory:/ { s = $0; sub(/.*Available KV cache memory: */, "", s); gib += s + 0 }
    END { if (!tok || !gib) exit 1
          printf "%s: kvCache: {gpuTokens: %d, bytesPerToken: %d}\n", pod, min, gib * 1073741824 / tok }'
}
