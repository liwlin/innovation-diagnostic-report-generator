#!/bin/sh
set -eu
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${SECRETS_ROOT:?SECRETS_ROOT is required}"

if [ "$SECRETS_ROOT" != "$PROJECT_ROOT/secrets" ]; then
  echo "ABORT: manual rollback secrets root must be the project secrets directory" >&2
  exit 91
fi

admin_username=''
admin_source=''
test_source=''
interactive=0

usage() {
  cat >&2 <<'USAGE'
usage: prepare-manual-rollback-smoke.sh --admin-username NAME [--admin-password-file FILE --test-password-file FILE | --interactive]
USAGE
  exit 90
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --admin-username)
      [ "$#" -ge 2 ] || usage
      admin_username=$2
      shift 2
      ;;
    --admin-password-file)
      [ "$#" -ge 2 ] || usage
      admin_source=$2
      shift 2
      ;;
    --test-password-file)
      [ "$#" -ge 2 ] || usage
      test_source=$2
      shift 2
      ;;
    --interactive)
      interactive=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

require_bounded_username() {
  username=$1
  if [ "${#username}" -lt 1 ] || [ "${#username}" -gt 64 ]; then
    echo "ABORT: admin username length is unsafe" >&2
    exit 93
  fi
  case "$username" in
    *[!A-Za-z0-9._@+-]*)
      echo "ABORT: admin username contains unsafe characters" >&2
      exit 93
      ;;
  esac
}

require_source_file() {
  source_path=$1
  label=$2
  if [ ! -f "$source_path" ] || [ -L "$source_path" ]; then
    echo "ABORT: $label source is missing or unsafe" >&2
    exit 91
  fi
  mode=$(stat -c %a "$source_path")
  if [ "$mode" != "600" ]; then
    echo "ABORT: $label source must be mode 600" >&2
    exit 91
  fi
}

publish_secret_from_file() {
  source_path=$1
  dest_path=$2
  label=$3
  require_source_file "$source_path" "$label"
  tmp_path="$dest_path.prepare.$$"
  if [ -e "$tmp_path" ] || [ -L "$tmp_path" ]; then
    echo "ABORT: reserved manual rollback credential temp path already exists" >&2
    exit 91
  fi
  cp "$source_path" "$tmp_path"
  chmod 600 "$tmp_path"
  mv "$tmp_path" "$dest_path"
}

read_secret_interactively() {
  prompt_label=$1
  dest_path=$2
  tmp_path="$dest_path.prepare.$$"
  if [ -e "$tmp_path" ] || [ -L "$tmp_path" ]; then
    echo "ABORT: reserved manual rollback credential temp path already exists" >&2
    exit 91
  fi
  if [ ! -r /dev/tty ]; then
    echo "ABORT: interactive manual rollback requires a TTY" >&2
    exit 91
  fi
  printf '%s: ' "$prompt_label" >/dev/tty
  old_tty=$(stty -g </dev/tty)
  stty -echo </dev/tty
  IFS= read -r secret_value </dev/tty || {
    stty "$old_tty" </dev/tty
    echo >&2
    exit 91
  }
  stty "$old_tty" </dev/tty
  echo >&2
  if [ -z "$secret_value" ]; then
    echo "ABORT: manual rollback credential must not be empty" >&2
    exit 91
  fi
  printf '%s\n' "$secret_value" >"$tmp_path"
  unset secret_value
  chmod 600 "$tmp_path"
  mv "$tmp_path" "$dest_path"
}

require_bounded_username "$admin_username"

admin_dest="$SECRETS_ROOT/manual_rollback_admin_password"
test_dest="$SECRETS_ROOT/manual_rollback_smoke_test_password"

case "$interactive:$admin_source:$test_source" in
  1::)
    read_secret_interactively "Admin secret" "$admin_dest"
    read_secret_interactively "Temporary smoke secret" "$test_dest"
    ;;
  0:*:*)
    publish_secret_from_file "$admin_source" "$admin_dest" "admin credential"
    publish_secret_from_file "$test_source" "$test_dest" "smoke credential"
    ;;
  *)
    usage
    ;;
esac

echo "MANUAL_ROLLBACK_SMOKE_READY"
