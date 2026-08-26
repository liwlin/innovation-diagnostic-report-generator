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
      app) : >"$FAKE_STATE_DIR/app-started" ;;
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
      *"alembic -c /opt/app/server/alembic.ini upgrade head"*) : >"$FAKE_STATE_DIR/migrated" ;;
      *"python -m makerseed_app.cli bootstrap-admin"*) : >"$FAKE_STATE_DIR/bootstrapped" ;;
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
if [ "${FAKE_FAIL_DEPLOY_SHA256:-}" = "final-stage" ] && [ "$#" -eq 1 ] && [ "$1" = "current.env" ]; then
  exit 96
fi
exec /usr/bin/sha256sum "$@"
EOF
  cat >"$fake_dir/mv" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "mv $*" >> "$FAKE_DOCKER_LOG"
if [ "${FAKE_FAIL_DEPLOY_MV:-}" = "final-hash" ] && [ "$#" -eq 2 ] && [ "$1" = "current.env.sha256" ] && [ "$2" = "/volume1/docker/makerseed-diagnostic/deployment-state/current.env.sha256" ]; then
  exit 97
fi
if [ "${FAKE_FAIL_DEPLOY_MV:-}" = "final-hash" ] && [ "$#" -eq 2 ] && [ "${1##*/}" = "current.env.sha256.new" ] && [ "${2##*/}" = "current.env.sha256" ]; then
  exit 97
fi
if [ "${FAKE_FAIL_DEPLOY_MV:-}" = "final-hash" ] && [ "$#" -eq 2 ] && [ "${1##*/}" = "current.env.sha256" ] && [ "${2##*/}" = "current.env.sha256" ]; then
  exit 97
fi
exec /usr/bin/mv "$@"
EOF
  chmod 755 "$fake_dir/docker" "$fake_dir/docker-compose" "$fake_dir/curl" "$fake_dir/sha256sum" "$fake_dir/mv"
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
  printf '%s\n' "$RUN_MARKER" >"$PROJECT_ROOT/$PROJECT_MARKER"
  printf '%s\n' "$RUN_MARKER" >"$DOCKER_PARENT/$DOCKER_MARKER"
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
  if grep -q 'alembic -c /opt/app/server/alembic.ini upgrade head' "$FAKE_DOCKER_LOG"; then
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

assert_upgrade_rejects_bad_current_hash() {
  reason=$1
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

write_install_passwords
before_state_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env" | awk '{print $1}')
before_checksum_hash=$(sha256sum "$PROJECT_ROOT/deployment-state/current.env.sha256" | awk '{print $1}')
before_smoke_hash=$(sha256sum "$PROJECT_ROOT/secrets/smoke_test_password" | awk '{print $1}')
: >"$FAKE_DOCKER_LOG"
if RUN_FAIL_DEPLOY_SHA256=final-stage run_deploy >/dev/null 2>&1; then
  fail "final checksum staging failure reported deploy success"
fi
assert_current_state_unchanged "$before_state_hash" "$before_checksum_hash"
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
if grep -q 'alembic -c /opt/app/server/alembic.ini upgrade head' "$FAKE_DOCKER_LOG"; then
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
