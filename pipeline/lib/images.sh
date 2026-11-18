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
# Keep {digest} only if your mirroring preserves digests (crane/gcrane copy, skopeo copy --all);
# a plain `docker pull && docker push` of a multi-arch image does not.
IMAGE_TEMPLATE=${IMAGE_TEMPLATE:-'{registry}/{host}/{path}@{digest}'}

# docker.io short names -> fully qualified: vllm/vllm-openai:x -> docker.io/vllm/vllm-openai:x
norm_image() {
  local i=$1 h=${1%%/*}
  [[ $i == */* && ( $h == *.* || $h == *:* || $h == localhost ) ]] || { [[ $i == */* ]] && i=docker.io/$i || i=docker.io/library/$i; }
  echo "$i"
}

# image_target <normalized source image> <digest>  -> target reference per IMAGE_TEMPLATE
image_target() {
  local src=$1 dig=$2 repo tag
  repo=${src%@*}; tag=""
  [[ ${repo##*/} == *:* ]] && { tag=${repo##*:}; repo=${repo%:*}; }
  [[ -n $tag ]] || tag=sha-${dig#sha256:}; tag=${tag:0:128}   # digest-only sources still get a tag
  local host=${repo%%/*} path=${repo#*/} t=$IMAGE_TEMPLATE
  t=${t//\{registry\}/${IMAGE_REGISTRY%/}}; t=${t//\{host\}/$host}; t=${t//\{path\}/$path}
  t=${t//\{name\}/${path##*/}};             t=${t//\{tag\}/$tag};   t=${t//\{digest\}/$dig}
  echo "$t"
}
