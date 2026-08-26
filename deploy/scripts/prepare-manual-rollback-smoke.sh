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
helper_stage_dir=''
helper_complete=0
published_admin=0
published_test=0
tty_restore_needed=0
saved_tty_state=''
tty_path=/dev/tty

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

refuse_existing_destinations() {
  for dest_path in "$admin_dest" "$test_dest"; do
    if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
      echo "ABORT: manual rollback credential destination already exists" >&2
      exit 91
    fi
  done
}

restore_tty_state() {
  if [ "$tty_restore_needed" -eq 1 ]; then
    stty "$saved_tty_state" <"$tty_path" || true
    tty_restore_needed=0
  fi
}

cleanup_helper() {
  exit_code=$?
  restore_tty_state
  if [ "$helper_complete" -eq 0 ]; then
    if [ "$published_admin" -eq 1 ]; then
      rm -f "$admin_dest" || true
    fi
    if [ "$published_test" -eq 1 ]; then
      rm -f "$test_dest" || true
    fi
    if [ -n "$helper_stage_dir" ] && [ -d "$helper_stage_dir" ]; then
      rm -f "$helper_stage_dir/admin" "$helper_stage_dir/test"
      rmdir "$helper_stage_dir" 2>/dev/null || true
    fi
  fi
  exit "$exit_code"
}

stage_secret_from_file() {
  source_path=$1
  stage_path=$2
  label=$3
  require_source_file "$source_path" "$label"
  if [ -e "$stage_path" ] || [ -L "$stage_path" ]; then
    echo "ABORT: reserved manual rollback credential temp path already exists" >&2
    exit 91
  fi
  cp "$source_path" "$stage_path"
  chmod 600 "$stage_path"
}

validate_staged_secret() {
  stage_path=$1
  label=$2
  if [ ! -f "$stage_path" ] || [ -L "$stage_path" ]; then
    echo "ABORT: staged $label credential is missing or unsafe" >&2
    exit 91
  fi
  mode=$(stat -c %a "$stage_path")
  if [ "$mode" != "600" ]; then
    echo "ABORT: staged $label credential must be mode 600" >&2
    exit 91
  fi
  line_count=$(wc -l <"$stage_path" | awk '{print $1}')
  if [ "$line_count" -ne 1 ]; then
    echo "ABORT: staged $label credential must contain exactly one logical line" >&2
    exit 91
  fi
  byte_count=$(wc -c <"$stage_path" | awk '{print $1}')
  secret_length=$((byte_count - 1))
  if [ "$secret_length" -lt 12 ]; then
    echo "ABORT: staged $label credential is too short" >&2
    exit 91
  fi
  if ! LC_ALL=C awk '
    NR == 1 {
      if ($0 ~ /[[:cntrl:]]/) exit 1
      next
    }
    { exit 1 }
    END { if (NR != 1) exit 1 }
  ' "$stage_path"; then
    echo "ABORT: staged $label credential contains unsafe control characters" >&2
    exit 91
  fi
}

read_secret_interactively() {
  prompt_label=$1
  stage_path=$2
  if [ -e "$stage_path" ] || [ -L "$stage_path" ]; then
    echo "ABORT: reserved manual rollback credential temp path already exists" >&2
    exit 91
  fi
  if [ ! -r "$tty_path" ]; then
    echo "ABORT: interactive manual rollback requires a TTY" >&2
    exit 91
  fi
  if [ "$tty_restore_needed" -eq 0 ]; then
    saved_tty_state=$(stty -g <"$tty_path")
    stty -echo <"$tty_path"
    tty_restore_needed=1
  fi
  printf '%s: ' "$prompt_label" >"$tty_path"
  IFS= read -r secret_value <"$tty_path"
  echo >&2
  if [ -z "$secret_value" ]; then
    echo "ABORT: manual rollback credential must not be empty" >&2
    exit 91
  fi
  printf '%s\n' "$secret_value" >"$stage_path"
  unset secret_value
  chmod 600 "$stage_path"
}

require_bounded_username "$admin_username"

admin_dest="$SECRETS_ROOT/manual_rollback_admin_password"
test_dest="$SECRETS_ROOT/manual_rollback_smoke_test_password"
refuse_existing_destinations

helper_stage_dir=$(mktemp -d "$SECRETS_ROOT/.manual-rollback-credentials.XXXXXX")
trap cleanup_helper EXIT HUP INT TERM
admin_stage="$helper_stage_dir/admin"
test_stage="$helper_stage_dir/test"

case "$interactive:$admin_source:$test_source" in
  1::)
    read_secret_interactively "Admin secret" "$admin_stage"
    read_secret_interactively "Temporary smoke secret" "$test_stage"
    ;;
  0:*:*)
    stage_secret_from_file "$admin_source" "$admin_stage" "admin"
    stage_secret_from_file "$test_source" "$test_stage" "smoke"
    ;;
  *)
    usage
    ;;
esac

validate_staged_secret "$admin_stage" "admin"
validate_staged_secret "$test_stage" "smoke"
restore_tty_state
refuse_existing_destinations
published_admin=1
mv "$admin_stage" "$admin_dest"
published_test=1
mv "$test_stage" "$test_dest"
validate_staged_secret "$admin_dest" "admin"
validate_staged_secret "$test_dest" "smoke"
helper_complete=1
rmdir "$helper_stage_dir"
helper_stage_dir=''
trap - EXIT HUP INT TERM

echo "MANUAL_ROLLBACK_SMOKE_READY"
