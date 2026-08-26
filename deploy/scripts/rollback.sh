#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root

if [ "$#" -ne 2 ] || [ "$1" != "--state" ]; then
  echo "usage: rollback.sh --state /exact/project/deployment-state/current.env|pending.env" >&2
  exit 90
fi

state_file=$2
state_dir=$(readlink -f "$PROJECT_ROOT/deployment-state")
current_state="$state_dir/current.env"
project_env="$PROJECT_ROOT/.env"

require_regular_state_file() {
  state_path=$1
  state_name=$2
  if [ ! -f "$state_path" ] || [ -L "$state_path" ]; then
    echo "ABORT: $state_name is missing or unsafe" >&2
    exit 91
  fi
}

require_canonical_current_env_sha256() {
  hash_file=$1
  line_count=$(wc -l <"$hash_file" | awk '{print $1}')
  if [ "$line_count" -ne 1 ]; then
    echo "ABORT: current.env.sha256 must contain exactly one canonical current.env checksum line" >&2
    exit 92
  fi
  line=$(sed -n '1p' "$hash_file")
  digest=${line%  current.env}
  case "$line" in
    *"  current.env") ;;
    *)
      echo "ABORT: current.env.sha256 must contain exactly one canonical current.env checksum line" >&2
      exit 92
      ;;
  esac
  if [ "${#digest}" -ne 64 ]; then
    echo "ABORT: current.env.sha256 must contain exactly one canonical current.env checksum line" >&2
    exit 92
  fi
  case "$digest" in
    *[!0123456789abcdef]*)
      echo "ABORT: current.env.sha256 must contain exactly one canonical current.env checksum line" >&2
      exit 92
      ;;
  esac
}

read_required_single_field() {
  file=$1
  key=$2
  count=$(grep -c "^$key=" "$file" || true)
  if [ "$count" -ne 1 ]; then
    echo "ABORT: $file must contain exactly one $key field" >&2
    exit 93
  fi
  sed -n "s/^$key=//p" "$file"
}

require_safe_release_id() {
  release_id=$1
  case "$release_id" in
    ''|*[!A-Za-z0-9._-]*)
      echo "ABORT: release id contains unsafe characters" >&2
      exit 93
      ;;
  esac
}

require_safe_version() {
  version=$1
  case "$version" in
    ''|*[!A-Za-z0-9._-]*)
      echo "ABORT: app version contains unsafe characters" >&2
      exit 93
      ;;
  esac
}

release_id_from_root() {
  basename "$(dirname "$1")"
}

validate_release_tuple() {
  release_root=$1
  app_image=$2
  app_version=$3
  release_id=$4
  require_safe_release_id "$release_id"
  require_safe_version "$app_version"
  if [ "$release_root" != "$PROJECT_ROOT/releases/$release_id/deploy" ]; then
    echo "ABORT: release root does not match release id or project boundary" >&2
    exit 93
  fi
  case "$app_image" in
    ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:????????????????????????????????????????????????????????????????) ;;
    *) echo "ABORT: app image is not the approved digest-pinned repository" >&2; exit 93 ;;
  esac
  if [ ! -d "$release_root" ] || [ -L "$release_root" ]; then
    echo "ABORT: release root is missing or unsafe" >&2
    exit 93
  fi
}

require_regular_state_file "$state_file" "deployment-state file"
resolved_state=$(readlink -f "$state_file")
case "$resolved_state" in
  "$state_dir"/*.env) ;;
  *) echo "ABORT: deployment-state file is outside the exact state directory" >&2; exit 91 ;;
esac
if [ ! -f "$resolved_state.sha256" ] || [ -L "$resolved_state.sha256" ]; then
  echo "ABORT: deployment-state SHA-256 proof is missing or unsafe" >&2
  exit 92
fi
(cd "$state_dir" && sha256sum -c "$(basename "$resolved_state").sha256") >/dev/null

manual_state=0
if [ "$resolved_state" = "$current_state" ]; then
  manual_state=1
  require_regular_state_file "$project_env" ".env"
  require_regular_state_file "$current_state" "current.env"
  require_regular_state_file "$current_state.sha256" "current.env.sha256"
  require_canonical_current_env_sha256 "$current_state.sha256"
  (cd "$state_dir" && sha256sum -c current.env.sha256 >/dev/null)
fi

previous_release=$(read_required_single_field "$resolved_state" PREVIOUS_RELEASE_ROOT)
previous_image=$(read_required_single_field "$resolved_state" PREVIOUS_APP_IMAGE)
previous_version=$(read_required_single_field "$resolved_state" PREVIOUS_APP_VERSION)
backup_file=$(sed -n 's/^BACKUP_FILE=//p' "$resolved_state")
schema_compatible=$(sed -n 's/^SCHEMA_COMPATIBLE=//p' "$resolved_state")
previous_release_id=$(release_id_from_root "$previous_release")
validate_release_tuple "$previous_release" "$previous_image" "$previous_version" "$previous_release_id"

manual_stage_dir=''
manual_commit_started=0
manual_commit_complete=0
manual_backup_ready=0
manual_env_backup="$PROJECT_ROOT/.env.before-manual-rollback"
manual_state_backup="$state_dir/current.env.before-manual-rollback"
manual_hash_backup="$state_dir/current.env.sha256.before-manual-rollback"
active_release=''
active_image=''
active_version=''
active_release_id=''

restore_manual_rollback_files() {
  if [ -n "$manual_stage_dir" ] && [ -d "$manual_stage_dir" ]; then
    rm -f "$manual_stage_dir/.env" "$manual_stage_dir/current.env" "$manual_stage_dir/current.env.sha256"
    rmdir "$manual_stage_dir" 2>/dev/null || true
  fi
  if [ "$manual_commit_complete" -eq 0 ]; then
    if [ "$manual_commit_started" -eq 1 ] && [ "$manual_backup_ready" -eq 1 ]; then
      mv "$manual_env_backup" "$project_env" || true
      mv "$manual_state_backup" "$current_state" || true
      mv "$manual_hash_backup" "$current_state.sha256" || true
    fi
    rm -f "$manual_env_backup" "$manual_state_backup" "$manual_hash_backup"
  fi
}

restore_manual_active_app() {
  if [ "$manual_state" -eq 1 ] && [ -n "$active_release" ] && [ -n "$active_image" ] && [ -n "$active_version" ]; then
    RELEASE_ROOT=$active_release
    APP_IMAGE=$active_image
    APP_VERSION=$active_version
    export RELEASE_ROOT APP_IMAGE APP_VERSION
    compose up -d --no-deps app || true
  fi
}

rollback_manual_failure() {
  exit_code=$?
  if [ "$exit_code" -ne 0 ] && [ "$manual_state" -eq 1 ]; then
    restore_manual_rollback_files
    restore_manual_active_app
  fi
  exit "$exit_code"
}

if [ "$manual_state" -eq 1 ]; then
  active_release=$(read_required_single_field "$current_state" RELEASE_ROOT)
  active_image=$(read_required_single_field "$current_state" APP_IMAGE)
  active_version=$(read_required_single_field "$current_state" APP_VERSION)
  active_release_id=$(read_required_single_field "$project_env" RELEASE_ID)
  env_release=$(read_required_single_field "$project_env" RELEASE_ROOT)
  env_image=$(read_required_single_field "$project_env" APP_IMAGE)
  env_version=$(read_required_single_field "$project_env" APP_VERSION)
  if [ "$env_release" != "$active_release" ] || [ "$env_image" != "$active_image" ] || [ "$env_version" != "$active_version" ]; then
    echo "ABORT: .env and current deployment state disagree" >&2
    exit 93
  fi
  validate_release_tuple "$active_release" "$active_image" "$active_version" "$active_release_id"
  for manual_reserved in "$manual_env_backup" "$manual_state_backup" "$manual_hash_backup"; do
    if [ -e "$manual_reserved" ] || [ -L "$manual_reserved" ]; then
      echo "ABORT: reserved manual rollback backup already exists: $manual_reserved" >&2
      exit 93
    fi
  done
  trap rollback_manual_failure EXIT HUP INT TERM
fi

RELEASE_ROOT=$previous_release
APP_IMAGE=$previous_image
APP_VERSION=$previous_version
export RELEASE_ROOT APP_IMAGE APP_VERSION
if [ "$schema_compatible" = "false" ]; then
  if [ -z "$backup_file" ]; then
    echo "ABORT: incompatible-schema rollback requires an exact pre-upgrade backup" >&2
    exit 95
  fi
  expected_confirmation="restore-incompatible-schema:$previous_version:$(sha256sum "$backup_file" | awk '{print $1}')"
  if [ "${CONFIRM_INCOMPATIBLE_SCHEMA_RESTORE:-}" != "$expected_confirmation" ]; then
    echo "ABORT: set CONFIRM_INCOMPATIBLE_SCHEMA_RESTORE=$expected_confirmation to restore the database" >&2
    exit 95
  fi
  "$SCRIPT_DIR/restore-verify.sh" --backup "$backup_file" >/dev/null
  compose stop app
  compose exec -T db dropdb --username makerseed_owner --if-exists makerseed
  compose exec -T db createdb --username makerseed_owner makerseed
  compose exec -T db pg_restore \
    --username makerseed_owner \
    --dbname makerseed \
    --exit-on-error \
    --single-transaction \
    --no-owner \
    --no-acl \
    "/backups/$(basename "$backup_file")"
fi
compose up -d --no-deps app
app_container=$(compose ps -q app)
attempt=0
until [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$app_container")" = "healthy" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 60 ] || { echo "ABORT: rollback app health timeout" >&2; exit 94; }
  sleep 2
done
"$SCRIPT_DIR/smoke.sh"
if [ "$manual_state" -eq 1 ]; then
  manual_stage_dir=$(mktemp -d "$state_dir/.manual-rollback-stage.XXXXXX")
  awk \
    -v app_image="$previous_image" \
    -v app_version="$previous_version" \
    -v release_id="$previous_release_id" \
    -v release_root="$previous_release" '
    /^APP_IMAGE=/ { app_image_seen++; print "APP_IMAGE=" app_image; next }
    /^APP_VERSION=/ { app_version_seen++; print "APP_VERSION=" app_version; next }
    /^RELEASE_ID=/ { release_id_seen++; print "RELEASE_ID=" release_id; next }
    /^RELEASE_ROOT=/ { release_root_seen++; print "RELEASE_ROOT=" release_root; next }
    { print }
    END {
      if (app_image_seen != 1 || app_version_seen != 1 || release_id_seen != 1 || release_root_seen != 1) exit 1
    }
  ' "$project_env" >"$manual_stage_dir/.env"
  awk \
    -v release_root="$previous_release" \
    -v app_image="$previous_image" \
    -v app_version="$previous_version" \
    -v active_release="$active_release" \
    -v active_image="$active_image" \
    -v active_version="$active_version" '
    /^RELEASE_ROOT=/ { release_root_seen++; print "RELEASE_ROOT=" release_root; next }
    /^APP_IMAGE=/ { app_image_seen++; print "APP_IMAGE=" app_image; next }
    /^APP_VERSION=/ { app_version_seen++; print "APP_VERSION=" app_version; next }
    /^PREVIOUS_RELEASE_ROOT=/ { previous_release_seen++; print "PREVIOUS_RELEASE_ROOT=" active_release; next }
    /^PREVIOUS_APP_IMAGE=/ { previous_image_seen++; print "PREVIOUS_APP_IMAGE=" active_image; next }
    /^PREVIOUS_APP_VERSION=/ { previous_version_seen++; print "PREVIOUS_APP_VERSION=" active_version; next }
    { print }
    END {
      if (release_root_seen != 1 || app_image_seen != 1 || app_version_seen != 1 || previous_release_seen != 1 || previous_image_seen != 1 || previous_version_seen != 1) exit 1
    }
  ' "$current_state" >"$manual_stage_dir/current.env"
  chmod 600 "$manual_stage_dir/.env" "$manual_stage_dir/current.env"
  (
    cd "$manual_stage_dir"
    sha256sum current.env > current.env.sha256
    sha256sum -c current.env.sha256 >/dev/null
  )
  cp -p "$project_env" "$manual_env_backup"
  cp -p "$current_state" "$manual_state_backup"
  cp -p "$current_state.sha256" "$manual_hash_backup"
  manual_backup_ready=1
  manual_commit_started=1
  mv "$manual_stage_dir/.env" "$project_env"
  mv "$manual_stage_dir/current.env" "$current_state"
  mv "$manual_stage_dir/current.env.sha256" "$current_state.sha256"
  (cd "$state_dir" && sha256sum -c current.env.sha256 >/dev/null)
  manual_commit_complete=1
  rm -f "$manual_env_backup" "$manual_state_backup" "$manual_hash_backup"
  rmdir "$manual_stage_dir"
  manual_stage_dir=''
fi
ln -sfn "$previous_release" "$PROJECT_ROOT/current"
if [ "$manual_state" -eq 1 ]; then
  trap - EXIT HUP INT TERM
fi
echo "ROLLBACK_OK: $previous_version"
