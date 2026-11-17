#!/usr/bin/env bash
# Keep docs/deploy-guide.md honest: every YAML sample must work with the pipeline as written.
#   "# profile: <path>"  -> same content as <path> if that file exists, and renders with --dry-run
#   "# models/<...>"     -> kustomize patch: renders when applied to the P/D profile
#   anything else        -> must parse as YAML
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - docs/deploy-guide.md "$T" <<'EOF'
import re, sys
text, out = open(sys.argv[1]).read(), sys.argv[2]
for i, block in enumerate(re.findall(r"```yaml\n(.*?)```", text, re.S)):
    open(f"{out}/{i:02d}.yaml", "w").write(block)
EOF
fail() { echo "FAIL: $*" >&2; exit 1; }
n=0
for f in "$T"/*.yaml; do
  head1=$(head -1 "$f")
  yq -e 'true' "$f" >/dev/null 2>&1 || yq '.' "$f" >/dev/null || fail "not valid YAML: $head1"
  if [[ $head1 =~ ^#\ profile:\ ([^ ]+) ]]; then
    path=${BASH_REMATCH[1]}
    if [[ -f $path ]]; then
      [[ $(yq -o=json -I=0 'sort_keys(..)' "$f") == "$(yq -o=json -I=0 'sort_keys(..)' "$path")" ]] ||
        { diff <(yq -o=json "sort_keys(..)" "$f") <(yq -o=json "sort_keys(..)" "$path") >&2; fail "guide sample differs from $path"; }
    fi
    MODEL_BUCKET=gs://guide-check ./deploy.sh "$f" --dry-run >/dev/null 2>"$T/err" || { cat "$T/err" >&2; fail "sample $path does not render"; }
    echo "ok  profile sample $path ($(./deploy.sh "$f" --name))"
  elif [[ $head1 =~ ^#\ models/ ]]; then
    yq '.modelserver.patches = ["'"$f"'"] | .modelserver.components = ["guides/recipes/modelserver/components/disaggregatedset-schema"]' \
      profiles/pd-gke.yaml > "$T/patched-profile.yaml"
    ./deploy.sh "$T/patched-profile.yaml" --dry-run >/dev/null 2>"$T/err" || { cat "$T/err" >&2; fail "patch sample does not render"; }
    mem=$(yq -N 'select(.kind == "DisaggregatedSet") | .spec.roles[] | select(.name == "decode") | .spec.leaderWorkerTemplate.workerTemplate.spec.containers[] | select(.name == "modelserver") | .resources.limits.memory' \
      ".build/$(./deploy.sh "$T/patched-profile.yaml" --name)/modelserver.yaml")
    [[ $mem == 128Gi ]] || fail "patch sample did not apply (decode memory=$mem)"
    echo "ok  patch sample applies to P/D (decode memory $mem)"
  else
    echo "ok  yaml: $head1"
  fi
  n=$((n+1))
done
echo "all $n guide samples check out"
