#!/bin/sh
set -eu

EXPECTED_PROJECT_ROOT=/volume1/docker/makerseed-diagnostic

require_exact_project_root() {
  : "${PROJECT_ROOT:?PROJECT_ROOT is required}"
  if [ -L "$PROJECT_ROOT" ]; then
    echo "ABORT: project root must not be a symbolic link" >&2
    exit 20
  fi
  resolved=$(readlink -f "$PROJECT_ROOT" 2>/dev/null || true)
  if [ "$resolved" != "$EXPECTED_PROJECT_ROOT" ]; then
    echo "ABORT: PROJECT_ROOT must resolve exactly to $EXPECTED_PROJECT_ROOT" >&2
    exit 20
  fi
}

require_regular_secret() {
  secret_path=$1
  if [ ! -f "$secret_path" ] || [ -L "$secret_path" ]; then
    echo "ABORT: required secret file is missing or unsafe" >&2
    exit 21
  fi
}

compose() {
  docker-compose -p makerseed-diagnostic --env-file "$PROJECT_ROOT/.env" -f "$RELEASE_ROOT/compose.yaml" "$@"
}
