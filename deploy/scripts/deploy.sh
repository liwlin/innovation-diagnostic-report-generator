#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${RELEASE_ROOT:?RELEASE_ROOT is required}"
: "${APP_VERSION:?APP_VERSION is required}"
: "${APP_IMAGE:?APP_IMAGE is required}"
: "${PREFLIGHT_NONCE:?PREFLIGHT_NONCE is required}"
: "${MIGRATION_COMPATIBILITY:?MIGRATION_COMPATIBILITY is required}"

case "$MIGRATION_COMPATIBILITY" in
  backward-compatible) schema_compatible=true ;;
  incompatible) schema_compatible=false ;;
  *) echo "ABORT: MIGRATION_COMPATIBILITY must be backward-compatible or incompatible" >&2; exit 80 ;;
esac

"$SCRIPT_DIR/preflight.sh" >/dev/null

lock_dir="$PROJECT_ROOT/.deploy-lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "ABORT: another deployment holds the project lock" >&2
  exit 80
fi
cleanup_lock() { rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup_lock EXIT HUP INT TERM

if [ -n "${IMAGE_TAR:-}" ] && ! docker image inspect "$APP_IMAGE" >/dev/null 2>&1; then
  docker load --input "$IMAGE_TAR" >/dev/null
  docker image inspect "$APP_IMAGE" >/dev/null
fi
docker image inspect "$APP_IMAGE" >/dev/null

state_dir="$PROJECT_ROOT/deployment-state"
previous_state="$state_dir/current.env"
pending_state="$state_dir/pending.env"
previous_exists=0
previous_release=''
previous_image=''
previous_version=''
if [ -f "$previous_state" ] && [ ! -L "$previous_state" ]; then
  previous_exists=1
  previous_release=$(sed -n 's/^RELEASE_ROOT=//p' "$previous_state")
  previous_image=$(sed -n 's/^APP_IMAGE=//p' "$previous_state")
  previous_version=$(sed -n 's/^APP_VERSION=//p' "$previous_state")
fi

compose up -d db
db_container=$(compose ps -q db)
attempt=0
until [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$db_container")" = "healthy" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || { echo "ABORT: database health timeout" >&2; exit 81; }
  sleep 2
done

backup_file=''
if [ "$previous_exists" -eq 1 ]; then
  backup_result=$("$SCRIPT_DIR/backup.sh")
  backup_file=${backup_result#BACKUP_OK: }
  "$SCRIPT_DIR/restore-verify.sh" --backup "$backup_file" >/dev/null
fi

printf 'RELEASE_ROOT=%s\nAPP_IMAGE=%s\nAPP_VERSION=%s\nSCHEMA_COMPATIBLE=%s\nBACKUP_FILE=%s\nPREVIOUS_RELEASE_ROOT=%s\nPREVIOUS_APP_IMAGE=%s\nPREVIOUS_APP_VERSION=%s\n' \
  "$RELEASE_ROOT" "$APP_IMAGE" "$APP_VERSION" "$schema_compatible" "$backup_file" \
  "$previous_release" "$previous_image" "$previous_version" >"$pending_state"
chmod 600 "$pending_state"
sha256sum "$pending_state" >"$pending_state.sha256"

rollback_on_error() {
  exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ "$previous_exists" -eq 1 ]; then
    "$SCRIPT_DIR/rollback.sh" --state "$pending_state" || true
  fi
  cleanup_lock
  exit "$exit_code"
}
trap rollback_on_error EXIT HUP INT TERM

"$SCRIPT_DIR/migrate.sh"
compose up -d --no-deps app
app_container=$(compose ps -q app)
attempt=0
until [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$app_container")" = "healthy" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || { echo "ABORT: app health timeout" >&2; exit 82; }
  sleep 2
done
"$SCRIPT_DIR/smoke.sh"

for bootstrap_password in "$PROJECT_ROOT/secrets/bootstrap_password" "$PROJECT_ROOT/secrets/bootstrap-admin-password" "$PROJECT_ROOT/secrets/bootstrap_admin_password"; do
  if [ -f "$bootstrap_password" ] && [ ! -L "$bootstrap_password" ]; then
    rm -f "$bootstrap_password"
  fi
done
mv "$pending_state" "$previous_state"
mv "$pending_state.sha256" "$previous_state.sha256"
ln -sfn "$RELEASE_ROOT" "$PROJECT_ROOT/current"
sync
trap - EXIT HUP INT TERM
cleanup_lock
echo "DEPLOY_OK: $APP_VERSION"
