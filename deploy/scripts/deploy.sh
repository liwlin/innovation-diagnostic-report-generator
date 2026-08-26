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
: "${SECRETS_ROOT:?SECRETS_ROOT is required}"

case "$MIGRATION_COMPATIBILITY" in
  backward-compatible) schema_compatible=true ;;
  incompatible) schema_compatible=false ;;
  *) echo "ABORT: MIGRATION_COMPATIBILITY must be backward-compatible or incompatible" >&2; exit 80 ;;
esac

state_dir="$PROJECT_ROOT/deployment-state"
previous_state="$state_dir/current.env"
pending_state="$state_dir/pending.env"

require_canonical_current_env_sha256() {
  hash_file=$1
  line_count=$(wc -l <"$hash_file" | awk '{print $1}')
  if [ "$line_count" -ne 1 ]; then
    echo "ABORT: current.env.sha256 must contain exactly one canonical current.env checksum line" >&2
    exit 81
  fi
  line=$(sed -n '1p' "$hash_file")
  digest=${line%  current.env}
  case "$line" in
    *"  current.env") ;;
    *)
      echo "ABORT: current.env.sha256 must contain exactly one canonical current.env checksum line" >&2
      exit 81
      ;;
  esac
  if [ "${#digest}" -ne 64 ]; then
    echo "ABORT: current.env.sha256 must contain exactly one canonical current.env checksum line" >&2
    exit 81
  fi
  case "$digest" in
    *[!0123456789abcdef]*)
      echo "ABORT: current.env.sha256 must contain exactly one canonical current.env checksum line" >&2
      exit 81
      ;;
  esac
}

previous_exists=0
previous_release=''
previous_image=''
previous_version=''
previous_db_image=''
previous_db_config_hash=''
previous_initial_admin_handoff=''
if [ -e "$previous_state" ] || [ -L "$previous_state" ]; then
  if [ ! -f "$previous_state" ] || [ -L "$previous_state" ]; then
    echo "ABORT: current.env exists but is not a regular non-symlink file; capture an audited baseline before deployment" >&2
    exit 81
  fi
  if [ -f "$previous_state.sha256" ] && [ ! -L "$previous_state.sha256" ]; then
    :
  else
    echo "ABORT: current.env.sha256 is missing or not a regular non-symlink file; capture an audited baseline before deployment" >&2
    exit 81
  fi
  require_canonical_current_env_sha256 "$previous_state.sha256"
  (cd "$state_dir" && sha256sum -c current.env.sha256 >/dev/null)
  previous_exists=1
  previous_release=$(sed -n 's/^RELEASE_ROOT=//p' "$previous_state")
  previous_image=$(sed -n 's/^APP_IMAGE=//p' "$previous_state")
  previous_version=$(sed -n 's/^APP_VERSION=//p' "$previous_state")
  previous_db_image=$(sed -n 's/^DB_IMAGE=//p' "$previous_state")
  previous_db_config_hash=$(sed -n 's/^DB_CONTAINER_CONFIG_HASH=//p' "$previous_state")
  previous_initial_admin_handoff=$(sed -n 's/^INITIAL_ADMIN_HANDOFF=//p' "$previous_state")
fi

PREFLIGHT_MODE=runtime "$SCRIPT_DIR/preflight.sh" >/dev/null

lock_dir="$PROJECT_ROOT/.deploy-lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "ABORT: another deployment holds the project lock" >&2
  exit 80
fi
cleanup_lock() { rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup_lock EXIT HUP INT TERM

docker image inspect "$APP_IMAGE" >/dev/null

require_safe_scalar() {
  value_name=$1
  value=$2
  max_length=$3
  if [ -z "$value" ] || [ "${#value}" -gt "$max_length" ]; then
    echo "ABORT: $value_name is missing or too long" >&2
    exit 83
  fi
  case "$value" in
    *"
"*|*""*|*"	"*)
      echo "ABORT: $value_name must not contain control characters" >&2
      exit 83
      ;;
  esac
}

require_exact_secret_file() {
  value_name=$1
  value=$2
  expected=$3
  if [ "$value" != "$expected" ]; then
    echo "ABORT: $value_name must be exactly $expected" >&2
    exit 83
  fi
  require_regular_secret_mode "$value"
}

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

SMOKE_TEST_PASSWORD_FILE=${SMOKE_TEST_PASSWORD_FILE:-$SECRETS_ROOT/smoke_test_password}
require_exact_secret_file SMOKE_TEST_PASSWORD_FILE "$SMOKE_TEST_PASSWORD_FILE" "$SECRETS_ROOT/smoke_test_password"

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
  : "${BOOTSTRAP_ADMIN_USERNAME:?BOOTSTRAP_ADMIN_USERNAME is required for first install}"
  : "${BOOTSTRAP_ADMIN_DISPLAY_NAME:?BOOTSTRAP_ADMIN_DISPLAY_NAME is required for first install}"
  require_safe_scalar BOOTSTRAP_ADMIN_USERNAME "$BOOTSTRAP_ADMIN_USERNAME" 80
  require_safe_scalar BOOTSTRAP_ADMIN_DISPLAY_NAME "$BOOTSTRAP_ADMIN_DISPLAY_NAME" 120
  case "$BOOTSTRAP_ADMIN_USERNAME" in
    [a-z0-9][a-z0-9._-]*) ;;
    *) echo "ABORT: BOOTSTRAP_ADMIN_USERNAME is invalid" >&2; exit 83 ;;
  esac
  INITIAL_ADMIN_PASSWORD_FILE=${INITIAL_ADMIN_PASSWORD_FILE:-$SECRETS_ROOT/initial_admin_password}
  require_exact_secret_file INITIAL_ADMIN_PASSWORD_FILE "$INITIAL_ADMIN_PASSWORD_FILE" "$SECRETS_ROOT/initial_admin_password"
  SMOKE_ADMIN_USERNAME=${SMOKE_ADMIN_USERNAME:-$BOOTSTRAP_ADMIN_USERNAME}
  SMOKE_ADMIN_PASSWORD_FILE=$INITIAL_ADMIN_PASSWORD_FILE
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
initial_admin_handoff=$previous_initial_admin_handoff
if [ "$previous_exists" -eq 0 ]; then
  initial_admin_handoff=pending
elif [ -z "$initial_admin_handoff" ]; then
  initial_admin_handoff=unknown
fi

printf 'RELEASE_ROOT=%s\nAPP_IMAGE=%s\nAPP_VERSION=%s\nDB_IMAGE=%s\nDB_CONTAINER_CONFIG_HASH=%s\nSCHEMA_COMPATIBLE=%s\nBACKUP_FILE=%s\nPREVIOUS_RELEASE_ROOT=%s\nPREVIOUS_APP_IMAGE=%s\nPREVIOUS_APP_VERSION=%s\nINITIAL_ADMIN_HANDOFF=%s\n' \
  "$RELEASE_ROOT" "$APP_IMAGE" "$APP_VERSION" "$db_image" "$db_container_config_hash" "$schema_compatible" "$backup_file" \
  "$previous_release" "$previous_image" "$previous_version" "$initial_admin_handoff" >"$pending_state"
chmod 600 "$pending_state"
sha256sum "$pending_state" >"$pending_state.sha256"

final_stage_dir=''
commit_started=0
commit_complete=0
commit_backup_ready=0
commit_state_backup="$state_dir/current.env.before-commit"
commit_hash_backup="$state_dir/current.env.sha256.before-commit"

restore_deploy_state_commit() {
  if [ -n "$final_stage_dir" ] && [ -d "$final_stage_dir" ]; then
    rm -f "$final_stage_dir/current.env" "$final_stage_dir/current.env.sha256"
    rmdir "$final_stage_dir" 2>/dev/null || true
  fi
  if [ "$commit_complete" -eq 0 ] && [ "$commit_started" -eq 1 ]; then
    if [ "$previous_exists" -eq 1 ]; then
      if [ "$commit_backup_ready" -eq 1 ] && [ -f "$commit_state_backup" ] && [ -f "$commit_hash_backup" ]; then
        mv "$commit_state_backup" "$previous_state" || true
        mv "$commit_hash_backup" "$previous_state.sha256" || true
      fi
    else
      rm -f "$previous_state" "$previous_state.sha256"
    fi
  fi
  if [ "$commit_complete" -eq 0 ]; then
    rm -f "$commit_state_backup" "$commit_hash_backup"
  fi
}

rollback_on_error() {
  exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    restore_deploy_state_commit
    if [ "$previous_exists" -eq 1 ]; then
      "$SCRIPT_DIR/rollback.sh" --state "$pending_state" || true
    fi
  fi
  cleanup_lock
  exit "$exit_code"
}
trap rollback_on_error EXIT HUP INT TERM

"$SCRIPT_DIR/migrate.sh"
if [ "$previous_exists" -eq 0 ]; then
  compose run --rm --no-deps \
    -v "$INITIAL_ADMIN_PASSWORD_FILE:/run/bootstrap/initial_admin_password:ro" \
    app /opt/app/.venv/bin/python -m makerseed_app.cli bootstrap-admin \
      --username "$BOOTSTRAP_ADMIN_USERNAME" \
      --display-name "$BOOTSTRAP_ADMIN_DISPLAY_NAME" \
      --password-file /run/bootstrap/initial_admin_password
else
  : "${SMOKE_ADMIN_USERNAME:?SMOKE_ADMIN_USERNAME is required}"
  : "${SMOKE_ADMIN_PASSWORD_FILE:?SMOKE_ADMIN_PASSWORD_FILE is required}"
  require_safe_scalar SMOKE_ADMIN_USERNAME "$SMOKE_ADMIN_USERNAME" 80
  require_regular_secret_mode "$SMOKE_ADMIN_PASSWORD_FILE"
fi
compose up -d --no-deps --force-recreate app
app_container=$(compose ps -q app)
attempt=0
until [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$app_container")" = "healthy" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || { echo "ABORT: app health timeout" >&2; exit 82; }
  sleep 2
done
SMOKE_ADMIN_USERNAME=$SMOKE_ADMIN_USERNAME \
SMOKE_ADMIN_PASSWORD_FILE=$SMOKE_ADMIN_PASSWORD_FILE \
SMOKE_TEST_PASSWORD_FILE=$SMOKE_TEST_PASSWORD_FILE \
  "$SCRIPT_DIR/smoke.sh"

final_stage_dir=$(mktemp -d "$state_dir/.current-env-stage.XXXXXX")
cp -p "$pending_state" "$final_stage_dir/current.env"
(
  cd "$final_stage_dir"
  sha256sum current.env > current.env.sha256
  sha256sum -c current.env.sha256 >/dev/null
)
for commit_backup in "$commit_state_backup" "$commit_hash_backup"; do
  if [ -e "$commit_backup" ] || [ -L "$commit_backup" ]; then
    echo "ABORT: reserved deployment state backup already exists: $commit_backup" >&2
    exit 81
  fi
done
if [ "$previous_exists" -eq 1 ]; then
  cp -p "$previous_state" "$commit_state_backup"
  cp -p "$previous_state.sha256" "$commit_hash_backup"
  commit_backup_ready=1
fi
commit_started=1
mv "$final_stage_dir/current.env" "$previous_state"
mv "$final_stage_dir/current.env.sha256" "$previous_state.sha256"
(cd "$state_dir" && sha256sum -c current.env.sha256 >/dev/null)
commit_complete=1
rm -f "$SMOKE_TEST_PASSWORD_FILE"
rm -f "$pending_state" "$pending_state.sha256" "$commit_state_backup" "$commit_hash_backup"
rmdir "$final_stage_dir"
final_stage_dir=''
ln -sfn "$RELEASE_ROOT" "$PROJECT_ROOT/current"
sync
trap - EXIT HUP INT TERM
cleanup_lock
echo "DEPLOY_OK: $APP_VERSION"
