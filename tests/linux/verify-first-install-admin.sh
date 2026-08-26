#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)
VOLUME_ROOT=/volume1
DOCKER_PARENT=$VOLUME_ROOT/docker
PROJECT_ROOT=$DOCKER_PARENT/makerseed-diagnostic
RELEASE_ID=v0.1.0-first-admin-test
PREFLIGHT_NONCE=nonce-first-admin
RELEASE_ROOT=$PROJECT_ROOT/releases/$RELEASE_ID/deploy
APP_IMAGE=ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:1111111111111111111111111111111111111111111111111111111111111111
ROLLBACK_RELEASE_ID=v0.2.0-manual-rollback-test
ROLLBACK_RELEASE_ROOT=$PROJECT_ROOT/releases/$ROLLBACK_RELEASE_ID/deploy
ROLLBACK_APP_IMAGE=ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:2222222222222222222222222222222222222222222222222222222222222222
ADMIN_PASSWORD='AdminSecret-DoNotLeak-2026!'
SMOKE_PASSWORD='SmokeSecret-DoNotLeak-2026!'
RUN_MARKER=task7-first-admin-$$
PROJECT_MARKER=.makerseed-first-admin-test-marker
DOCKER_MARKER=.makerseed-first-admin-test-marker

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_cleanup_target() {
  target=$1
  resolved=$(realpath "$target" 2>/dev/null || printf '%s' "$target")
  case "$target" in
    "$DOCKER_PARENT"|"$DOCKER_PARENT"/*) ;;
    "$PROJECT_ROOT"|"$PROJECT_ROOT"/*) ;;
    "$TMP_DIR"|"$TMP_DIR"/*) ;;
    *) fail "unsafe cleanup target: $target" ;;
  esac
  case "$resolved" in
    "$DOCKER_PARENT"|"$DOCKER_PARENT"/*|"$PROJECT_ROOT"|"$PROJECT_ROOT"/*|"$TMP_DIR"|"$TMP_DIR"/*) ;;
    *) fail "unsafe resolved cleanup target: $resolved" ;;
  esac
}

cleanup_path() {
  target=$1
  require_cleanup_target "$target"
  [ -e "$target" ] || [ -L "$target" ] || return 0
  if [ "$target" = "$PROJECT_ROOT" ]; then
    [ -f "$PROJECT_ROOT/$PROJECT_MARKER" ] || fail "refusing cleanup of unmarked project root"
    [ "$(cat "$PROJECT_ROOT/$PROJECT_MARKER")" = "$RUN_MARKER" ] || fail "refusing cleanup of marker not owned by this run"
    for child in "$PROJECT_ROOT"/* "$PROJECT_ROOT"/.[!.]* "$PROJECT_ROOT"/..?*; do
      [ -e "$child" ] || [ -L "$child" ] || continue
      child_name=$(basename "$child")
      case "$child_name" in
        data|backups|reports-staging|secrets|deployment-state|releases|current|.env|.deploy-lock|"$PROJECT_MARKER") ;;
        *) fail "refusing cleanup of unknown project child: $child_name" ;;
      esac
    done
    for child_name in data backups reports-staging secrets deployment-state releases current .env .deploy-lock "$PROJECT_MARKER"; do
      child="$PROJECT_ROOT/$child_name"
      if [ -e "$child" ] || [ -L "$child" ]; then
        rm -R "$child"
      fi
    done
    rmdir "$PROJECT_ROOT"
    return 0
  fi
  if [ "$target" = "$DOCKER_PARENT" ]; then
    [ -f "$DOCKER_PARENT/$DOCKER_MARKER" ] || fail "refusing cleanup of unmarked docker parent"
    [ "$(cat "$DOCKER_PARENT/$DOCKER_MARKER")" = "$RUN_MARKER" ] || fail "refusing cleanup of docker marker not owned by this run"
    for child in "$DOCKER_PARENT"/* "$DOCKER_PARENT"/.[!.]* "$DOCKER_PARENT"/..?*; do
      [ -e "$child" ] || [ -L "$child" ] || continue
      child_name=$(basename "$child")
      case "$child_name" in
        "$DOCKER_MARKER") ;;
        *) fail "refusing cleanup of unknown docker parent child: $child_name" ;;
      esac
    done
    rm -f "$DOCKER_PARENT/$DOCKER_MARKER"
    rmdir "$DOCKER_PARENT"
    return 0
  fi
  rm -R "$target"
}

assert_ephemeral_runner() {
  [ "${MKSEED_EPHEMERAL_VOLUME1_TEST:-}" = "1" ] || fail "MKSEED_EPHEMERAL_VOLUME1_TEST=1 is required"
  for root in "$DOCKER_PARENT" "$PROJECT_ROOT"; do
    if [ -e "$root" ] || [ -L "$root" ]; then
      fail "fixed root pre-exists before test-owned marker setup: $root"
    fi
  done
}

write_fake_commands() {
  fake_dir=$1
  log_file=$2
  mkdir -p "$fake_dir"
  cat >"$fake_dir/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "docker $*" >> "$FAKE_DOCKER_LOG"
case "$1 $2" in
  "image inspect") exit 0 ;;
  "version --format") echo "24.0.7" ;;
  "inspect --format")
    case "$*" in
      *'.State.Health'*) echo healthy ;;
      *'.Config.Image'*) echo "$APP_IMAGE" ;;
      *'.Config.Labels'*'com.docker.compose.project.working_dir'*) echo "$PROJECT_ROOT" ;;
      *'.Config.Labels'*) echo makerseed-diagnostic ;;
      *) echo inspect-proof ;;
    esac
    ;;
  "ps --filter"|"ps -a") exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat >"$fake_dir/docker-compose" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "docker-compose $*" >> "$FAKE_DOCKER_LOG"
command_name=''
service_name=''
for arg in "$@"; do
  case "$arg" in
    up|run|ps|exec|version) command_name=$arg ;;
    db|app) service_name=$arg ;;
  esac
done
case "$command_name" in
  version) echo "v2.20.3" ;;
  ps)
    case "$*" in
      *"-a -q db"*) [ -f "$FAKE_STATE_DIR/db-created" ] && echo db-container || true ;;
      *"-q db"*) echo db-container ;;
      *"-q app"*) echo app-container ;;
    esac
    ;;
  up)
    case "$service_name" in
      db) : >"$FAKE_STATE_DIR/db-created" ;;
      app)
        : >"$FAKE_STATE_DIR/app-started"
        printf 'APP_VERSION=%s\nAPP_IMAGE=%s\nRELEASE_ROOT=%s\n' "${APP_VERSION:-}" "${APP_IMAGE:-}" "${RELEASE_ROOT:-}" >"$FAKE_STATE_DIR/app-runtime"
        ;;
    esac
    ;;
  exec)
    case "$*" in
      *"pg_dump"*"--file=/backups/"*)
        backup_name=''
        for exec_arg in "$@"; do
          case "$exec_arg" in
            --file=/backups/*) backup_name=${exec_arg#--file=/backups/} ;;
          esac
        done
        [ -n "$backup_name" ] || exit 98
        printf 'fake dump\n' >"$PROJECT_ROOT/backups/$backup_name"
        ;;
      *"pg_restore --list"*) : ;;
      *"SELECT version_num FROM alembic_version"*) echo "0002_runtime_grants" ;;
      *"json_build_object"*) echo '{"users":1,"evaluations":0,"generations":0}' ;;
      *"createdb"*) : ;;
      *"pg_restore"*) : ;;
      *"information_schema.tables"*) echo 9 ;;
      *"dropdb"*) : ;;
    esac
    ;;
  run)
    case "$*" in
      *"/opt/app/.venv/bin/python -m alembic -c /opt/app/server/alembic.ini upgrade head"*) : >"$FAKE_STATE_DIR/migrated" ;;
      *"/opt/app/.venv/bin/python -m makerseed_app.cli bootstrap-admin"*) : >"$FAKE_STATE_DIR/bootstrapped" ;;
    esac
    ;;
esac
EOF
  cat >"$fake_dir/curl" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "curl $*" >> "$FAKE_DOCKER_LOG"
output=''
cookie_jar=''
csrf=0
method=GET
body_path=''
url=''
write_out=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --cookie-jar) cookie_jar=$2; shift 2 ;;
    --request) method=$2; shift 2 ;;
    --header)
      case "$2" in "X-CSRF-Token:"*) csrf=1 ;; esac
      shift 2
      ;;
    --data-binary) body_path=${2#@}; shift 2 ;;
    --write-out) write_out=1; shift 2 ;;
    http://*) url=$1; shift ;;
    *) shift ;;
  esac
done
path=${url#http://127.0.0.1:18081}
[ -z "$cookie_jar" ] || printf '127.0.0.1\tFALSE\t/\tFALSE\t0\tmkseed_csrf\tcsrf-token\n' >"$cookie_jar"
body='{}'
status=200
case "$method $path" in
  "GET /api/health") body='{"status":"ok"}' ;;
  "GET /api/session")
    case "$output" in /dev/null) status=401 ;; *) body='{"user":{"id":"teacher-id"}}' ;;
    esac
    ;;
  "POST /api/auth/login") body='{"ok":true}' ;;
  "POST /api/admin/users") status=201; body='{"id":"teacher-id"}' ;;
  "POST /api/batches")
    if [ "$csrf" -eq 0 ]; then status=403; body='{"error":"csrf_failed"}'; else status=201; body='{"id":"batch-id"}'; fi
    ;;
  "POST /api/batches/batch-id/evaluations") status=201; body='{"evaluation_id":"evaluation-id","version":1}' ;;
  "GET /api/evaluations"*) body='{"items":[{"id":"evaluation-id"}]}' ;;
  "PUT /api/evaluations/evaluation-id") body='{"id":"evaluation-id"}' ;;
  "POST /api/evaluations/evaluation-id/trash") body='{"id":"evaluation-id"}' ;;
  "POST /api/evaluations/evaluation-id/restore") body='{"id":"evaluation-id"}' ;;
  "DELETE /api/evaluations/evaluation-id") status=204; body='' ;;
  "PATCH /api/admin/users/teacher-id") body='{"id":"teacher-id"}' ;;
esac
if [ -n "$body_path" ]; then
  case "$method $path" in
    "POST /api/auth/login")
      if grep -q '"username":"first-admin"' "$body_path"; then
        grep -Fq "\"password\":\"$FAKE_EXPECTED_ADMIN_PASSWORD\"" "$body_path" || status=401
      else
        grep -Fq "\"password\":\"$FAKE_EXPECTED_TEST_PASSWORD\"" "$body_path" || status=401
      fi
      ;;
    "POST /api/admin/users")
      grep -Fq "\"password\":\"$FAKE_EXPECTED_TEST_PASSWORD\"" "$body_path" || status=401
      ;;
  esac
fi
if [ -n "$output" ]; then
  if [ "$output" != "/dev/null" ]; then
    printf '%s' "$body" >"$output"
  fi
else
  printf '%s' "$body"
fi
[ "$write_out" -eq 0 ] || printf '%s' "$status"
EOF
  cat >"$fake_dir/sha256sum" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "sha256sum $*" >> "$FAKE_DOCKER_LOG"
if [ "${FAKE_FAIL_DEPLOY_SHA256:-}" = "final-stage" ] && [ "$#" -eq 1 ] && [ "$1" = "current.env" ]; then
  exit 96
fi
exec /usr/bin/sha256sum "$@"
EOF
  cat >"$fake_dir/mv" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "mv $*" >> "$FAKE_DOCKER_LOG"
if [ "${FAKE_FAIL_MANUAL_HELPER_MV:-}" = "smoke-dest" ] && [ "$#" -eq 2 ] && [ "$2" = "/volume1/docker/makerseed-diagnostic/secrets/manual_rollback_smoke_test_password" ]; then
  exit 102
fi
if [ "${FAKE_FAIL_DEPLOY_MV:-}" = "final-hash" ] && [ "$#" -eq 2 ] && [ "$1" = "current.env.sha256" ] && [ "$2" = "/volume1/docker/makerseed-diagnostic/deployment-state/current.env.sha256" ]; then
  exit 97
fi
if [ "${FAKE_FAIL_DEPLOY_MV:-}" = "final-hash" ] && [ "$#" -eq 2 ] && [ "${1##*/}" = "current.env.sha256.new" ] && [ "${2##*/}" = "current.env.sha256" ]; then
  exit 97
fi
if [ "${FAKE_FAIL_DEPLOY_MV:-}" = "final-hash" ] && [ "$#" -eq 2 ] && [ "${1##*/}" = "current.env.sha256" ] && [ "${2##*/}" = "current.env.sha256" ]; then
  exit 97
fi
if [ "${FAKE_FAIL_ROLLBACK_MV:-}" = "env" ] && [ "$#" -eq 2 ] && [ "${1##*/}" = ".env" ] && [ "$2" = "/volume1/docker/makerseed-diagnostic/.env" ]; then
  exit 98
fi
if [ "${FAKE_FAIL_ROLLBACK_MV:-}" = "state-hash" ] && [ "$#" -eq 2 ] && [ "${1##*/}" = "current.env.sha256" ] && [ "$2" = "/volume1/docker/makerseed-diagnostic/deployment-state/current.env.sha256" ]; then
  exit 99
fi
exec /usr/bin/mv "$@"
EOF
  cat >"$fake_dir/cp" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "cp $*" >> "$FAKE_DOCKER_LOG"
if [ "${FAKE_FAIL_MANUAL_HELPER_CP:-}" = "smoke-stage" ] && [ "$#" -eq 2 ]; then
  case "$2" in
    /volume1/docker/makerseed-diagnostic/secrets/.manual-rollback-credentials.*/test) exit 101 ;;
  esac
fi
exec /usr/bin/cp "$@"
EOF
  cat >"$fake_dir/ln" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "ln $*" >> "$FAKE_DOCKER_LOG"
if [ "${FAKE_FAIL_ROLLBACK_LN:-}" = "current" ] && [ "$#" -eq 3 ] && [ "$1" = "-sfn" ] && [ "$2" = "/volume1/docker/makerseed-diagnostic/releases/v0.1.0-first-admin-test/deploy" ] && [ "$3" = "/volume1/docker/makerseed-diagnostic/current" ]; then
  exit 100
fi
exec /usr/bin/ln "$@"
EOF
  cat >"$fake_dir/rm" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "rm $*" >> "$FAKE_DOCKER_LOG"
if [ "${FAKE_FAIL_ROLLBACK_RM:-}" = "manual-credential-cleanup" ]; then
  for rm_arg in "$@"; do
    case "$rm_arg" in
      /volume1/docker/makerseed-diagnostic/secrets/manual_rollback_admin_password|/volume1/docker/makerseed-diagnostic/secrets/manual_rollback_smoke_test_password) exit 103 ;;
    esac
  done
fi
exec /usr/bin/rm "$@"
EOF
  chmod 755 "$fake_dir/docker" "$fake_dir/docker-compose" "$fake_dir/curl" "$fake_dir/sha256sum" "$fake_dir/mv" "$fake_dir/cp" "$fake_dir/ln" "$fake_dir/rm"
  : >"$log_file"
}

copy_release_fixture() {
  mkdir -p "$PROJECT_ROOT/releases/$RELEASE_ID"
  cp -R "$PROJECT_DIR/deploy/." "$RELEASE_ROOT/"
  chmod +x "$RELEASE_ROOT"/scripts/*.sh "$RELEASE_ROOT"/postgres-init/10-create-runtime-role.sh
  (
    cd "$PROJECT_ROOT/releases/$RELEASE_ID"
    find deploy -type f | LC_ALL=C sort | while IFS= read -r file; do
      sha256sum "$file"
    done > release-tree.sha256
  )
}

copy_rollback_release_fixture() {
  mkdir -p "$PROJECT_ROOT/releases/$ROLLBACK_RELEASE_ID"
  cp -R "$PROJECT_DIR/deploy/." "$ROLLBACK_RELEASE_ROOT/"
  chmod +x "$ROLLBACK_RELEASE_ROOT"/scripts/*.sh "$ROLLBACK_RELEASE_ROOT"/postgres-init/10-create-runtime-role.sh
  (
    cd "$PROJECT_ROOT/releases/$ROLLBACK_RELEASE_ID"
    find deploy -type f | LC_ALL=C sort | while IFS= read -r file; do
      sha256sum "$file"
    done > release-tree.sha256
  )
}

prepare_project_root() {
  mkdir -p "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/backups" "$PROJECT_ROOT/reports-staging" "$PROJECT_ROOT/secrets" "$PROJECT_ROOT/deployment-state"
  printf '%s\n' "$RUN_MARKER" >"$PROJECT_ROOT/$PROJECT_MARKER"
  printf '%s\n' "$RUN_MARKER" >"$DOCKER_PARENT/$DOCKER_MARKER"
  copy_release_fixture
  cat >"$PROJECT_ROOT/.env" <<EOF
APP_IMAGE=$APP_IMAGE
APP_VERSION=$RELEASE_ID
RELEASE_ID=$RELEASE_ID
PROJECT_ROOT=$PROJECT_ROOT
RELEASE_ROOT=$RELEASE_ROOT
SECRETS_ROOT=$PROJECT_ROOT/secrets
REPORT_ROOT=$PROJECT_ROOT/reports-staging
REPORT_ROOT_PHASE=isolated
EOF
  for secret in postgres_owner_password postgres_runtime_password database_url database_owner_url session_secret bootstrap_secret; do
    printf 'dummy-%s\n' "$secret" >"$PROJECT_ROOT/secrets/$secret"
    chmod 600 "$PROJECT_ROOT/secrets/$secret"
  done
}

write_install_passwords() {
  printf '%s\n' "$ADMIN_PASSWORD" >"$PROJECT_ROOT/secrets/initial_admin_password"
  printf '%s\n' "$SMOKE_PASSWORD" >"$PROJECT_ROOT/secrets/smoke_test_password"
  chmod 600 "$PROJECT_ROOT/secrets/initial_admin_password" "$PROJECT_ROOT/secrets/smoke_test_password"
}

write_manual_rollback_passwords() {
  printf '%s\n' "$ADMIN_PASSWORD" >"$PROJECT_ROOT/secrets/manual_rollback_admin_password"
  printf '%s\n' "$SMOKE_PASSWORD" >"$PROJECT_ROOT/secrets/manual_rollback_smoke_test_password"
  chmod 600 "$PROJECT_ROOT/secrets/manual_rollback_admin_password" "$PROJECT_ROOT/secrets/manual_rollback_smoke_test_password"
}

write_manual_rollback_sources() {
  admin_source=$TMP_DIR/manual-admin-password-source
  test_source=$TMP_DIR/manual-test-password-source
  printf '%s\n' "$ADMIN_PASSWORD" >"$admin_source"
  printf '%s\n' "$SMOKE_PASSWORD" >"$test_source"
  chmod 600 "$admin_source" "$test_source"
}

manual_admin_dest() {
  printf '%s\n' "$PROJECT_ROOT/secrets/manual_rollback_admin_password"
}

manual_test_dest() {
  printf '%s\n' "$PROJECT_ROOT/secrets/manual_rollback_smoke_test_password"
}

assert_no_manual_rollback_credentials() {
  [ ! -e "$(manual_admin_dest)" ] && [ ! -L "$(manual_admin_dest)" ] || fail "manual helper left admin credential destination"
  [ ! -e "$(manual_test_dest)" ] && [ ! -L "$(manual_test_dest)" ] || fail "manual helper left smoke credential destination"
  if find "$PROJECT_ROOT/secrets" -maxdepth 1 -name '.manual-rollback-credentials.*' -print | grep . >/dev/null 2>&1; then
    fail "manual helper left this-run temp credential files"
  fi
}

run_prepare_manual_rollback_smoke() {
  fail_helper_cp=${RUN_FAIL_MANUAL_HELPER_CP:-}
  fail_helper_mv=${RUN_FAIL_MANUAL_HELPER_MV:-}
  set +e
  PROJECT_ROOT=$PROJECT_ROOT \
  SECRETS_ROOT=$PROJECT_ROOT/secrets \
  PATH="$FAKE_DOCKER_DIR:$PATH" \
  FAKE_DOCKER_LOG=$FAKE_DOCKER_LOG \
  FAKE_FAIL_MANUAL_HELPER_CP=$fail_helper_cp \
  FAKE_FAIL_MANUAL_HELPER_MV=$fail_helper_mv \
    "$PROJECT_DIR/deploy/scripts/prepare-manual-rollback-smoke.sh" \
    --admin-username first-admin \
    --admin-password-file "$admin_source" \
    --test-password-file "$test_source"
  helper_status=$?
  set -e
  printf '%s\n' "$RUN_MARKER" >"$PROJECT_ROOT/$PROJECT_MARKER"
  return "$helper_status"
}

assert_manual_helper_success() {
  [ "$(cat "$(manual_admin_dest)")" = "$ADMIN_PASSWORD" ] || fail "manual admin credential content mismatch"
  [ "$(cat "$(manual_test_dest)")" = "$SMOKE_PASSWORD" ] || fail "manual smoke credential content mismatch"
  [ "$(stat -c %a "$(manual_admin_dest)")" = "600" ] || fail "manual admin credential mode is not 600"
  [ "$(stat -c %a "$(manual_test_dest)")" = "600" ] || fail "manual smoke credential mode is not 600"
}

run_deploy() {
  smoke_admin_password_file=${RUN_SMOKE_ADMIN_PASSWORD_FILE:-$PROJECT_ROOT/secrets/initial_admin_password}
  smoke_test_password_file=${RUN_SMOKE_TEST_PASSWORD_FILE:-$PROJECT_ROOT/secrets/smoke_test_password}
  fail_deploy_sha256=${RUN_FAIL_DEPLOY_SHA256:-}
  fail_deploy_mv=${RUN_FAIL_DEPLOY_MV:-}
  rm -f "$PROJECT_ROOT/$PROJECT_MARKER"
  set +e
  BOOTSTRAP_ADMIN_USERNAME=first-admin \
  BOOTSTRAP_ADMIN_DISPLAY_NAME="First Admin" \
  SMOKE_ADMIN_USERNAME=first-admin \
  SMOKE_ADMIN_PASSWORD_FILE=$smoke_admin_password_file \
  SMOKE_TEST_PASSWORD_FILE=$smoke_test_password_file \
  PROJECT_ROOT=$PROJECT_ROOT \
  RELEASE_ROOT=$RELEASE_ROOT \
  RELEASE_ID=$RELEASE_ID \
  SECRETS_ROOT=$PROJECT_ROOT/secrets \
  REPORT_ROOT=$PROJECT_ROOT/reports-staging \
  REPORT_ROOT_PHASE=isolated \
  APP_IMAGE=$APP_IMAGE \
  APP_VERSION=$RELEASE_ID \
  PREFLIGHT_NONCE=$PREFLIGHT_NONCE \
  MIGRATION_COMPATIBILITY=backward-compatible \
  PATH="$FAKE_DOCKER_DIR:$PATH" \
  FAKE_DOCKER_LOG=$FAKE_DOCKER_LOG \
  FAKE_STATE_DIR=$FAKE_STATE_DIR \
  FAKE_EXPECTED_ADMIN_PASSWORD=$ADMIN_PASSWORD \
  FAKE_EXPECTED_TEST_PASSWORD=$SMOKE_PASSWORD \
  FAKE_FAIL_DEPLOY_SHA256=$fail_deploy_sha256 \
  FAKE_FAIL_DEPLOY_MV=$fail_deploy_mv \
    "$PROJECT_DIR/deploy/scripts/deploy.sh"
  deploy_status=$?
  set -e
  printf '%s\n' "$RUN_MARKER" >"$PROJECT_ROOT/$PROJECT_MARKER"
  return "$deploy_status"
}

run_rollback() {
  rollback_state_file=$1
  fail_rollback_mv=${RUN_FAIL_ROLLBACK_MV:-}
  fail_rollback_ln=${RUN_FAIL_ROLLBACK_LN:-}
  fail_rollback_rm=${RUN_FAIL_ROLLBACK_RM:-}
  set +e
  SMOKE_ADMIN_USERNAME=first-admin \
  SMOKE_ADMIN_PASSWORD_FILE=$PROJECT_ROOT/secrets/initial_admin_password \
  SMOKE_TEST_PASSWORD_FILE=$PROJECT_ROOT/secrets/smoke_test_password \
  PROJECT_ROOT=$PROJECT_ROOT \
  SECRETS_ROOT=$PROJECT_ROOT/secrets \
  PATH="$FAKE_DOCKER_DIR:$PATH" \
  FAKE_DOCKER_LOG=$FAKE_DOCKER_LOG \
  FAKE_STATE_DIR=$FAKE_STATE_DIR \
  FAKE_EXPECTED_ADMIN_PASSWORD=$ADMIN_PASSWORD \
  FAKE_EXPECTED_TEST_PASSWORD=$SMOKE_PASSWORD \
  FAKE_FAIL_ROLLBACK_MV=$fail_rollback_mv \
  FAKE_FAIL_ROLLBACK_LN=$fail_rollback_ln \
  FAKE_FAIL_ROLLBACK_RM=$fail_rollback_rm \
    "$PROJECT_DIR/deploy/scripts/rollback.sh" --state "$rollback_state_file"
  rollback_status=$?
  set -e
  printf '%s\n' "$RUN_MARKER" >"$PROJECT_ROOT/$PROJECT_MARKER"
  return "$rollback_status"
}

run_manual_rollback_runbook() {
  write_manual_rollback_sources
  awk '
    /^```sh$/ { block += 1; capture = (block == 1); next }
    /^```$/ { capture = 0; next }
    capture { print }
  ' "$PROJECT_DIR/deploy/synology/rollback.md" >"$TMP_DIR/manual-rollback-runbook.sh"
  set +e
  MANUAL_ROLLBACK_ADMIN_USERNAME=first-admin \
  MANUAL_ROLLBACK_ADMIN_PASSWORD_SOURCE=$admin_source \
  MANUAL_ROLLBACK_TEST_PASSWORD_SOURCE=$test_source \
  PROJECT_ROOT=$PROJECT_ROOT \
  PATH="$FAKE_DOCKER_DIR:$PATH" \
  FAKE_DOCKER_LOG=$FAKE_DOCKER_LOG \
  FAKE_STATE_DIR=$FAKE_STATE_DIR \
  FAKE_EXPECTED_ADMIN_PASSWORD=$ADMIN_PASSWORD \
  FAKE_EXPECTED_TEST_PASSWORD=$SMOKE_PASSWORD \
    sh "$TMP_DIR/manual-rollback-runbook.sh"
  rollback_status=$?
  set -e
  printf '%s\n' "$RUN_MARKER" >"$PROJECT_ROOT/$PROJECT_MARKER"
  return "$rollback_status"
}

run_manual_helper_interrupted_in_pty() {
  tty_bin=$TMP_DIR/fake-tty-bin
  stty_log=$TMP_DIR/stty.log
  wrapper=$TMP_DIR/manual-helper-interactive-wrapper.sh
  helper_pid_file=$TMP_DIR/manual-helper.pid
  mkdir -p "$tty_bin"
  cat >"$tty_bin/stty" <<'EOF'
#!/bin/sh
set -eu
if [ "$#" -eq 1 ] && [ "$1" = "-g" ]; then
  echo saved-tty-state
  exit 0
fi
if [ "$#" -eq 1 ] && [ "$1" = "-echo" ]; then
  printf '%s\n' "stty:-echo" >>"$FAKE_STTY_LOG"
  exit 0
fi
printf '%s\n' "stty:restore:$*" >>"$FAKE_STTY_LOG"
exit 0
EOF
  chmod 755 "$tty_bin/stty"
  cat >"$wrapper" <<EOF
#!/bin/sh
set -eu
printf '%s\n' "\$\$" >"$helper_pid_file"
exec env \\
  PROJECT_ROOT=$PROJECT_ROOT \\
  SECRETS_ROOT=$PROJECT_ROOT/secrets \\
  PATH=$tty_bin:/usr/bin:/bin \\
  FAKE_STTY_LOG=$stty_log \\
  "$PROJECT_DIR/deploy/scripts/prepare-manual-rollback-smoke.sh" --admin-username first-admin --interactive
EOF
  chmod 700 "$wrapper"
  set +e
  ( (printf '%s\n' "$ADMIN_PASSWORD"; sleep 5) | script -qfec "sh '$wrapper'" /dev/null >/dev/null 2>&1 ) &
  runner_pid=$!
  helper_status=124
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$helper_pid_file" ] && break
    sleep 0.1
  done
  if [ -f "$helper_pid_file" ]; then
    kill -TERM "$(cat "$helper_pid_file")" 2>/dev/null || true
    wait "$runner_pid"
    helper_status=$?
  else
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  set -e
  printf '%s\n' "$RUN_MARKER" >"$PROJECT_ROOT/$PROJECT_MARKER"
  [ "$helper_status" -ne 0 ] || fail "manual helper interruption reported success"
  grep -q '^stty:-echo$' "$stty_log" || fail "manual helper did not disable tty echo in interactive mode"
  grep -q '^stty:restore:saved-tty-state$' "$stty_log" || fail "manual helper did not restore saved tty state after interruption"
  assert_no_manual_rollback_credentials
}

line_number() {
  pattern=$1
  grep -n "$pattern" "$FAKE_DOCKER_LOG" | sed -n '1s/:.*//p'
}

run_handoff() {
  awk '
    /^```sh$/ { block += 1; capture = (block == 2); next }
    /^```$/ { capture = 0; next }
    capture { print }
  ' "$PROJECT_DIR/deploy/synology/initial-admin-handoff.md" >"$TMP_DIR/initial-admin-handoff.sh"
  sh "$TMP_DIR/initial-admin-handoff.sh"
}

assert_current_state_unchanged() {
  expected_state_hash=$1
  expected_checksum_hash=$2
  actual_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
  actual_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
  [ "$expected_state_hash" = "$actual_state_hash" ] || fail "current.env changed after failed final-state commit"
  [ "$expected_checksum_hash" = "$actual_checksum_hash" ] || fail "current.env.sha256 changed after failed final-state commit"
  (cd "$PROJECT_ROOT/deployment-state" && sha256sum -c current.env.sha256 >/dev/null) || fail "current.env.sha256 no longer verifies after failed final-state commit"
}

assert_smoke_password_unchanged() {
  expected_hash=$1
  [ -f "$PROJECT_ROOT/secrets/smoke_test_password" ] || fail "smoke password was removed before final deployment state was verified"
  actual_hash=$(sha256sum "$PROJECT_ROOT/secrets/smoke_test_password" | awk '{print $1}')
  [ "$expected_hash" = "$actual_hash" ] || fail "smoke password changed before final deployment state was verified"
}

assert_no_upgrade_mutation_started() {
  if grep -q 'pg_dump' "$FAKE_DOCKER_LOG"; then
    fail "unsafe previous deployment checksum was accepted before backup"
  fi
  if grep -q '/opt/app/.venv/bin/python -m alembic -c /opt/app/server/alembic.ini upgrade head' "$FAKE_DOCKER_LOG"; then
    fail "unsafe previous deployment checksum was accepted before migration"
  fi
  if grep -q 'docker-compose .* up .* app' "$FAKE_DOCKER_LOG"; then
    fail "unsafe previous deployment checksum was accepted before app startup"
  fi
}

restore_verified_current_state() {
  cp -p "$TMP_DIR/good-current.env" "$PROJECT_ROOT/deployment-state/current.env"
  cp -p "$TMP_DIR/good-current.env.sha256" "$PROJECT_ROOT/deployment-state/current.env.sha256"
}

require_line_once() {
  file=$1
  line=$2
  count=$(grep -Fxc "$line" "$file" || true)
  [ "$count" -eq 1 ] || fail "$file does not contain exactly one line: $line"
}

stage_manual_rollback_active_release() {
  copy_rollback_release_fixture
  active_db_image=$(sed -n 's/^DB_IMAGE=//p' "$PROJECT_ROOT/deployment-state/current.env")
  active_db_config_hash=$(sed -n 's/^DB_CONTAINER_CONFIG_HASH=//p' "$PROJECT_ROOT/deployment-state/current.env")
  active_backup_file=$(sed -n 's/^BACKUP_FILE=//p' "$PROJECT_ROOT/deployment-state/current.env")
  active_schema_compatible=$(sed -n 's/^SCHEMA_COMPATIBLE=//p' "$PROJECT_ROOT/deployment-state/current.env")
  active_handoff=$(sed -n 's/^INITIAL_ADMIN_HANDOFF=//p' "$PROJECT_ROOT/deployment-state/current.env")
  cat >"$PROJECT_ROOT/.env" <<EOF
APP_IMAGE=$ROLLBACK_APP_IMAGE
APP_VERSION=$ROLLBACK_RELEASE_ID
RELEASE_ID=$ROLLBACK_RELEASE_ID
PROJECT_ROOT=$PROJECT_ROOT
RELEASE_ROOT=$ROLLBACK_RELEASE_ROOT
SECRETS_ROOT=$PROJECT_ROOT/secrets
REPORT_ROOT=$PROJECT_ROOT/reports-staging
REPORT_ROOT_PHASE=isolated
EOF
  cat >"$PROJECT_ROOT/deployment-state/current.env" <<EOF
RELEASE_ROOT=$ROLLBACK_RELEASE_ROOT
APP_IMAGE=$ROLLBACK_APP_IMAGE
APP_VERSION=$ROLLBACK_RELEASE_ID
DB_IMAGE=$active_db_image
DB_CONTAINER_CONFIG_HASH=$active_db_config_hash
SCHEMA_COMPATIBLE=$active_schema_compatible
BACKUP_FILE=$active_backup_file
PREVIOUS_RELEASE_ROOT=$RELEASE_ROOT
PREVIOUS_APP_IMAGE=$APP_IMAGE
PREVIOUS_APP_VERSION=$RELEASE_ID
INITIAL_ADMIN_HANDOFF=$active_handoff
EOF
  chmod 600 "$PROJECT_ROOT/.env" "$PROJECT_ROOT/deployment-state/current.env"
  (cd "$PROJECT_ROOT/deployment-state" && sha256sum current.env > current.env.sha256)
  ln -sfn "$ROLLBACK_RELEASE_ROOT" "$PROJECT_ROOT/current"
}

assert_manual_rollback_committed() {
  expected_db_image=$1
  expected_db_config_hash=$2
  require_line_once "$PROJECT_ROOT/.env" "APP_IMAGE=$APP_IMAGE"
  require_line_once "$PROJECT_ROOT/.env" "APP_VERSION=$RELEASE_ID"
  require_line_once "$PROJECT_ROOT/.env" "RELEASE_ID=$RELEASE_ID"
  require_line_once "$PROJECT_ROOT/.env" "RELEASE_ROOT=$RELEASE_ROOT"
  require_line_once "$PROJECT_ROOT/.env" "PROJECT_ROOT=$PROJECT_ROOT"
  require_line_once "$PROJECT_ROOT/.env" "SECRETS_ROOT=$PROJECT_ROOT/secrets"
  require_line_once "$PROJECT_ROOT/.env" "REPORT_ROOT=$PROJECT_ROOT/reports-staging"
  require_line_once "$PROJECT_ROOT/.env" "REPORT_ROOT_PHASE=isolated"
  require_line_once "$PROJECT_ROOT/deployment-state/current.env" "RELEASE_ROOT=$RELEASE_ROOT"
  require_line_once "$PROJECT_ROOT/deployment-state/current.env" "APP_IMAGE=$APP_IMAGE"
  require_line_once "$PROJECT_ROOT/deployment-state/current.env" "APP_VERSION=$RELEASE_ID"
  require_line_once "$PROJECT_ROOT/deployment-state/current.env" "PREVIOUS_RELEASE_ROOT=$ROLLBACK_RELEASE_ROOT"
  require_line_once "$PROJECT_ROOT/deployment-state/current.env" "PREVIOUS_APP_IMAGE=$ROLLBACK_APP_IMAGE"
  require_line_once "$PROJECT_ROOT/deployment-state/current.env" "PREVIOUS_APP_VERSION=$ROLLBACK_RELEASE_ID"
  require_line_once "$PROJECT_ROOT/deployment-state/current.env" "DB_IMAGE=$expected_db_image"
  require_line_once "$PROJECT_ROOT/deployment-state/current.env" "DB_CONTAINER_CONFIG_HASH=$expected_db_config_hash"
  (cd "$PROJECT_ROOT/deployment-state" && sha256sum -c current.env.sha256 >/dev/null) || fail "manual rollback current.env.sha256 does not verify"
  grep -q '  current.env$' "$PROJECT_ROOT/deployment-state/current.env.sha256" || fail "manual rollback current.env.sha256 does not name current.env"
  [ "$(readlink "$PROJECT_ROOT/current")" = "$RELEASE_ROOT" ] || fail "manual rollback current symlink does not point to previous release"
  require_line_once "$FAKE_STATE_DIR/app-runtime" "APP_VERSION=$RELEASE_ID"
  require_line_once "$FAKE_STATE_DIR/app-runtime" "APP_IMAGE=$APP_IMAGE"
  require_line_once "$FAKE_STATE_DIR/app-runtime" "RELEASE_ROOT=$RELEASE_ROOT"
}

assert_manual_rollback_failure_restored() {
  expected_env_hash=$1
  expected_state_hash=$2
  expected_checksum_hash=$3
  expected_current_target=$4
  actual_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
  actual_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
  actual_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
  [ "$expected_env_hash" = "$actual_env_hash" ] || fail "manual rollback commit failure changed .env"
  [ "$expected_state_hash" = "$actual_state_hash" ] || fail "manual rollback commit failure changed current.env"
  [ "$expected_checksum_hash" = "$actual_checksum_hash" ] || fail "manual rollback commit failure changed current.env.sha256"
  [ "$(readlink "$PROJECT_ROOT/current")" = "$expected_current_target" ] || fail "manual rollback commit failure changed current symlink"
  require_line_once "$FAKE_STATE_DIR/app-runtime" "APP_VERSION=$ROLLBACK_RELEASE_ID"
  require_line_once "$FAKE_STATE_DIR/app-runtime" "APP_IMAGE=$ROLLBACK_APP_IMAGE"
  require_line_once "$FAKE_STATE_DIR/app-runtime" "RELEASE_ROOT=$ROLLBACK_RELEASE_ROOT"
}

assert_manual_rollback_rejected_before_mutation() {
  expected_env_hash=$1
  expected_state_hash=$2
  expected_checksum_hash=$3
  expected_current_target=$4
  actual_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
  actual_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
  actual_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
  [ "$expected_env_hash" = "$actual_env_hash" ] || fail "rejected rollback changed .env"
  [ "$expected_state_hash" = "$actual_state_hash" ] || fail "rejected rollback changed current.env"
  [ "$expected_checksum_hash" = "$actual_checksum_hash" ] || fail "rejected rollback changed current.env.sha256"
  [ "$(readlink "$PROJECT_ROOT/current")" = "$expected_current_target" ] || fail "rejected rollback changed current symlink"
  if grep -q 'docker-compose .* up .* app' "$FAKE_DOCKER_LOG"; then
    fail "rejected rollback started app"
  fi
}

assert_no_rollback_checksum_command() {
  if grep -q 'sha256sum -c' "$FAKE_DOCKER_LOG"; then
    fail "rejected rollback checked checksum before exact state classification"
  fi
}

assert_pending_rollback_rejected_before_docker() {
  expected_env_hash=$1
  expected_state_hash=$2
  expected_checksum_hash=$3
  expected_current_target=$4
  actual_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
  actual_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
  actual_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
  [ "$expected_env_hash" = "$actual_env_hash" ] || fail "rejected pending rollback changed .env"
  [ "$expected_state_hash" = "$actual_state_hash" ] || fail "rejected pending rollback changed current.env"
  [ "$expected_checksum_hash" = "$actual_checksum_hash" ] || fail "rejected pending rollback changed current.env.sha256"
  [ "$(readlink "$PROJECT_ROOT/current")" = "$expected_current_target" ] || fail "rejected pending rollback changed current symlink"
  if grep -q 'docker-compose .* up .* app' "$FAKE_DOCKER_LOG"; then
    fail "malformed pending checksum was accepted before Docker mutation"
  fi
}

assert_pending_checksum_canonical() {
  [ -f "$PROJECT_ROOT/deployment-state/pending.env.sha256" ] || fail "pending.env.sha256 was not retained for failed deploy"
  grep -Eq '^[0-9a-f]{64}  pending\.env$' "$PROJECT_ROOT/deployment-state/pending.env.sha256" || fail "pending.env.sha256 does not record canonical pending.env"
}

assert_manual_rollback_cleanup_failure_left_rolled_back_state() {
  expected_db_image=$1
  expected_db_config_hash=$2
  assert_manual_rollback_committed "$expected_db_image" "$expected_db_config_hash"
  if grep -q "APP_VERSION=$ROLLBACK_RELEASE_ID" "$FAKE_STATE_DIR/app-runtime"; then
    fail "post-commit credential cleanup failure restarted formerly active app"
  fi
}

assert_upgrade_rejects_bad_current_hash() {
  reason=$1
  write_install_passwords
  before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
  : >"$FAKE_DOCKER_LOG"
  if run_deploy >/dev/null 2>&1; then
    fail "$reason current.env.sha256 was accepted"
  fi
  after_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
  [ "$before_state_hash" = "$after_state_hash" ] || fail "$reason current.env.sha256 failure changed current.env"
  assert_no_upgrade_mutation_started
  rm -f "$PROJECT_ROOT/deployment-state/pending.env" "$PROJECT_ROOT/deployment-state/pending.env.sha256"
}

[ "$(uname -s)" = "Linux" ] || fail "Linux test must run on Linux"
assert_ephemeral_runner

TMP_DIR=$(mktemp -d)
FAKE_DOCKER_DIR=$TMP_DIR/fake-bin
FAKE_DOCKER_LOG=$TMP_DIR/docker.log
FAKE_STATE_DIR=$TMP_DIR/fake-state
mkdir -p "$FAKE_STATE_DIR"
write_fake_commands "$FAKE_DOCKER_DIR" "$FAKE_DOCKER_LOG"
trap 'cleanup_path "$PROJECT_ROOT"; cleanup_path "$DOCKER_PARENT"; cleanup_path "$TMP_DIR"' EXIT HUP INT TERM

prepare_project_root
printf 'unknown\n' >"$PROJECT_ROOT/unknown-child"
if (cleanup_path "$PROJECT_ROOT") >/dev/null 2>&1; then
  fail "cleanup accepted an unknown fixed-root child"
fi
rm -f "$PROJECT_ROOT/unknown-child"
write_install_passwords
run_deploy >/dev/null

migrate_line=$(line_number '/opt/app/.venv/bin/python -m alembic -c /opt/app/server/alembic.ini upgrade head')
bootstrap_line=$(line_number '/opt/app/.venv/bin/python -m makerseed_app.cli bootstrap-admin')
app_line=$(line_number 'docker-compose .* up .* app')
[ -n "$migrate_line" ] || fail "migration command was not captured"
[ -n "$bootstrap_line" ] || fail "first install did not invoke bootstrap-admin"
[ -n "$app_line" ] || fail "app startup was not captured"
[ "$migrate_line" -lt "$bootstrap_line" ] || fail "bootstrap-admin ran before migration"
[ "$bootstrap_line" -lt "$app_line" ] || fail "app started before bootstrap-admin"

if grep -q 'DoNotLeak' "$FAKE_DOCKER_LOG"; then
  fail "password appeared in fake Docker/curl argv log"
fi
[ -f "$PROJECT_ROOT/secrets/initial_admin_password" ] || fail "initial admin password was removed before handoff"
[ ! -e "$PROJECT_ROOT/secrets/smoke_test_password" ] || fail "temporary smoke password was not removed after successful smoke"
grep -q '^INITIAL_ADMIN_HANDOFF=pending$' "$PROJECT_ROOT/deployment-state/current.env" || fail "handoff state was not recorded as pending"
(cd "$PROJECT_ROOT/deployment-state" && sha256sum -c current.env.sha256 >/dev/null) || fail "current.env.sha256 is not valid after first install"
grep -q '  current.env$' "$PROJECT_ROOT/deployment-state/current.env.sha256" || fail "current.env.sha256 does not record current.env after first install"
handoff_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
handoff_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
printf 'STALE_BACKUP_SHOULD_NOT_RESTORE=1\n' >"$PROJECT_ROOT/deployment-state/current.env.before-handoff"
printf '0000000000000000000000000000000000000000000000000000000000000000  current.env\n' >"$PROJECT_ROOT/deployment-state/current.env.sha256.before-handoff"
rm -f "$PROJECT_ROOT/secrets/initial_admin_password"
if run_handoff >/dev/null 2>&1; then
  fail "handoff accepted stale backup paths"
fi
after_handoff_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
after_handoff_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
[ "$handoff_state_hash" = "$after_handoff_state_hash" ] || fail "stale handoff backup overwrote current.env"
[ "$handoff_checksum_hash" = "$after_handoff_checksum_hash" ] || fail "stale handoff backup overwrote current.env.sha256"
rm -f "$PROJECT_ROOT/deployment-state/current.env.before-handoff" "$PROJECT_ROOT/deployment-state/current.env.sha256.before-handoff"
rm -f "$FAKE_STATE_DIR"/db-created "$FAKE_STATE_DIR"/app-started "$FAKE_STATE_DIR"/migrated "$FAKE_STATE_DIR"/bootstrapped

write_install_passwords
: >"$FAKE_DOCKER_LOG"
run_deploy >/dev/null
if grep -q 'bootstrap-admin' "$FAKE_DOCKER_LOG"; then
  fail "upgrade path reran bootstrap-admin"
fi
if grep -q 'DoNotLeak' "$FAKE_DOCKER_LOG"; then
  fail "password appeared in upgrade fake Docker/curl argv log"
fi
(cd "$PROJECT_ROOT/deployment-state" && sha256sum -c current.env.sha256 >/dev/null) || fail "current.env.sha256 is not valid after upgrade"
grep -q '  current.env$' "$PROJECT_ROOT/deployment-state/current.env.sha256" || fail "current.env.sha256 does not record current.env after upgrade"
cp -p "$PROJECT_ROOT/deployment-state/current.env" "$TMP_DIR/good-current.env"
cp -p "$PROJECT_ROOT/deployment-state/current.env.sha256" "$TMP_DIR/good-current.env.sha256"

rm -f "$PROJECT_ROOT/deployment-state/current.env.sha256"
assert_upgrade_rejects_bad_current_hash "missing"
restore_verified_current_state

rm -f "$PROJECT_ROOT/deployment-state/current.env.sha256"
ln -s current.env.sha256.good "$PROJECT_ROOT/deployment-state/current.env.sha256"
assert_upgrade_rejects_bad_current_hash "symlinked"
rm -f "$PROJECT_ROOT/deployment-state/current.env.sha256"
restore_verified_current_state

printf '0000000000000000000000000000000000000000000000000000000000000000  current.env\n' >"$PROJECT_ROOT/deployment-state/current.env.sha256"
assert_upgrade_rejects_bad_current_hash "mismatched"
restore_verified_current_state

printf 'decoy state\n' >"$PROJECT_ROOT/deployment-state/decoy.env"
(cd "$PROJECT_ROOT/deployment-state" && sha256sum decoy.env > current.env.sha256)
assert_upgrade_rejects_bad_current_hash "other-file"
restore_verified_current_state

printf 'decoy state\n' >"$PROJECT_ROOT/deployment-state/decoy.env"
(cd "$PROJECT_ROOT/deployment-state" && sha256sum decoy.env >> current.env.sha256)
assert_upgrade_rejects_bad_current_hash "extra-line"
restore_verified_current_state

printf 'not-a-checksum\n' >>"$PROJECT_ROOT/deployment-state/current.env.sha256"
assert_upgrade_rejects_bad_current_hash "malformed-extra-line"
restore_verified_current_state

write_manual_rollback_sources
: >"$FAKE_DOCKER_LOG"
run_prepare_manual_rollback_smoke >/dev/null
assert_manual_helper_success
rm -f "$(manual_admin_dest)" "$(manual_test_dest)"

write_manual_rollback_sources
printf '%s\n' 'preexisting-admin-credential' >"$(manual_admin_dest)"
chmod 600 "$(manual_admin_dest)"
before_manual_admin_hash=$(sha256sum "$(manual_admin_dest)" | awk '{print $1}')
: >"$FAKE_DOCKER_LOG"
if run_prepare_manual_rollback_smoke >/dev/null 2>&1; then
  fail "manual helper replaced preexisting credential destination"
fi
after_manual_admin_hash=$(sha256sum "$(manual_admin_dest)" | awk '{print $1}')
[ "$before_manual_admin_hash" = "$after_manual_admin_hash" ] || fail "manual helper modified preexisting credential destination"
[ ! -e "$(manual_test_dest)" ] && [ ! -L "$(manual_test_dest)" ] || fail "manual helper published second credential after preexisting destination refusal"
rm -f "$(manual_admin_dest)"

write_manual_rollback_sources
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_MANUAL_HELPER_CP=smoke-stage run_prepare_manual_rollback_smoke >/dev/null 2>&1; then
  fail "manual helper second copy failure reported success"
fi
assert_no_manual_rollback_credentials

write_manual_rollback_sources
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_MANUAL_HELPER_MV=smoke-dest run_prepare_manual_rollback_smoke >/dev/null 2>&1; then
  fail "manual helper second publish failure reported success"
fi
assert_no_manual_rollback_credentials

write_manual_rollback_sources
printf '%s\n' short >"$admin_source"
chmod 600 "$admin_source"
: >"$FAKE_DOCKER_LOG"
if run_prepare_manual_rollback_smoke >/dev/null 2>&1; then
  fail "manual helper accepted short admin credential"
fi
assert_no_manual_rollback_credentials

write_manual_rollback_sources
printf 'first-line\nsecond-line\n' >"$test_source"
chmod 600 "$test_source"
: >"$FAKE_DOCKER_LOG"
if run_prepare_manual_rollback_smoke >/dev/null 2>&1; then
  fail "manual helper accepted multiline smoke credential"
fi
assert_no_manual_rollback_credentials

run_manual_helper_interrupted_in_pty

stage_manual_rollback_active_release
manual_db_image=$(sed -n 's/^DB_IMAGE=//p' "$PROJECT_ROOT/deployment-state/current.env")
manual_db_config_hash=$(sed -n 's/^DB_CONTAINER_CONFIG_HASH=//p' "$PROJECT_ROOT/deployment-state/current.env")
: >"$FAKE_DOCKER_LOG"
run_manual_rollback_runbook >/dev/null
assert_manual_rollback_committed "$manual_db_image" "$manual_db_config_hash"
[ ! -e "$PROJECT_ROOT/secrets/manual_rollback_admin_password" ] || fail "manual rollback admin password was not removed after success"
[ ! -e "$PROJECT_ROOT/secrets/manual_rollback_smoke_test_password" ] || fail "manual rollback smoke password was not removed after success"

cat >"$PROJECT_ROOT/deployment-state/pending.env" <<EOF
RELEASE_ROOT=$ROLLBACK_RELEASE_ROOT
APP_IMAGE=$ROLLBACK_APP_IMAGE
APP_VERSION=$ROLLBACK_RELEASE_ID
DB_IMAGE=$manual_db_image
DB_CONTAINER_CONFIG_HASH=$manual_db_config_hash
SCHEMA_COMPATIBLE=true
BACKUP_FILE=
PREVIOUS_RELEASE_ROOT=$RELEASE_ROOT
PREVIOUS_APP_IMAGE=$APP_IMAGE
PREVIOUS_APP_VERSION=$RELEASE_ID
INITIAL_ADMIN_HANDOFF=pending
EOF
chmod 600 "$PROJECT_ROOT/deployment-state/pending.env"
(cd "$PROJECT_ROOT/deployment-state" && sha256sum pending.env > pending.env.sha256)
before_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
write_install_passwords
: >"$FAKE_DOCKER_LOG"
run_rollback "$PROJECT_ROOT/deployment-state/pending.env" >/dev/null
after_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
after_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
after_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
[ "$before_env_hash" = "$after_env_hash" ] || fail "automatic pending rollback rewrote .env"
[ "$before_state_hash" = "$after_state_hash" ] || fail "automatic pending rollback rewrote current.env"
[ "$before_checksum_hash" = "$after_checksum_hash" ] || fail "automatic pending rollback rewrote current.env.sha256"
rm -f "$PROJECT_ROOT/deployment-state/pending.env" "$PROJECT_ROOT/deployment-state/pending.env.sha256"

stage_manual_rollback_active_release
cat >"$PROJECT_ROOT/deployment-state/other.env" <<EOF
RELEASE_ROOT=$ROLLBACK_RELEASE_ROOT
APP_IMAGE=$ROLLBACK_APP_IMAGE
APP_VERSION=$ROLLBACK_RELEASE_ID
DB_IMAGE=$manual_db_image
DB_CONTAINER_CONFIG_HASH=$manual_db_config_hash
SCHEMA_COMPATIBLE=true
BACKUP_FILE=
PREVIOUS_RELEASE_ROOT=$RELEASE_ROOT
PREVIOUS_APP_IMAGE=$APP_IMAGE
PREVIOUS_APP_VERSION=$RELEASE_ID
INITIAL_ADMIN_HANDOFF=pending
EOF
chmod 600 "$PROJECT_ROOT/deployment-state/other.env"
(cd "$PROJECT_ROOT/deployment-state" && sha256sum other.env > other.env.sha256)
before_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
before_current_target=$(readlink "$PROJECT_ROOT/current")
write_install_passwords
: >"$FAKE_DOCKER_LOG"
if run_rollback "$PROJECT_ROOT/deployment-state/other.env" >/dev/null 2>&1; then
  fail "rollback accepted non-current non-pending state file"
fi
assert_manual_rollback_rejected_before_mutation "$before_env_hash" "$before_state_hash" "$before_checksum_hash" "$before_current_target"
rm -f "$PROJECT_ROOT/deployment-state/other.env" "$PROJECT_ROOT/deployment-state/other.env.sha256"

stage_manual_rollback_active_release
before_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
before_current_target=$(readlink "$PROJECT_ROOT/current")
write_manual_rollback_passwords
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_ROLLBACK_MV=env run_rollback "$PROJECT_ROOT/deployment-state/current.env" >/dev/null 2>&1; then
  fail "manual rollback .env commit failure reported success"
fi
assert_manual_rollback_failure_restored "$before_env_hash" "$before_state_hash" "$before_checksum_hash" "$before_current_target"
rm -f "$PROJECT_ROOT/deployment-state/current.env.before-manual-rollback" \
  "$PROJECT_ROOT/deployment-state/current.env.sha256.before-manual-rollback" \
  "$PROJECT_ROOT/.env.before-manual-rollback"

stage_manual_rollback_active_release
before_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
before_current_target=$(readlink "$PROJECT_ROOT/current")
write_manual_rollback_passwords
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_ROLLBACK_MV=state-hash run_rollback "$PROJECT_ROOT/deployment-state/current.env" >/dev/null 2>&1; then
  fail "manual rollback state checksum commit failure reported success"
fi
assert_manual_rollback_failure_restored "$before_env_hash" "$before_state_hash" "$before_checksum_hash" "$before_current_target"
rm -f "$PROJECT_ROOT/deployment-state/current.env.before-manual-rollback" \
  "$PROJECT_ROOT/deployment-state/current.env.sha256.before-manual-rollback" \
  "$PROJECT_ROOT/.env.before-manual-rollback"

stage_manual_rollback_active_release
before_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
before_current_target=$(readlink "$PROJECT_ROOT/current")
write_manual_rollback_passwords
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_ROLLBACK_LN=current run_rollback "$PROJECT_ROOT/deployment-state/current.env" >/dev/null 2>&1; then
  fail "manual rollback current symlink failure reported success"
fi
assert_manual_rollback_failure_restored "$before_env_hash" "$before_state_hash" "$before_checksum_hash" "$before_current_target"
rm -f "$PROJECT_ROOT/deployment-state/current.env.before-manual-rollback" \
  "$PROJECT_ROOT/deployment-state/current.env.sha256.before-manual-rollback" \
  "$PROJECT_ROOT/.env.before-manual-rollback" \
  "$PROJECT_ROOT/deployment-state/current.before-manual-rollback"

stage_manual_rollback_active_release
cat >"$PROJECT_ROOT/deployment-state/other.env" <<EOF
RELEASE_ROOT=$ROLLBACK_RELEASE_ROOT
APP_IMAGE=$ROLLBACK_APP_IMAGE
APP_VERSION=$ROLLBACK_RELEASE_ID
DB_IMAGE=$manual_db_image
DB_CONTAINER_CONFIG_HASH=$manual_db_config_hash
SCHEMA_COMPATIBLE=true
BACKUP_FILE=
PREVIOUS_RELEASE_ROOT=$RELEASE_ROOT
PREVIOUS_APP_IMAGE=$APP_IMAGE
PREVIOUS_APP_VERSION=$RELEASE_ID
INITIAL_ADMIN_HANDOFF=pending
EOF
chmod 600 "$PROJECT_ROOT/deployment-state/other.env"
(cd "$PROJECT_ROOT/deployment-state" && sha256sum other.env > other.env.sha256)
before_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
before_current_target=$(readlink "$PROJECT_ROOT/current")
write_install_passwords
: >"$FAKE_DOCKER_LOG"
if run_rollback "$PROJECT_ROOT/deployment-state/other.env" >/dev/null 2>&1; then
  fail "rollback accepted non-current non-pending state file with checksum"
fi
assert_manual_rollback_rejected_before_mutation "$before_env_hash" "$before_state_hash" "$before_checksum_hash" "$before_current_target"
assert_no_rollback_checksum_command
rm -f "$PROJECT_ROOT/deployment-state/other.env" "$PROJECT_ROOT/deployment-state/other.env.sha256"

cat >"$PROJECT_ROOT/deployment-state/pending.env" <<EOF
RELEASE_ROOT=$ROLLBACK_RELEASE_ROOT
APP_IMAGE=$ROLLBACK_APP_IMAGE
APP_VERSION=$ROLLBACK_RELEASE_ID
DB_IMAGE=$manual_db_image
DB_CONTAINER_CONFIG_HASH=$manual_db_config_hash
SCHEMA_COMPATIBLE=true
BACKUP_FILE=
PREVIOUS_RELEASE_ROOT=$RELEASE_ROOT
PREVIOUS_APP_IMAGE=$APP_IMAGE
PREVIOUS_APP_VERSION=$RELEASE_ID
INITIAL_ADMIN_HANDOFF=pending
EOF
chmod 600 "$PROJECT_ROOT/deployment-state/pending.env"
printf 'decoy\n' >"$PROJECT_ROOT/deployment-state/decoy.env"
for pending_checksum_case in other-file absolute-path extra-line; do
  case "$pending_checksum_case" in
    other-file)
      (cd "$PROJECT_ROOT/deployment-state" && sha256sum decoy.env > pending.env.sha256)
      ;;
    absolute-path)
      (cd "$PROJECT_ROOT/deployment-state" && sha256sum "$PROJECT_ROOT/deployment-state/pending.env" > pending.env.sha256)
      ;;
    extra-line)
      (cd "$PROJECT_ROOT/deployment-state" && sha256sum pending.env > pending.env.sha256 && sha256sum decoy.env >> pending.env.sha256)
      ;;
  esac
  before_env_hash=$(sha256sum "$PROJECT_ROOT/.env" | awk '{print $1}')
  before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
  before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
  before_current_target=$(readlink "$PROJECT_ROOT/current")
  write_install_passwords
  : >"$FAKE_DOCKER_LOG"
  if run_rollback "$PROJECT_ROOT/deployment-state/pending.env" >/dev/null 2>&1; then
    fail "rollback accepted malformed pending checksum: $pending_checksum_case"
  fi
  assert_pending_rollback_rejected_before_docker "$before_env_hash" "$before_state_hash" "$before_checksum_hash" "$before_current_target"
done
rm -f "$PROJECT_ROOT/deployment-state/pending.env" "$PROJECT_ROOT/deployment-state/pending.env.sha256" "$PROJECT_ROOT/deployment-state/decoy.env"

stage_manual_rollback_active_release
manual_db_image=$(sed -n 's/^DB_IMAGE=//p' "$PROJECT_ROOT/deployment-state/current.env")
manual_db_config_hash=$(sed -n 's/^DB_CONTAINER_CONFIG_HASH=//p' "$PROJECT_ROOT/deployment-state/current.env")
write_manual_rollback_passwords
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_ROLLBACK_RM=manual-credential-cleanup run_rollback "$PROJECT_ROOT/deployment-state/current.env" >/dev/null 2>&1; then
  fail "manual rollback credential cleanup failure reported full success"
fi
assert_manual_rollback_cleanup_failure_left_rolled_back_state "$manual_db_image" "$manual_db_config_hash"
rm -f "$(manual_admin_dest)" "$(manual_test_dest)"

write_install_passwords
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
before_smoke_hash=$(sha256sum "$PROJECT_ROOT/secrets/smoke_test_password" | awk '{print $1}')
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_DEPLOY_SHA256=final-stage run_deploy >/dev/null 2>&1; then
  fail "final checksum staging failure reported deploy success"
fi
assert_current_state_unchanged "$before_state_hash" "$before_checksum_hash"
assert_pending_checksum_canonical
assert_smoke_password_unchanged "$before_smoke_hash"
rm -f "$PROJECT_ROOT/deployment-state/pending.env" "$PROJECT_ROOT/deployment-state/pending.env.sha256"

write_install_passwords
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
before_smoke_hash=$(sha256sum "$PROJECT_ROOT/secrets/smoke_test_password" | awk '{print $1}')
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_DEPLOY_MV=final-hash run_deploy >/dev/null 2>&1; then
  fail "final checksum rename failure reported deploy success"
fi
assert_current_state_unchanged "$before_state_hash" "$before_checksum_hash"
assert_smoke_password_unchanged "$before_smoke_hash"
rm -f "$PROJECT_ROOT/deployment-state/pending.env" "$PROJECT_ROOT/deployment-state/pending.env.sha256"

write_install_passwords
printf '%s\n' 'WrongAdminSecret-DoNotLeak-2026!' >"$PROJECT_ROOT/secrets/wrong_admin_password"
chmod 600 "$PROJECT_ROOT/secrets/wrong_admin_password"
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
: >"$FAKE_DOCKER_LOG"
if RUN_SMOKE_ADMIN_PASSWORD_FILE=$PROJECT_ROOT/secrets/wrong_admin_password run_deploy >/dev/null 2>&1; then
  fail "wrong admin smoke password file was accepted"
fi
after_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
[ "$before_state_hash" = "$after_state_hash" ] || fail "failed smoke committed deployment state"
rm -f "$PROJECT_ROOT/deployment-state/pending.env" "$PROJECT_ROOT/deployment-state/pending.env.sha256"

write_install_passwords
printf '%s\n' "$SMOKE_PASSWORD" >"$PROJECT_ROOT/secrets/alternate_smoke_password"
chmod 600 "$PROJECT_ROOT/secrets/alternate_smoke_password"
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_alternate_hash=$(sha256sum "$PROJECT_ROOT/secrets/alternate_smoke_password" | awk '{print $1}')
: >"$FAKE_DOCKER_LOG"
if RUN_SMOKE_TEST_PASSWORD_FILE=$PROJECT_ROOT/secrets/alternate_smoke_password run_deploy >/dev/null 2>&1; then
  fail "alternate smoke password file was accepted"
fi
[ -f "$PROJECT_ROOT/secrets/alternate_smoke_password" ] || fail "alternate smoke password file was deleted"
after_alternate_hash=$(sha256sum "$PROJECT_ROOT/secrets/alternate_smoke_password" | awk '{print $1}')
[ "$before_alternate_hash" = "$after_alternate_hash" ] || fail "alternate smoke password file was modified"
after_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
[ "$before_state_hash" = "$after_state_hash" ] || fail "alternate smoke file failure committed deployment state"
if grep -q 'pg_dump' "$FAKE_DOCKER_LOG"; then
  fail "alternate smoke file validation ran after backup"
fi
if grep -q '/opt/app/.venv/bin/python -m alembic -c /opt/app/server/alembic.ini upgrade head' "$FAKE_DOCKER_LOG"; then
  fail "alternate smoke file validation ran after migration"
fi
if grep -q 'docker-compose .* up .* app' "$FAKE_DOCKER_LOG"; then
  fail "alternate smoke file validation ran after app startup"
fi
[ ! -e "$PROJECT_ROOT/deployment-state/pending.env" ] || fail "alternate smoke file failure wrote pending deployment state"
[ ! -e "$PROJECT_ROOT/deployment-state/pending.env.sha256" ] || fail "alternate smoke file failure wrote pending deployment checksum"

cleanup_path "$PROJECT_ROOT"
cleanup_path "$DOCKER_PARENT"
mkdir -p "$FAKE_STATE_DIR"
rm -f "$FAKE_STATE_DIR"/db-created "$FAKE_STATE_DIR"/app-started "$FAKE_STATE_DIR"/migrated "$FAKE_STATE_DIR"/bootstrapped
prepare_project_root
write_install_passwords
before_smoke_hash=$(sha256sum "$PROJECT_ROOT/secrets/smoke_test_password" | awk '{print $1}')
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_DEPLOY_MV=final-hash run_deploy >/dev/null 2>&1; then
  fail "first-install final checksum rename failure reported deploy success"
fi
[ ! -e "$PROJECT_ROOT/deployment-state/current.env" ] || fail "first-install final checksum rename failure left partial current.env"
[ ! -e "$PROJECT_ROOT/deployment-state/current.env.sha256" ] || fail "first-install final checksum rename failure left partial current.env.sha256"
[ ! -e "$PROJECT_ROOT/current" ] && [ ! -L "$PROJECT_ROOT/current" ] || fail "first-install final checksum rename failure published current release"
assert_smoke_password_unchanged "$before_smoke_hash"

echo "PASS: first-install admin bootstrap and smoke credential behavior verified."
