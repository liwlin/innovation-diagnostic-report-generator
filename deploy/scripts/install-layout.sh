#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${RELEASE_ROOT:?RELEASE_ROOT is required}"
: "${APP_IMAGE:?APP_IMAGE is required}"
: "${SECRETS_ROOT:?SECRETS_ROOT is required}"
: "${REPORT_ROOT:?REPORT_ROOT is required}"
: "${PREFLIGHT_NONCE:?PREFLIGHT_NONCE is required}"

preflight_verdict=$("$SCRIPT_DIR/preflight.sh")
case "$preflight_verdict" in
  *'"result":"pass"'*'"nonce":"'"$PREFLIGHT_NONCE"'"'*) ;;
  *) echo "ABORT: install layout requires a matching successful preflight nonce" >&2; exit 60 ;;
esac

if [ -e "$PROJECT_ROOT" ] && [ ! -d "$PROJECT_ROOT" ]; then
  echo "ABORT: project root exists and is not a directory" >&2
  exit 60
fi
if [ -e "$PROJECT_ROOT" ]; then
  for child in "$PROJECT_ROOT"/* "$PROJECT_ROOT"/.[!.]*; do
    [ -e "$child" ] || continue
    name=$(basename "$child")
    case "$name" in
      data|backups|reports-staging|secrets|releases|current|deployment-state|.env|.deploy-lock) ;;
      *) echo "ABORT: unexpected entry exists in project root: $name" >&2; exit 61 ;;
    esac
  done
fi
for path in "$PROJECT_ROOT" "$PROJECT_ROOT/data" "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/backups" "$PROJECT_ROOT/reports-staging" "$PROJECT_ROOT/secrets" "$PROJECT_ROOT/releases" "$PROJECT_ROOT/deployment-state"; do
  if [ -L "$path" ]; then
    echo "ABORT: layout path must not be a symbolic link: $path" >&2
    exit 62
  fi
done

mkdir -p \
  "$PROJECT_ROOT/data/postgres" \
  "$PROJECT_ROOT/backups" \
  "$PROJECT_ROOT/reports-staging" \
  "$PROJECT_ROOT/secrets" \
  "$PROJECT_ROOT/releases" \
  "$PROJECT_ROOT/deployment-state"

chown 999:999 "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/backups"
chown 10001:10001 "$PROJECT_ROOT/reports-staging"
chmod 700 "$PROJECT_ROOT" "$PROJECT_ROOT/data" "$PROJECT_ROOT/data/postgres" \
  "$PROJECT_ROOT/backups" "$PROJECT_ROOT/reports-staging" "$PROJECT_ROOT/secrets" \
  "$PROJECT_ROOT/releases" "$PROJECT_ROOT/deployment-state"

echo "LAYOUT_OK: $PROJECT_ROOT"
