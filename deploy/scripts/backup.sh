#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${RELEASE_ROOT:?RELEASE_ROOT is required}"
: "${APP_VERSION:?APP_VERSION is required}"

case "$APP_VERSION" in
  *[!A-Za-z0-9._-]*) echo "ABORT: APP_VERSION contains unsafe characters" >&2; exit 30 ;;
esac

backup_dir="$PROJECT_ROOT/backups"
if [ ! -d "$backup_dir" ] || [ -L "$backup_dir" ]; then
  echo "ABORT: dedicated backup directory is missing or unsafe" >&2
  exit 31
fi

free_kb=$(df -Pk "$backup_dir" | awk 'NR==2 {print $4}')
if [ -z "$free_kb" ] || [ "$free_kb" -lt 1048576 ]; then
  echo "ABORT: less than 1 GiB is available for backup" >&2
  exit 32
fi

db_container=$(compose ps -q db)
if [ -z "$db_container" ]; then
  echo "ABORT: database container is not running" >&2
  exit 33
fi
health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$db_container")
if [ "$health" != "healthy" ]; then
  echo "ABORT: database container is not healthy" >&2
  exit 33
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
base="makerseed_${timestamp}_${APP_VERSION}.dump"
partial="$backup_dir/.${base}.partial"
final="$backup_dir/$base"
manifest_partial="$backup_dir/.${base}.json.partial"
manifest="$backup_dir/${base}.json"
sha_partial="$backup_dir/.${base}.sha256.partial"
sha_file="$backup_dir/${base}.sha256"

cleanup_partial() {
  rm -f "$partial" "$manifest_partial" "$sha_partial"
}
trap cleanup_partial EXIT HUP INT TERM

compose exec -T db pg_dump \
  --username makerseed_owner \
  --dbname makerseed \
  --format=custom \
  --no-owner \
  --no-acl \
  --file="/backups/.${base}.partial"

compose exec -T db pg_restore --list "/backups/.${base}.partial" >/dev/null
if [ ! -s "$partial" ]; then
  echo "ABORT: pg_dump produced an empty archive" >&2
  exit 34
fi

sha=$(sha256sum "$partial" | awk '{print $1}')
schema_version=$(compose exec -T db psql --username makerseed_owner --dbname makerseed --tuples-only --no-align --command 'SELECT version_num FROM alembic_version')
case "$schema_version" in
  ''|*[!A-Za-z0-9._-]*) echo "ABORT: invalid database schema version" >&2; exit 35 ;;
esac
counts=$(compose exec -T db psql --username makerseed_owner --dbname makerseed --tuples-only --no-align --command "SELECT json_build_object('users', (SELECT count(*) FROM users), 'evaluations', (SELECT count(*) FROM evaluations), 'generations', (SELECT count(*) FROM generation_records))::text")

printf '%s  %s\n' "$sha" "$base" >"$sha_partial"
printf '{"created_at":"%s","app_version":"%s","schema_version":"%s","dump_file":"%s","sha256":"%s","counts":%s}\n' \
  "$timestamp" "$APP_VERSION" "$schema_version" "$base" "$sha" "$counts" >"$manifest_partial"
chmod 600 "$partial" "$sha_partial" "$manifest_partial"
mv "$partial" "$final"
mv "$sha_partial" "$sha_file"
mv "$manifest_partial" "$manifest"
sync
trap - EXIT HUP INT TERM

echo "BACKUP_OK: $final"
