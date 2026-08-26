#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)
DOCKER_PARENT=/volume1/docker
PROJECT_ROOT=$DOCKER_PARENT/makerseed-diagnostic
BOOTSTRAP_ROOT=$DOCKER_PARENT/.makerseed-diagnostic-bootstrap
RELEASE_ID=v0.1.0-test
PREFLIGHT_NONCE=nonce1234
BOOTSTRAP_STAGE=$BOOTSTRAP_ROOT/$RELEASE_ID-$PREFLIGHT_NONCE
APP_IMAGE=ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:1111111111111111111111111111111111111111111111111111111111111111

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  haystack=$1
  needle=$2
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain $needle; got $haystack" ;;
  esac
}

require_cleanup_target() {
  target=$1
  case "$target" in
    "$PROJECT_ROOT"|"$PROJECT_ROOT"/*|"$BOOTSTRAP_ROOT"|"$BOOTSTRAP_ROOT"/*) ;;
    "$TMP_DIR"|"$TMP_DIR"/*) ;;
    *) fail "unsafe cleanup target: $target" ;;
  esac
}

cleanup_path() {
  target=$1
  require_cleanup_target "$target"
  if [ -e "$target" ] || [ -L "$target" ]; then
    rm -R "$target"
  fi
}

prepare_volume_root() {
  if [ ! -d "$DOCKER_PARENT" ]; then
    sudo mkdir -p "$DOCKER_PARENT"
  fi
  [ -d "$DOCKER_PARENT" ] || fail "$DOCKER_PARENT is not available"
  [ ! -L "$DOCKER_PARENT" ] || fail "$DOCKER_PARENT is a symlink"
}

write_fake_docker() {
  fake_dir=$1
  log_file=$2
  mkdir -p "$fake_dir"
  cat >"$fake_dir/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "docker $*" >> "$FAKE_DOCKER_LOG"
case "$1 $2" in
  "version --format") echo "24.0.7" ;;
  "image inspect") exit 0 ;;
  "manifest inspect") echo '{"schemaVersion":2}' ;;
  "ps --filter")
    shift 2
    exit 0
    ;;
  "ps -a")
    exit 0
    ;;
  "inspect --format")
    echo "makerseed-diagnostic"
    ;;
  "pull "*|"load "*)
    echo "unexpected docker mutation: $*" >&2
    exit 97
    ;;
  *)
    exit 0
    ;;
esac
EOF
  cat >"$fake_dir/docker-compose" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "docker-compose $*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  version)
    case "${2:-}" in
      --short) echo "v2.20.3" ;;
      *) echo "Docker Compose version v2.20.3" ;;
    esac
    ;;
  up|run) echo "unexpected compose mutation: $*" >&2; exit 97 ;;
  *) exit 0 ;;
esac
EOF
  chmod 755 "$fake_dir/docker" "$fake_dir/docker-compose"
  : >"$log_file"
}

copy_release_fixture() {
  release_root=$BOOTSTRAP_STAGE/release
  mkdir -p "$release_root/deploy"
  cp -R "$PROJECT_DIR/deploy/." "$release_root/deploy/"
  chmod +x "$release_root"/deploy/scripts/*.sh
  chmod +x "$release_root"/deploy/postgres-init/10-create-runtime-role.sh
  (
    cd "$release_root"
    find deploy -type f | LC_ALL=C sort | while IFS= read -r file; do
      sha256sum "$file"
    done > "$BOOTSTRAP_STAGE/release-tree.sha256"
  )
  chmod 700 "$BOOTSTRAP_STAGE"
  if [ "$(id -u)" -eq 0 ]; then
    chown 0:0 "$BOOTSTRAP_STAGE"
  else
    sudo chown 0:0 "$BOOTSTRAP_STAGE"
  fi
}

reset_stage() {
  cleanup_path "$PROJECT_ROOT"
  cleanup_path "$BOOTSTRAP_ROOT"
  mkdir -p "$BOOTSTRAP_STAGE"
  copy_release_fixture
}

run_preflight_bootstrap() {
  PREFLIGHT_MODE=bootstrap \
  PROJECT_ROOT=$PROJECT_ROOT \
  RELEASE_ID=$RELEASE_ID \
  PREFLIGHT_NONCE=$PREFLIGHT_NONCE \
  BOOTSTRAP_STAGE=$BOOTSTRAP_STAGE \
  APP_IMAGE=$APP_IMAGE \
  REPORT_ROOT_PHASE=isolated \
  PATH="$FAKE_DOCKER_DIR:$PATH" \
  FAKE_DOCKER_LOG=$FAKE_DOCKER_LOG \
    "$PROJECT_DIR/deploy/scripts/preflight.sh"
}

run_install_layout() {
  binding=$1
  PREFLIGHT_MODE=bootstrap \
  PROJECT_ROOT=$PROJECT_ROOT \
  RELEASE_ID=$RELEASE_ID \
  PREFLIGHT_NONCE=$PREFLIGHT_NONCE \
  PREFLIGHT_BINDING_HASH=$binding \
  BOOTSTRAP_STAGE=$BOOTSTRAP_STAGE \
  APP_IMAGE=$APP_IMAGE \
  REPORT_ROOT_PHASE=isolated \
  PATH="$FAKE_DOCKER_DIR:$PATH" \
  FAKE_DOCKER_LOG=$FAKE_DOCKER_LOG \
    "$PROJECT_DIR/deploy/scripts/install-layout.sh"
}

run_preflight_runtime() {
  PREFLIGHT_MODE=runtime \
  PROJECT_ROOT=$PROJECT_ROOT \
  RELEASE_ID=$RELEASE_ID \
  RELEASE_ROOT=$PROJECT_ROOT/releases/$RELEASE_ID/deploy \
  SECRETS_ROOT=$PROJECT_ROOT/secrets \
  REPORT_ROOT=$PROJECT_ROOT/reports-staging \
  REPORT_ROOT_PHASE=isolated \
  PREFLIGHT_NONCE=$PREFLIGHT_NONCE \
  APP_IMAGE=$APP_IMAGE \
  PATH="$FAKE_DOCKER_DIR:$PATH" \
  FAKE_DOCKER_LOG=$FAKE_DOCKER_LOG \
    "$PROJECT_DIR/deploy/scripts/preflight.sh"
}

prepare_runtime_files() {
  cat >"$PROJECT_ROOT/.env" <<EOF
APP_IMAGE=$APP_IMAGE
APP_VERSION=$RELEASE_ID
PROJECT_ROOT=$PROJECT_ROOT
RELEASE_ROOT=$PROJECT_ROOT/releases/$RELEASE_ID/deploy
SECRETS_ROOT=$PROJECT_ROOT/secrets
REPORT_ROOT=$PROJECT_ROOT/reports-staging
REPORT_ROOT_PHASE=isolated
EOF
  for secret in postgres_owner_password postgres_runtime_password database_url database_owner_url session_secret bootstrap_secret; do
    printf 'dummy-%s\n' "$secret" >"$PROJECT_ROOT/secrets/$secret"
    chmod 600 "$PROJECT_ROOT/secrets/$secret"
  done
}

[ "$(uname -s)" = "Linux" ] || fail "Linux test must run on Linux"
command -v sudo >/dev/null 2>&1 || fail "sudo is required to prepare exact /volume1/docker roots"
prepare_volume_root

TMP_DIR=$(mktemp -d)
FAKE_DOCKER_DIR=$TMP_DIR/fake-bin
FAKE_DOCKER_LOG=$TMP_DIR/docker.log
write_fake_docker "$FAKE_DOCKER_DIR" "$FAKE_DOCKER_LOG"
trap 'cleanup_path "$PROJECT_ROOT"; cleanup_path "$BOOTSTRAP_ROOT"; cleanup_path "$TMP_DIR"' EXIT HUP INT TERM

reset_stage
before_project_state=absent
[ ! -e "$PROJECT_ROOT" ] && [ ! -L "$PROJECT_ROOT" ] || fail "project root should be absent before bootstrap"
bootstrap_json=$(run_preflight_bootstrap)
assert_contains "$bootstrap_json" '"mode":"bootstrap"'
assert_contains "$bootstrap_json" '"project_root_before_state":"absent"'
assert_contains "$bootstrap_json" '"binding_hash":"'
[ ! -e "$PROJECT_ROOT" ] && [ ! -L "$PROJECT_ROOT" ] || fail "bootstrap preflight created project root"
if grep -E 'docker (pull|load)|docker-compose up' "$FAKE_DOCKER_LOG" >/dev/null; then
  fail "bootstrap preflight invoked image/container mutation"
fi
case "$before_project_state" in absent) : ;; *) fail "unexpected before-state sentinel" ;; esac

binding_hash=$(printf '%s\n' "$bootstrap_json" | sed -n 's/.*"binding_hash":"\([^"]*\)".*/\1/p')
[ -n "$binding_hash" ] || fail "missing binding hash"

cleanup_path "$BOOTSTRAP_ROOT"
mkdir -p "$BOOTSTRAP_STAGE"
ln -s /tmp "$BOOTSTRAP_STAGE/release"
chmod 700 "$BOOTSTRAP_STAGE"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "stage symlink was accepted"; fi

reset_stage
printf 'bad\n' >>"$BOOTSTRAP_STAGE/release-tree.sha256"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "manifest traversal/malformed line was accepted"; fi

reset_stage
printf 'extra\n' >"$BOOTSTRAP_STAGE/release/deploy/extra.txt"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "extra staged file was accepted"; fi

reset_stage
awk 'NR == 1 { print "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  " substr($0, 67); next } { print }' "$BOOTSTRAP_STAGE/release-tree.sha256" >"$BOOTSTRAP_STAGE/release-tree.sha256.tmp"
mv "$BOOTSTRAP_STAGE/release-tree.sha256.tmp" "$BOOTSTRAP_STAGE/release-tree.sha256"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "hash mismatch was accepted"; fi

reset_stage
mkdir -p "$PROJECT_ROOT"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "pre-existing project root was accepted"; fi

reset_stage
if run_install_layout stale >/dev/null 2>&1; then fail "stale binding was accepted"; fi
run_install_layout "$binding_hash" >/dev/null
[ -d "$PROJECT_ROOT/releases/$RELEASE_ID/deploy" ] || fail "immutable release was not published"
[ -f "$PROJECT_ROOT/releases/$RELEASE_ID/deploy/compose.yaml" ] || fail "release contents missing"
if run_install_layout "$binding_hash" >/dev/null 2>&1; then fail "release overwrite was accepted"; fi

if run_preflight_runtime >/dev/null 2>&1; then fail "runtime preflight accepted missing secrets"; fi
prepare_runtime_files
chmod 644 "$PROJECT_ROOT/secrets/session_secret"
if run_preflight_runtime >/dev/null 2>&1; then fail "runtime preflight accepted mis-moded secret"; fi
chmod 600 "$PROJECT_ROOT/secrets/session_secret"
runtime_json=$(run_preflight_runtime)
assert_contains "$runtime_json" '"mode":"runtime"'
assert_contains "$runtime_json" '"binding_hash":"'

if grep -E 'docker (pull|load)|docker-compose up' "$FAKE_DOCKER_LOG" >/dev/null; then
  fail "preflight invoked forbidden mutation"
fi

echo "PASS: bootstrap/runtime preflight and install layout behavior verified."
