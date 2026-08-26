#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)
IMAGE_TAG=makerseed-runtime-entrypoints:task7
CONTAINER_NAME=makerseed-runtime-entrypoints-$$
DOCKER=${DOCKER_BIN:-docker}
DOCKERFILE=$PROJECT_DIR/deploy/Dockerfile
BUILD_CONTEXT=$PROJECT_DIR
BUILD_ARGS=''

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  "$DOCKER" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "$DOCKER" rmi "$IMAGE_TAG" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

[ "$(uname -s)" = "Linux" ] || fail "Linux test must run on Linux"
command -v "$DOCKER" >/dev/null 2>&1 || fail "docker is required"
case "$DOCKER" in
  *docker.exe)
    command -v wslpath >/dev/null 2>&1 || fail "wslpath is required when DOCKER_BIN uses docker.exe"
    DOCKERFILE=$(wslpath -w "$DOCKERFILE")
    BUILD_CONTEXT=$(wslpath -w "$BUILD_CONTEXT")
    ;;
esac
if [ -n "${RUNTIME_TEST_PYTHON_IMAGE:-}" ]; then
  BUILD_ARGS="--build-arg PYTHON_IMAGE=$RUNTIME_TEST_PYTHON_IMAGE"
fi

# shellcheck disable=SC2086
DOCKER_BUILDKIT=0 "$DOCKER" build $BUILD_ARGS -f "$DOCKERFILE" -t "$IMAGE_TAG" "$BUILD_CONTEXT" >/dev/null

"$DOCKER" run --rm --init "$IMAGE_TAG" /opt/app/.venv/bin/python -m alembic --version >/dev/null
"$DOCKER" run --rm --init "$IMAGE_TAG" /opt/app/.venv/bin/python -m makerseed_app.cli --help >/dev/null

"$DOCKER" run -d --name "$CONTAINER_NAME" --init \
  -e MKSEED_ENVIRONMENT=development \
  -e MKSEED_STATIC_ROOT=/opt/app/static \
  -e MKSEED_NAS_WEB_ROOT=/opt/app/static/nas-web \
  "$IMAGE_TAG" >/dev/null

attempt=0
while [ "$attempt" -lt 30 ]; do
  state=$("$DOCKER" inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)
  [ "$state" = "exited" ] && break
  if "$DOCKER" exec "$CONTAINER_NAME" /opt/app/.venv/bin/python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/health', timeout=1).read()" >/dev/null 2>&1; then
    echo "PASS: runtime Python entrypoints work under Docker --init."
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 1
done

"$DOCKER" logs "$CONTAINER_NAME" >&2 || true
fail "default image command did not start and serve health under Docker --init"
