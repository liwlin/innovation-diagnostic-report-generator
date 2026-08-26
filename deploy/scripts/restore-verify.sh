#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${RELEASE_ROOT:?RELEASE_ROOT is required}"

if [ "$#" -ne 2 ] || [ "$1" != "--backup" ]; then
  echo "usage: restore-verify.sh --backup /exact/project/backup.dump" >&2
  exit 40
fi

backup_dir=$(readlink -f "$PROJECT_ROOT/backups")
backup_file=$2
if [ ! -f "$backup_file" ] || [ -L "$backup_file" ]; then
  echo "ABORT: backup archive is missing or unsafe" >&2
  exit 41
fi
resolved_backup=$(readlink -f "$backup_file")
case "$resolved_backup" in
  "$backup_dir"/makerseed_*.dump) ;;
  *) echo "ABORT: backup archive is outside the exact project backup directory" >&2; exit 41 ;;
esac

base=$(basename "$resolved_backup")
sha_file="$resolved_backup.sha256"
if [ ! -f "$sha_file" ] || [ -L "$sha_file" ]; then
  echo "ABORT: backup SHA-256 proof is missing or unsafe" >&2
  exit 42
fi
(cd "$backup_dir" && sha256sum -c "$(basename "$sha_file")") >/dev/null

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
verify_db="makerseed_verify_${timestamp}_$$"
case "$verify_db" in
  makerseed_verify_[A-Za-z0-9_]*) ;;
  *) echo "ABORT: invalid verification database name" >&2; exit 43 ;;
esac

cleanup_database() {
  compose exec -T db dropdb --username makerseed_owner --if-exists "$verify_db" >/dev/null 2>&1 || true
}
trap cleanup_database EXIT HUP INT TERM

compose exec -T db createdb --username makerseed_owner "$verify_db"
compose exec -T db pg_restore \
  --username makerseed_owner \
  --dbname "$verify_db" \
  --exit-on-error \
  --single-transaction \
  --no-owner \
  --no-acl \
  "/backups/$base"

table_count=$(compose exec -T db psql --username makerseed_owner --dbname "$verify_db" --tuples-only --no-align --command "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('users','sessions','batches','students','evaluations','evaluation_versions','generation_records','audit_events','emergency_imports')")
schema_version=$(compose exec -T db psql --username makerseed_owner --dbname "$verify_db" --tuples-only --no-align --command 'SELECT version_num FROM alembic_version')
if [ "$table_count" -ne 9 ] || [ -z "$schema_version" ]; then
  echo "ABORT: restored database invariants failed" >&2
  exit 44
fi

sha=$(sha256sum "$resolved_backup" | awk '{print $1}')
verdict="$backup_dir/restore-verification_${timestamp}.json"
printf '{"verified_at":"%s","dump_file":"%s","sha256":"%s","schema_version":"%s","required_tables":%s,"result":"pass"}\n' \
  "$timestamp" "$base" "$sha" "$schema_version" "$table_count" >"$verdict"
chmod 600 "$verdict"

cleanup_database
trap - EXIT HUP INT TERM
echo "RESTORE_VERIFY_OK: $verdict"
