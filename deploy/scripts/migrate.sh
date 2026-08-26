#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${RELEASE_ROOT:?RELEASE_ROOT is required}"
: "${SECRETS_ROOT:?SECRETS_ROOT is required}"

owner_url_file="$SECRETS_ROOT/database_owner_url"
require_regular_secret "$owner_url_file"

compose run --rm --no-deps \
  -e MKSEED_MIGRATION_DATABASE_URL_FILE=/run/maintenance/database_owner_url \
  -v "$owner_url_file:/run/maintenance/database_owner_url:ro" \
  app /opt/app/.venv/bin/python -m alembic -c /opt/app/server/alembic.ini upgrade head
