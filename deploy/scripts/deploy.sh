#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${RELEASE_ROOT:?RELEASE_ROOT is required}"
: "${RELEASE_ID:?RELEASE_ID is required}"
: "${APP_VERSION:?APP_VERSION is required}"
: "${APP_IMAGE:?APP_IMAGE is required}"
: "${PREFLIGHT_NONCE:?PREFLIGHT_NONCE is required}"
: "${MIGRATION_COMPATIBILITY:?MIGRATION_COMPATIBILITY is required}"

case "$MIGRATION_COMPATIBILITY" in
  backward-compatible) schema_compatible=true ;;
  incompatible) schema_compatible=false ;;
  *) echo "ABORT: MIGRATION_COMPATIBILITY must be backward-compatible or incompatible" >&2; exit 80 ;;
esac

PREFLIGHT_MODE=runtime "$SCRIPT_DIR/preflight.sh" >/dev/null

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
previous_db_image=''
previous_db_config_hash=''
if [ -e "$previous_state" ] || [ -L "$previous_state" ]; then
  if [ ! -f "$previous_state" ] || [ -L "$previous_state" ]; then
    echo "ABORT: current.env exists but is not a regular non-symlink file; capture an audited baseline before deployment" >&2
    exit 81
  fi
  previous_exists=1
  previous_release=$(sed -n 's/^RELEASE_ROOT=//p' "$previous_state")
  previous_image=$(sed -n 's/^APP_IMAGE=//p' "$previous_state")
  previous_version=$(sed -n 's/^APP_VERSION=//p' "$previous_state")
  previous_db_image=$(sed -n 's/^DB_IMAGE=//p' "$previous_state")
  previous_db_config_hash=$(sed -n 's/^DB_CONTAINER_CONFIG_HASH=//p' "$previous_state")
fi

data_postgres_has_entries() {
  data_dir="$PROJECT_ROOT/data/postgres"
  [ -d "$data_dir" ] || return 1
  for child in "$data_dir"/* "$data_dir"/.[!.]* "$data_dir"/..?*; do
    if [ -e "$child" ] || [ -L "$child" ]; then
      return 0
    fi
  done
  return 1
}

detect_existing_db_footprint() {
  existing_db_container=$(compose ps -a -q db 2>/dev/null || true)
  if [ -n "$existing_db_container" ]; then
    return 0
  fi
  if data_postgres_has_entries; then
    return 0
  fi
  return 1
}

db_config_hash() {
  container_id=$1
  docker inspect --format '{{json .Config.Image}}{{json .HostConfig.Binds}}{{json .Mounts}}{{json .HostConfig.NetworkMode}}{{json .Config.Labels}}' "$container_id" | sha256sum | awk '{print $1}'
}

verify_existing_db_state() {
  db_container=$(compose ps -q db)
  if [ -z "$db_container" ]; then
    echo "ABORT: upgrade requires the existing db container to be running before deployment" >&2
    exit 81
  fi
  owner_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$db_container")
  owner_dir=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$db_container")
  if [ "$owner_project" != "makerseed-diagnostic" ] || [ "$owner_dir" != "$PROJECT_ROOT" ]; then
    echo "ABORT: running db container does not match the recorded project identity" >&2
    exit 81
  fi
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$db_container")
  if [ "$health" != "healthy" ]; then
    echo "ABORT: existing db container is not healthy" >&2
    exit 81
  fi
  current_db_image=$(docker inspect --format '{{.Config.Image}}' "$db_container")
  current_db_config_hash=$(db_config_hash "$db_container")
  if [ -z "$previous_db_image" ] || [ -z "$previous_db_config_hash" ]; then
    echo "ABORT: previous deployment state lacks DB image/config proof; refusing upgrade drift" >&2
    exit 81
  fi
  if [ "$current_db_image" != "$previous_db_image" ] || [ "$current_db_config_hash" != "$previous_db_config_hash" ]; then
    echo "ABORT: existing db image or container config drifted from persisted state" >&2
    exit 81
  fi
}

backup_file=''
if [ "$previous_exists" -eq 1 ]; then
  verify_existing_db_state
  backup_result=$("$SCRIPT_DIR/backup.sh")
  backup_file=${backup_result#BACKUP_OK: }
  "$SCRIPT_DIR/restore-verify.sh" --backup "$backup_file" >/dev/null
fi
if [ "$previous_exists" -eq 0 ]; then
  if detect_existing_db_footprint; then
    echo "ABORT: refusing first install over existing database evidence; capture an audited baseline before deployment" >&2
    exit 81
  fi
  compose up -d db
  db_container=$(compose ps -q db)
  attempt=0
  until [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$db_container")" = "healthy" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 60 ] || { echo "ABORT: database health timeout" >&2; exit 81; }
    sleep 2
  done
fi
db_container=$(compose ps -q db)
db_image=$(docker inspect --format '{{.Config.Image}}' "$db_container")
db_container_config_hash=$(db_config_hash "$db_container")

printf 'RELEASE_ROOT=%s\nAPP_IMAGE=%s\nAPP_VERSION=%s\nDB_IMAGE=%s\nDB_CONTAINER_CONFIG_HASH=%s\nSCHEMA_COMPATIBLE=%s\nBACKUP_FILE=%s\nPREVIOUS_RELEASE_ROOT=%s\nPREVIOUS_APP_IMAGE=%s\nPREVIOUS_APP_VERSION=%s\n' \
  "$RELEASE_ROOT" "$APP_IMAGE" "$APP_VERSION" "$db_image" "$db_container_config_hash" "$schema_compatible" "$backup_file" \
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
compose up -d --no-deps --force-recreate app
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
