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
ADMIN_PASSWORD='AdminSecret-DoNotLeak-2026!'
SMOKE_PASSWORD='SmokeSecret-DoNotLeak-2026!'
RUN_MARKER=task7-first-admin-$$

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
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ "$target" = "$PROJECT_ROOT" ]; then
      [ -f "$TMP_DIR/project-root.marker" ] || fail "refusing cleanup of unmarked project root"
      [ "$(cat "$TMP_DIR/project-root.marker")" = "$RUN_MARKER" ] || fail "refusing cleanup of marker not owned by this run"
    fi
    if [ "$target" = "$DOCKER_PARENT" ]; then
      [ -f "$TMP_DIR/docker-parent.marker" ] || fail "refusing cleanup of unmarked docker parent"
      [ "$(cat "$TMP_DIR/docker-parent.marker")" = "$RUN_MARKER" ] || fail "refusing cleanup of docker marker not owned by this run"
    fi
    rm -R "$target"
  fi
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
      *"-a -q db"*) [ -f "$PROJECT_ROOT/.fake-db-created" ] && echo db-container || true ;;
      *"-q db"*) echo db-container ;;
      *"-q app"*) echo app-container ;;
    esac
    ;;
  up)
    case "$service_name" in
      db) : >"$PROJECT_ROOT/.fake-db-created" ;;
      app) : >"$PROJECT_ROOT/.fake-app-started" ;;
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
      *"alembic -c /opt/app/server/alembic.ini upgrade head"*) : >"$PROJECT_ROOT/.fake-migrated" ;;
      *"python -m makerseed_app.cli bootstrap-admin"*) : >"$PROJECT_ROOT/.fake-bootstrapped" ;;
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
[ -z "$body_path" ] || grep -q 'DoNotLeak' "$body_path" || true
if [ -n "$output" ]; then
  if [ "$output" != "/dev/null" ]; then
    printf '%s' "$body" >"$output"
  fi
else
  printf '%s' "$body"
fi
[ "$write_out" -eq 0 ] || printf '%s' "$status"
EOF
  chmod 755 "$fake_dir/docker" "$fake_dir/docker-compose" "$fake_dir/curl"
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

prepare_project_root() {
  mkdir -p "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/backups" "$PROJECT_ROOT/reports-staging" "$PROJECT_ROOT/secrets" "$PROJECT_ROOT/deployment-state"
  printf '%s\n' "$RUN_MARKER" >"$TMP_DIR/project-root.marker"
  printf '%s\n' "$RUN_MARKER" >"$TMP_DIR/docker-parent.marker"
  copy_release_fixture
  cat >"$PROJECT_ROOT/.env" <<EOF
APP_IMAGE=$APP_IMAGE
APP_VERSION=$RELEASE_ID
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

run_deploy() {
  BOOTSTRAP_ADMIN_USERNAME=first-admin \
  BOOTSTRAP_ADMIN_DISPLAY_NAME="First Admin" \
  SMOKE_ADMIN_USERNAME=first-admin \
  SMOKE_ADMIN_PASSWORD_FILE=$PROJECT_ROOT/secrets/initial_admin_password \
  SMOKE_TEST_PASSWORD_FILE=$PROJECT_ROOT/secrets/smoke_test_password \
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
    "$PROJECT_DIR/deploy/scripts/deploy.sh"
}

line_number() {
  pattern=$1
  grep -n "$pattern" "$FAKE_DOCKER_LOG" | sed -n '1s/:.*//p'
}

[ "$(uname -s)" = "Linux" ] || fail "Linux test must run on Linux"
assert_ephemeral_runner

TMP_DIR=$(mktemp -d)
FAKE_DOCKER_DIR=$TMP_DIR/fake-bin
FAKE_DOCKER_LOG=$TMP_DIR/docker.log
write_fake_commands "$FAKE_DOCKER_DIR" "$FAKE_DOCKER_LOG"
trap 'cleanup_path "$PROJECT_ROOT"; cleanup_path "$DOCKER_PARENT"; cleanup_path "$TMP_DIR"' EXIT HUP INT TERM

prepare_project_root
write_install_passwords
run_deploy >/dev/null

migrate_line=$(line_number 'alembic -c /opt/app/server/alembic.ini upgrade head')
bootstrap_line=$(line_number 'python -m makerseed_app.cli bootstrap-admin')
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
rm -f "$PROJECT_ROOT"/.fake-db-created "$PROJECT_ROOT"/.fake-app-started "$PROJECT_ROOT"/.fake-migrated "$PROJECT_ROOT"/.fake-bootstrapped

write_install_passwords
: >"$FAKE_DOCKER_LOG"
run_deploy >/dev/null
if grep -q 'bootstrap-admin' "$FAKE_DOCKER_LOG"; then
  fail "upgrade path reran bootstrap-admin"
fi
if grep -q 'DoNotLeak' "$FAKE_DOCKER_LOG"; then
  fail "password appeared in upgrade fake Docker/curl argv log"
fi

echo "PASS: first-install admin bootstrap and smoke credential behavior verified."
