# Environment settings: --env-file loading and typo checks. Sourced by deploy.sh and bundle.sh.
#
#   ./deploy.sh --env-file dev profiles/x.yaml      # envs/dev.env (or any path)
#   ./bundle.sh --env-file envs/dev.env profiles/x.yaml
#
# The file's values win over the shell's. Both scripts refuse names that are not settings, so a typo
# (IMAGE_REMOTE, BUNDLE_STEP) stops the run instead of being ignored.

# Every setting the pipeline reads from the environment, plus what kubectl/helm/curl read
ENV_SETTINGS="NAMESPACE SERVICE_ACCOUNT ROUTER_SERVICE_ACCOUNT MONITORING MONITORING_INTERVAL MODEL_BUCKET MODEL_CACHE_PATH DOWNLOADER_IMAGE SMOKE_IMAGE
  IMAGE_REGISTRY IMAGE_TEMPLATE IMAGE_REMOTES
  OUT BUNDLE_STEPS ROUTER_CRDS ROUTER_CRDS_URL INFERENCE_CRDS_URL LWS_CHART LWS_VERSION
  KUBECONFIG HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy"

# env_check [file]: with a file, every NAME= in it must be a setting; without, any shell variable that is
# one typo away from a setting (IMAGE_REMOTE, BUNDLE_STEP) is an error. Prints the problems, if any.
env_check() {
  python3 - "$@" <<'EOF'
import difflib, os, re, sys
known = os.environ["ENV_SETTINGS"].split()
def hint(n):
    m = difflib.get_close_matches(n, known, 1, 0.8)
    return f" (did you mean {m[0]}?)" if m else ""
if len(sys.argv) > 1:
    # line-level mistakes that make bash skip or mangle an assignment without stopping
    probs, names, quote = [], [], None
    for i, line in enumerate(open(sys.argv[1], newline=""), 1):
        if "\r" in line: probs.append(f"line {i}: Windows line ending (CRLF); fix with: sed -i.bak 's/\\r$//' {sys.argv[1]}")
        if re.search("[\u2018\u2019\u201c\u201d]", line): probs.append(f"line {i}: curly quotes; use plain ' or \"")
        s = line.strip()
        if quote:                                       # inside a value that spans lines
            if s.count(quote) % 2: quote = None
            continue
        if not s or s.startswith("#"): continue
        m = re.match(r"(?:export\s+)?([A-Za-z_]\w*)(\s*)=(\s*)(.*)", s)
        if not m: probs.append(f"line {i}: not NAME=value: {s[:60]}"); continue
        n, sp1, sp2, val = m.groups(); names.append(n)
        if sp1: probs.append(f"line {i}: space before '=' in {n}")
        if sp2 and val and not val.startswith("#"): probs.append(f"line {i}: space after '=' in {n} (bash runs the value as a command and {n} stays empty)")
        q = val[:1]
        if q in "'\"" and q and val.count(q) % 2: quote = q
    if quote: probs.append(f"unclosed {quote} quote")
    bad = [n + hint(n) for n in names if n not in known]
    if bad: probs.append("not a setting: " + ", ".join(bad) + ". Settings: " + " ".join(known))
    if probs: print("; ".join(probs))
else:
    bad = [f"{n} (did you mean {m[0]}?)" for n in os.environ if n not in known
           for m in [difflib.get_close_matches(n, known, 1, 0.9)] if m]
    if bad: print("environment has misspelled settings: " + ", ".join(bad))
EOF
}

# load_env_file <name or path>: envs/<name>.env or a path, checked, then exported
load_env_file() {
  local f=$1 err
  [[ -f $f ]] || f=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/envs/$1.env
  [[ -f $f ]] || die "env file not found: $1 (nor $f)"
  err=$(ENV_SETTINGS=$ENV_SETTINGS env_check "$f") && [[ -z $err ]] || die "$f: $err"
  set -a; source "$f"; set +a
  # every NAME= in the file must now be set (catches anything bash still swallowed)
  local n; for n in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$f" | sort -u); do
    [[ -n ${!n+x} ]] || die "$f: $n is in the file but did not get set; check that line"
  done
  log "env file $f: NAMESPACE=${NAMESPACE:-<default>}${IMAGE_REMOTES:+, IMAGE_REMOTES for $(echo "$IMAGE_REMOTES" | tr ' ' '\n' | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')}${IMAGE_REGISTRY:+, IMAGE_REGISTRY=$IMAGE_REGISTRY}"
}

# check_env: refuse misspelled settings in the shell environment (e.g. BUNDLE_STEP=images ./bundle.sh)
check_env() {
  local err
  err=$(ENV_SETTINGS=$ENV_SETTINGS env_check) && [[ -z $err ]] || die "$err"
}

# env_args "$@": take --env-file / -e <name|path> from anywhere in the arguments, load it, check the
# environment for typos, and leave the other arguments in ARGS (caller: set -- ${ARGS[@]+"${ARGS[@]}"})
env_args() {
  local file=""; ARGS=()
  while (($#)); do
    case $1 in
      -e|--env-file) [[ -n ${2:-} ]] || die "$1 needs an env file (envs/<name>.env or a path)"; file=$2; shift 2 ;;
      --env-file=*)  file=${1#*=}; shift ;;
      *)             ARGS+=("$1"); shift ;;
    esac
  done
  [[ -z $file ]] || load_env_file "$file"
  check_env
}
