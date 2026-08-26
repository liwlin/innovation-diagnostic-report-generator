#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root

if [ "$#" -ne 2 ] || [ "$1" != "--state" ]; then
  echo "usage: rollback.sh --state /exact/project/deployment-state/pending.env" >&2
  exit 90
fi

state_file=$2
state_dir=$(readlink -f "$PROJECT_ROOT/deployment-state")
if [ ! -f "$state_file" ] || [ -L "$state_file" ]; then
  echo "ABORT: deployment-state file is missing or unsafe" >&2
  exit 91
fi
resolved_state=$(readlink -f "$state_file")
case "$resolved_state" in
  "$state_dir"/*.env) ;;
  *) echo "ABORT: deployment-state file is outside the exact state directory" >&2; exit 91 ;;
esac
if [ ! -f "$resolved_state.sha256" ]; then
  echo "ABORT: deployment-state SHA-256 proof is missing" >&2
  exit 92
fi
(cd "$state_dir" && sha256sum -c "$(basename "$resolved_state").sha256") >/dev/null

previous_release=$(sed -n 's/^PREVIOUS_RELEASE_ROOT=//p' "$resolved_state")
previous_image=$(sed -n 's/^PREVIOUS_APP_IMAGE=//p' "$resolved_state")
previous_version=$(sed -n 's/^PREVIOUS_APP_VERSION=//p' "$resolved_state")
backup_file=$(sed -n 's/^BACKUP_FILE=//p' "$resolved_state")
schema_compatible=$(sed -n 's/^SCHEMA_COMPATIBLE=//p' "$resolved_state")
if [ -z "$previous_release" ] || [ -z "$previous_image" ] || [ -z "$previous_version" ]; then
  echo "ABORT: no previous deployment is recorded" >&2
  exit 93
fi
case "$previous_release" in
  "$PROJECT_ROOT"/releases/*/deploy) ;;
  *) echo "ABORT: previous release path is outside project releases" >&2; exit 93 ;;
esac
case "$previous_image" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) echo "ABORT: previous app image is not digest pinned" >&2; exit 93 ;;
esac

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
ln -sfn "$previous_release" "$PROJECT_ROOT/current"
echo "ROLLBACK_OK: $previous_version"
