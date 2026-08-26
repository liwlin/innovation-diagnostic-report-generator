#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_project_root_identity
: "${RELEASE_ID:?RELEASE_ID is required}"
: "${APP_IMAGE:?APP_IMAGE is required}"
: "${PREFLIGHT_NONCE:?PREFLIGHT_NONCE is required}"
: "${PREFLIGHT_BINDING_HASH:?PREFLIGHT_BINDING_HASH is required}"

BOOTSTRAP_STAGE=${BOOTSTRAP_STAGE:-/volume1/.makerseed-diagnostic-bootstrap/$RELEASE_ID-$PREFLIGHT_NONCE}
STAGED_RELEASE_ROOT=${STAGED_RELEASE_ROOT:-$BOOTSTRAP_STAGE/release/deploy}
RELEASE_TREE_MANIFEST=${RELEASE_TREE_MANIFEST:-$BOOTSTRAP_STAGE/release-tree.sha256}

preflight_verdict=$(PREFLIGHT_MODE=bootstrap "$SCRIPT_DIR/preflight.sh")
case "$preflight_verdict" in
  *'"result":"pass"'*'"mode":"bootstrap"'*'"nonce":"'"$PREFLIGHT_NONCE"'"'*) ;;
  *) echo "ABORT: install layout requires a matching successful bootstrap preflight nonce" >&2; exit 60 ;;
esac
actual_binding_hash=$(printf '%s\n' "$preflight_verdict" | sed -n 's/.*"binding_hash":"\([^"]*\)".*/\1/p')
if [ "$actual_binding_hash" != "$PREFLIGHT_BINDING_HASH" ]; then
  echo "ABORT: install layout requires the exact bootstrap binding hash" >&2
  exit 60
fi

if [ -e "$PROJECT_ROOT" ] || [ -L "$PROJECT_ROOT" ]; then
  echo "ABORT: project root exists before bootstrap layout" >&2
  exit 60
fi
if [ ! -d /volume1 ] || [ -L /volume1 ]; then
  echo "ABORT: verified volume /volume1 is missing or unsafe" >&2
  exit 60
fi
if [ -e /volume1/docker ] || [ -L /volume1/docker ]; then
  if [ ! -d /volume1/docker ] || [ -L /volume1/docker ]; then
    echo "ABORT: Docker parent exists but is unsafe" >&2
    exit 60
  fi
  docker_parent=$(safe_realpath /volume1/docker)
  [ "$docker_parent" = "/volume1/docker" ] || { echo "ABORT: Docker parent resolves outside /volume1/docker" >&2; exit 60; }
else
  mkdir /volume1/docker
  chown 0:0 /volume1/docker
  chmod 755 /volume1/docker
fi

target_release="$PROJECT_ROOT/releases/$RELEASE_ID"
incoming_release="$PROJECT_ROOT/releases/.incoming-$RELEASE_ID-$PREFLIGHT_NONCE"
for path in "$target_release" "$incoming_release"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "ABORT: release target or incoming path already exists: $path" >&2
    exit 61
  fi
done

mkdir "$PROJECT_ROOT"
mkdir "$PROJECT_ROOT/data" "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/backups" \
  "$PROJECT_ROOT/reports-staging" "$PROJECT_ROOT/secrets" "$PROJECT_ROOT/releases" \
  "$PROJECT_ROOT/deployment-state"

for path in "$PROJECT_ROOT" "$PROJECT_ROOT/data" "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/backups" "$PROJECT_ROOT/reports-staging" "$PROJECT_ROOT/secrets" "$PROJECT_ROOT/releases" "$PROJECT_ROOT/deployment-state"; do
  if [ -L "$path" ]; then
    echo "ABORT: layout path must not be a symbolic link: $path" >&2
    exit 62
  fi
done

chown 999:999 "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/backups"
chown 10001:10001 "$PROJECT_ROOT/reports-staging"
chmod 700 "$PROJECT_ROOT" "$PROJECT_ROOT/data" "$PROJECT_ROOT/data/postgres" \
  "$PROJECT_ROOT/backups" "$PROJECT_ROOT/reports-staging" "$PROJECT_ROOT/secrets" \
  "$PROJECT_ROOT/releases" "$PROJECT_ROOT/deployment-state"

mkdir "$incoming_release"
cp -pR "$BOOTSTRAP_STAGE/release/." "$incoming_release/"
cp "$RELEASE_TREE_MANIFEST" "$incoming_release/release-tree.sha256"
# re-verify copied release tree before publishing immutable release
verify_release_tree "$incoming_release" "$incoming_release/release-tree.sha256"
chmod 755 "$incoming_release/deploy"/scripts/*.sh "$incoming_release/deploy/postgres-init/10-create-runtime-role.sh"
chmod 755 "$incoming_release/deploy" "$incoming_release/deploy/postgres-init" "$incoming_release/deploy/scripts"
chmod 644 "$incoming_release/deploy/compose.yaml" "$incoming_release/deploy/Dockerfile" "$incoming_release/deploy/env.example" 2>/dev/null || true
chown 999:999 "$incoming_release/deploy/postgres-init/10-create-runtime-role.sh" 2>/dev/null || true

mv "$incoming_release" "$target_release"
sync
echo "LAYOUT_OK: $PROJECT_ROOT/releases/$RELEASE_ID"
