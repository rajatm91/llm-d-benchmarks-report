set -eu
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
EOF
