#!/usr/bin/env bash
# Local-only image and ephemeral container acceptance. Never publishes or logs in.
set -euo pipefail
CODE_COMMIT=bc6e64b3374aa80a92127c8ff570ebb1fb9c5568
LOCAL_IMAGE=decypharr:2.7-linkfix-bc6e64b-owned.1
EVIDENCE=owned-baseline-evidence
test "$(git rev-parse --show-toplevel)" = "$PWD"
git merge-base --is-ancestor "$CODE_COMMIT" HEAD
git diff --exit-code "$CODE_COMMIT" -- '*.go' go.mod go.sum
if test -d "$EVIDENCE" && test -n "$(find "$EVIDENCE" -mindepth 1 -print -quit)"; then
  echo 'Refusing to overwrite previous acceptance evidence.' >&2
  exit 1
fi
mkdir -p "$EVIDENCE/test-results" .owned-build
REVISION=$(git rev-parse HEAD)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$REVISION" > "$EVIDENCE/build-revision.txt"
printf '%s\n' "$CODE_COMMIT" > "$EVIDENCE/code-revision.txt"
printf '%s\n' "$BUILD_DATE" > "$EVIDENCE/build-date.txt"
docker version > "$EVIDENCE/docker-version.txt"
docker buildx version > "$EVIDENCE/buildx-version.txt"
export BUILDX_METADATA_PROVENANCE=disabled

docker buildx build --platform linux/amd64 --target acceptance-results \
  --build-arg VERSION=2.7 --build-arg CHANNEL=linkfix \
  --output "type=local,dest=$EVIDENCE/test-results" --progress plain . \
  > "$EVIDENCE/tests-build.log" 2>&1

docker buildx build --platform linux/amd64 --load --provenance=false \
  --build-arg VERSION=2.7 --build-arg CHANNEL=linkfix \
  --build-arg "VCS_REF=$REVISION" --build-arg "BUILD_DATE=$BUILD_DATE" \
  --metadata-file "$EVIDENCE/build-metadata.json" \
  --iidfile "$EVIDENCE/build-image-id.txt" --tag "$LOCAL_IMAGE" --progress plain . \
  > "$EVIDENCE/image-build.log" 2>&1

docker image inspect --format '{{json .Config.Labels}}' "$LOCAL_IMAGE" > "$EVIDENCE/labels.json"
docker image inspect --format '{{.Id}}' "$LOCAL_IMAGE" > "$EVIDENCE/image-id.txt"
docker image inspect --format '{{.Os}}/{{.Architecture}}' "$LOCAL_IMAGE" > "$EVIDENCE/platform.txt"
docker run --rm --network none --entrypoint /sbin/apk "$LOCAL_IMAGE" info -v > "$EVIDENCE/runtime-apk.txt"
docker run --rm --network none --entrypoint /usr/local/bin/rclone "$LOCAL_IMAGE" version > "$EVIDENCE/rclone-version.txt"

CONFIG_DIR=$(mktemp -d "$PWD/.owned-build/empty-config.XXXXXX")
CONTAINER="decypharr-owned-acceptance-${GITHUB_RUN_ID:-local}-$$"
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  case "$CONFIG_DIR" in "$PWD"/.owned-build/empty-config.*) rm -rf -- "$CONFIG_DIR" ;; esac
}
trap cleanup EXIT
printf '0\n' > "$EVIDENCE/http-status.txt"
docker run --detach --name "$CONTAINER" --network none \
  --cpus 2 --memory 1g --pids-limit 256 \
  --env "PUID=$(id -u)" --env "PGID=$(id -g)" \
  --mount "type=bind,src=$CONFIG_DIR,dst=/app" "$LOCAL_IMAGE" >/dev/null
for attempt in $(seq 1 30); do
  if docker exec "$CONTAINER" sh -c 'wget -q -S -T 2 -O /tmp/owned-smoke-body http://127.0.0.1:8282/ 2>/tmp/owned-smoke-headers'; then
    STATUS=$(docker exec "$CONTAINER" awk '$1 ~ /^HTTP\// {status=$2} END {print status}' /tmp/owned-smoke-headers | tr -d '\r')
    if test "$STATUS" = 200; then
      printf '%s\n' "$STATUS" > "$EVIDENCE/http-status.txt"
      docker exec "$CONTAINER" sh -c 'wc -c < /tmp/owned-smoke-body' > "$EVIDENCE/http-body-bytes.txt"
      break
    fi
  fi
  sleep 1
done
# Do not export the generated config, auth material, response cookies or raw logs.
docker logs "$CONTAINER" 2>&1 | python3 build/owned-baseline-report.py --redact > "$EVIDENCE/container.log"
python3 build/owned-baseline-report.py "$EVIDENCE"
