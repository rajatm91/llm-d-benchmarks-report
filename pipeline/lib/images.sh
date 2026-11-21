# Image naming shared by bundle.sh (mirror list) and deploy.sh (rewrite), so both always agree.
#
# IMAGE_REGISTRY  your registry prefix, e.g. us-docker.pkg.dev/my-proj/llm-d
# IMAGE_TEMPLATE  where each source image lives in it. Placeholders:
#   {registry} IMAGE_REGISTRY            {host}  source registry host (docker.io, ghcr.io, ...)
#   {path}     source repo path          {name}  last path segment (vllm-openai)
#   {tag}      source tag                {digest} sha256:... from .cache/images.lock
# Examples for docker.io/vllm/vllm-openai:v0.34.0:
#   {registry}/{host}/{path}@{digest}  -> <reg>/docker.io/vllm/vllm-openai@sha256:...   (default)
#   {registry}/{path}:{tag}            -> <reg>/vllm/vllm-openai:v0.34.0
#   {registry}/{name}:{tag}            -> <reg>/vllm-openai:v0.34.0
# Keep {digest} only if your mirroring preserves digests; a plain `docker pull && docker push`
# of a multi-arch image does not.
#
# IMAGE_REMOTES   Artifact Registry remote (or virtual) repos, one per upstream host, space-separated:
#                   'docker.io=asia-south1-docker.pkg.dev/<proj>/<repo> ghcr.io=... gcr.io=...'
#                 Images from a listed host are pulled through its repo, which keeps the upstream path:
#                   docker.io/vllm/vllm-openai:v0.34.0 -> <repo>/vllm/vllm-openai@sha256:...
#                 Nothing to copy for them. Other hosts use IMAGE_REGISTRY + IMAGE_TEMPLATE.
IMAGE_TEMPLATE=${IMAGE_TEMPLATE:-'{registry}/{host}/{path}@{digest}'}
IMAGE_REMOTES=${IMAGE_REMOTES:-}

# image_remote <host>  -> the remote repo for that host, or nothing
image_remote() {
  local e
  for e in $IMAGE_REMOTES; do [[ ${e%%=*} == "$1" ]] && { echo "${e#*=}"; return; }; done
  return 0
}

# docker.io short names -> fully qualified: vllm/vllm-openai:x -> docker.io/vllm/vllm-openai:x
norm_image() {
  local i=$1 h=${1%%/*}
  [[ $i == */* && ( $h == *.* || $h == *:* || $h == localhost ) ]] || { [[ $i == */* ]] && i=docker.io/$i || i=docker.io/library/$i; }
  echo "$i"
}

# image_target <normalized source image> <digest>  -> target reference (remote repo, else IMAGE_TEMPLATE)
image_target() {
  local src=$1 dig=$2 repo tag
  repo=${src%@*}; tag=""
  [[ ${repo##*/} == *:* ]] && { tag=${repo##*:}; repo=${repo%:*}; }
  local host=${repo%%/*} path=${repo#*/} remote
  remote=$(image_remote "$host")
  if [[ -n $remote ]]; then echo "${remote%/}/$path@$dig"; return; fi   # pull-through: same path, pinned digest
  [[ -n $tag ]] || tag=sha-${dig#sha256:}; tag=${tag:0:128}   # digest-only sources still get a tag
  local t=$IMAGE_TEMPLATE
  t=${t//\{registry\}/${IMAGE_REGISTRY%/}}; t=${t//\{host\}/$host}; t=${t//\{path\}/$path}
  t=${t//\{name\}/${path##*/}};             t=${t//\{tag\}/$tag};   t=${t//\{digest\}/$dig}
  echo "$t"
}

# registry_digest <normalized image>  -> sha256:... of what the tag points at (the multi-arch index if any),
# straight from the registry's v2 API with an anonymous pull token. Needs only curl + python3, so it
# works where `docker` is podman (no `buildx imagetools --format`) and no crane/skopeo is installed.
registry_digest() {
  local img=$1 repo tag host rpath api url auth realm service tok hdr
  [[ $img != *@sha256:* ]] || { echo "${img##*@}"; return; }
  repo=$img; tag=latest
  [[ ${repo##*/} == *:* ]] && { tag=${repo##*:}; repo=${repo%:*}; }
  host=${repo%%/*} rpath=${repo#*/}
  api=$host; [[ $host == docker.io ]] && api=registry-1.docker.io
  url=https://$api/v2/$rpath/manifests/$tag
  local accept=application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json
  if ! hdr=$(curl -fsSIL -H "Accept: $accept" "$url" 2>/dev/null); then
    # 401: the WWW-Authenticate header names the token service; ask it for an anonymous pull token
    auth=$(curl -sSI -H "Accept: $accept" "$url" | tr -d '\r' | grep -i '^www-authenticate: *bearer') || return 1
    realm=$(sed -nE 's/.*realm="([^"]+)".*/\1/p' <<<"$auth"); service=$(sed -nE 's/.*service="([^"]+)".*/\1/p' <<<"$auth")
    tok=$(curl -fsS -G "$realm" ${service:+--data-urlencode "service=$service"} --data-urlencode "scope=repository:$rpath:pull" |
      python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d["access_token"])') || return 1
    hdr=$(curl -fsSIL -H "Accept: $accept" -H "Authorization: Bearer $tok" "$url") || return 1
  fi
  tr -d '\r' <<<"$hdr" | grep -i '^docker-content-digest:' | tail -1 | awk '{print $2}'
}
