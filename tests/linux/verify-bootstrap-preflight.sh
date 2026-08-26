#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)
VOLUME_ROOT=/volume1
DOCKER_PARENT=$VOLUME_ROOT/docker
PROJECT_ROOT=$DOCKER_PARENT/makerseed-diagnostic
BOOTSTRAP_ROOT=$VOLUME_ROOT/.makerseed-diagnostic-bootstrap
RELEASE_ID=v0.1.0-test
PREFLIGHT_NONCE=nonce1234
BOOTSTRAP_STAGE=$BOOTSTRAP_ROOT/$RELEASE_ID-$PREFLIGHT_NONCE
APP_IMAGE=ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:1111111111111111111111111111111111111111111111111111111111111111
MARKER_FILE=.makerseed-bootstrap-preflight-test
RUN_MARKER=task7-bootstrap-$$

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
  resolved=$(realpath "$target" 2>/dev/null || printf '%s' "$target")
  case "$target" in
    "$DOCKER_PARENT"|"$DOCKER_PARENT"/*|"$PROJECT_ROOT"|"$PROJECT_ROOT"/*|"$BOOTSTRAP_ROOT"|"$BOOTSTRAP_ROOT"/*) ;;
    "$TMP_DIR"|"$TMP_DIR"/*) ;;
    *) fail "unsafe cleanup target: $target" ;;
  esac
  case "$resolved" in
    "$DOCKER_PARENT"|"$DOCKER_PARENT"/*|"$PROJECT_ROOT"|"$PROJECT_ROOT"/*|"$BOOTSTRAP_ROOT"|"$BOOTSTRAP_ROOT"/*|"$TMP_DIR"|"$TMP_DIR"/*) ;;
    *) fail "unsafe resolved cleanup target: $resolved" ;;
  esac
}

require_marker_owned() {
  target=$1
  [ -e "$target" ] || [ -L "$target" ] || return 0
  marker_path=$(marker_path_for_root "$target")
  [ -f "$marker_path" ] || fail "refusing cleanup of unmarked fixed root: $target"
  marker=$(cat "$marker_path")
  [ "$marker" = "$RUN_MARKER" ] || fail "refusing cleanup of marker not owned by this run: $target"
}

cleanup_path() {
  target=$1
  require_cleanup_target "$target"
  case "$target" in
    "$DOCKER_PARENT"|"$PROJECT_ROOT"|"$BOOTSTRAP_ROOT") require_marker_owned "$target" ;;
  esac
  if [ -e "$target" ] || [ -L "$target" ]; then
    rm -R "$target"
  fi
}

assert_ephemeral_runner() {
  [ "${MKSEED_EPHEMERAL_VOLUME1_TEST:-}" = "1" ] || fail "MKSEED_EPHEMERAL_VOLUME1_TEST=1 is required"
  for root in "$DOCKER_PARENT" "$BOOTSTRAP_ROOT"; do
    if [ -e "$root" ] || [ -L "$root" ]; then
      fail "fixed root pre-exists before test-owned marker setup: $root"
    fi
  done
}

marker_path_for_root() {
  root=$1
  case "$root" in
    "$DOCKER_PARENT") printf '%s\n' "$TMP_DIR/docker-parent.marker" ;;
    "$PROJECT_ROOT") printf '%s\n' "$TMP_DIR/project-root.marker" ;;
    "$BOOTSTRAP_ROOT") printf '%s\n' "$TMP_DIR/bootstrap-root.marker" ;;
    *) fail "no marker path for root: $root" ;;
  esac
}

mark_owned_root() {
  root=$1
  printf '%s\n' "$RUN_MARKER" >"$(marker_path_for_root "$root")"
}

prepare_volume_root() {
  if [ ! -d "$VOLUME_ROOT" ]; then
    sudo mkdir -p "$VOLUME_ROOT"
  fi
  [ -d "$VOLUME_ROOT" ] || fail "$VOLUME_ROOT is not available"
  [ ! -L "$VOLUME_ROOT" ] || fail "$VOLUME_ROOT is a symlink"
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
  "image inspect")
    case "${FAKE_IMAGE_INSPECT:-pass}" in pass) exit 0 ;; *) exit 1 ;; esac
    ;;
  "manifest inspect")
    case "${FAKE_MANIFEST_INSPECT:-fail}" in pass) echo '{"schemaVersion":2}'; exit 0 ;; *) exit 1 ;; esac
    ;;
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
  cleanup_path "$DOCKER_PARENT"
  cleanup_path "$BOOTSTRAP_ROOT"
  mkdir -p "$BOOTSTRAP_ROOT" "$BOOTSTRAP_STAGE"
  mark_owned_root "$BOOTSTRAP_ROOT"
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
  FAKE_IMAGE_INSPECT=${FAKE_IMAGE_INSPECT:-pass} \
  FAKE_MANIFEST_INSPECT=${FAKE_MANIFEST_INSPECT:-fail} \
  PATH="$FAKE_DOCKER_DIR:$PATH" \
  FAKE_DOCKER_LOG=$FAKE_DOCKER_LOG \
    "$PROJECT_DIR/deploy/scripts/preflight.sh"
}

run_preflight_bootstrap_with_tar() {
  proof=$1
  tar_path=$2
  PREFLIGHT_MODE=bootstrap \
  PROJECT_ROOT=$PROJECT_ROOT \
  RELEASE_ID=$RELEASE_ID \
  PREFLIGHT_NONCE=$PREFLIGHT_NONCE \
  BOOTSTRAP_STAGE=$BOOTSTRAP_STAGE \
  IMAGE_TAR=$tar_path \
  IMAGE_TAR_PROOF=$proof \
  APP_IMAGE=$APP_IMAGE \
  REPORT_ROOT_PHASE=isolated \
  FAKE_IMAGE_INSPECT=fail \
  FAKE_MANIFEST_INSPECT=fail \
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
  FAKE_IMAGE_INSPECT=${FAKE_IMAGE_INSPECT:-pass} \
  FAKE_MANIFEST_INSPECT=${FAKE_MANIFEST_INSPECT:-fail} \
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
  FAKE_IMAGE_INSPECT=${FAKE_IMAGE_INSPECT:-pass} \
  FAKE_MANIFEST_INSPECT=${FAKE_MANIFEST_INSPECT:-fail} \
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

write_tar_proof() {
  proof=$1
  tar_path=$2
  image_value=$3
  tar_hash=$(sha256sum "$tar_path" | awk '{print $1}')
  canonical_tar=$(realpath "$tar_path")
  cat >"$proof" <<EOF
proof_version=1
app_image=$image_value
image_tar_path=$canonical_tar
image_tar_sha256=$tar_hash
EOF
}

[ "$(uname -s)" = "Linux" ] || fail "Linux test must run on Linux"
assert_ephemeral_runner
command -v sudo >/dev/null 2>&1 || fail "sudo is required to prepare exact /volume1/docker roots"
prepare_volume_root

TMP_DIR=$(mktemp -d)
FAKE_DOCKER_DIR=$TMP_DIR/fake-bin
FAKE_DOCKER_LOG=$TMP_DIR/docker.log
write_fake_docker "$FAKE_DOCKER_DIR" "$FAKE_DOCKER_LOG"
trap 'cleanup_path "$PROJECT_ROOT"; cleanup_path "$DOCKER_PARENT"; cleanup_path "$BOOTSTRAP_ROOT"; cleanup_path "$TMP_DIR"' EXIT HUP INT TERM

reset_stage
before_project_state=absent
[ ! -e "$DOCKER_PARENT" ] && [ ! -L "$DOCKER_PARENT" ] || fail "docker parent should be absent before bootstrap"
[ ! -e "$PROJECT_ROOT" ] && [ ! -L "$PROJECT_ROOT" ] || fail "project root should be absent before bootstrap"
bootstrap_json=$(run_preflight_bootstrap)
assert_contains "$bootstrap_json" '"mode":"bootstrap"'
assert_contains "$bootstrap_json" '"project_root_before_state":"absent"'
assert_contains "$bootstrap_json" '"binding_hash":"'
[ ! -e "$PROJECT_ROOT" ] && [ ! -L "$PROJECT_ROOT" ] || fail "bootstrap preflight created project root"
[ ! -e "$DOCKER_PARENT" ] && [ ! -L "$DOCKER_PARENT" ] || fail "bootstrap preflight created docker parent"
if grep -E 'docker (pull|load)|docker-compose up' "$FAKE_DOCKER_LOG" >/dev/null; then
  fail "bootstrap preflight invoked image/container mutation"
fi
case "$before_project_state" in absent) : ;; *) fail "unexpected before-state sentinel" ;; esac

binding_hash=$(printf '%s\n' "$bootstrap_json" | sed -n 's/.*"binding_hash":"\([^"]*\)".*/\1/p')
[ -n "$binding_hash" ] || fail "missing binding hash"

cleanup_path "$BOOTSTRAP_ROOT"
mkdir -p "$BOOTSTRAP_STAGE"
mkdir -p "$BOOTSTRAP_ROOT"
mark_owned_root "$BOOTSTRAP_ROOT"
ln -s /tmp "$BOOTSTRAP_STAGE/release"
chmod 700 "$BOOTSTRAP_STAGE"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "stage symlink was accepted"; fi

reset_stage
printf 'bad\n' >>"$BOOTSTRAP_STAGE/release-tree.sha256"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "manifest traversal/malformed line was accepted"; fi

reset_stage
printf 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  ../escape\n' >"$BOOTSTRAP_STAGE/release-tree.sha256"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "manifest traversal path was accepted"; fi

reset_stage
printf 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  deploy\\compose.yaml\n' >"$BOOTSTRAP_STAGE/release-tree.sha256"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "manifest backslash path was accepted"; fi

reset_stage
printf 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  -leading\n' >"$BOOTSTRAP_STAGE/release-tree.sha256"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "manifest leading-dash path was accepted"; fi

reset_stage
printf 'dash component\n' >"$BOOTSTRAP_STAGE/release/deploy/-name"
(
  cd "$BOOTSTRAP_STAGE/release"
  find deploy -type f | LC_ALL=C sort | while IFS= read -r file; do
    sha256sum "$file"
  done > "$BOOTSTRAP_STAGE/release-tree.sha256"
)
if run_preflight_bootstrap >/dev/null 2>&1; then fail "manifest dash path component was accepted"; fi

reset_stage
printf 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  deploy/control\001path\n' >"$BOOTSTRAP_STAGE/release-tree.sha256"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "manifest control-character path was accepted"; fi

reset_stage
first_line=$(sed -n '1p' "$BOOTSTRAP_STAGE/release-tree.sha256")
second_line=$(sed -n '2p' "$BOOTSTRAP_STAGE/release-tree.sha256")
if [ -n "$second_line" ]; then
  { printf '%s\n' "$second_line"; printf '%s\n' "$first_line"; sed -n '3,$p' "$BOOTSTRAP_STAGE/release-tree.sha256"; } >"$BOOTSTRAP_STAGE/release-tree.sha256.tmp"
  mv "$BOOTSTRAP_STAGE/release-tree.sha256.tmp" "$BOOTSTRAP_STAGE/release-tree.sha256"
  if run_preflight_bootstrap >/dev/null 2>&1; then fail "unsorted manifest was accepted"; fi
fi

reset_stage
printf 'extra\n' >"$BOOTSTRAP_STAGE/release/deploy/extra.txt"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "extra staged file was accepted"; fi

reset_stage
awk 'NR == 1 { print "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  " substr($0, 67); next } { print }' "$BOOTSTRAP_STAGE/release-tree.sha256" >"$BOOTSTRAP_STAGE/release-tree.sha256.tmp"
mv "$BOOTSTRAP_STAGE/release-tree.sha256.tmp" "$BOOTSTRAP_STAGE/release-tree.sha256"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "hash mismatch was accepted"; fi

reset_stage
mkdir -p "$PROJECT_ROOT"
mark_owned_root "$DOCKER_PARENT"
mark_owned_root "$PROJECT_ROOT"
if run_preflight_bootstrap >/dev/null 2>&1; then fail "pre-existing project root was accepted"; fi
cleanup_path "$DOCKER_PARENT"

reset_stage
bad_app_image=ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
if APP_IMAGE=$bad_app_image run_preflight_bootstrap >/dev/null 2>&1; then fail "bad uppercase digest was accepted"; fi

reset_stage
FAKE_IMAGE_INSPECT=fail FAKE_MANIFEST_INSPECT=pass run_preflight_bootstrap >/dev/null

reset_stage
if FAKE_IMAGE_INSPECT=fail FAKE_MANIFEST_INSPECT=fail run_preflight_bootstrap >/dev/null 2>&1; then fail "missing local image and registry proof was accepted"; fi

reset_stage
tar_path=$BOOTSTRAP_STAGE/app-image.tar
proof_path=$BOOTSTRAP_STAGE/app-image.proof
printf 'offline-image\n' >"$tar_path"
write_tar_proof "$proof_path" "$tar_path" "$APP_IMAGE"
tar_json=$(run_preflight_bootstrap_with_tar "$proof_path" "$tar_path")
assert_contains "$tar_json" '"image_source":"verified-tar"'
assert_contains "$tar_json" '"image_tar_hash":"'
tar_binding=$(printf '%s\n' "$tar_json" | sed -n 's/.*"binding_hash":"\([^"]*\)".*/\1/p')

printf 'changed-image\n' >"$tar_path"
if run_preflight_bootstrap_with_tar "$proof_path" "$tar_path" >/dev/null 2>&1; then fail "tar hash mismatch was accepted"; fi

reset_stage
tar_path=$BOOTSTRAP_STAGE/app-image.tar
proof_path=$BOOTSTRAP_STAGE/app-image.proof
printf 'offline-image\n' >"$tar_path"
write_tar_proof "$proof_path" "$tar_path" "ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:2222222222222222222222222222222222222222222222222222222222222222"
if run_preflight_bootstrap_with_tar "$proof_path" "$tar_path" >/dev/null 2>&1; then fail "tar proof for swapped APP_IMAGE was accepted"; fi

reset_stage
if IMAGE_TAR=$tar_path IMAGE_TAR_PROOF=$proof_path run_install_layout "$tar_binding" >/dev/null 2>&1; then fail "stale tar binding was accepted"; fi

reset_stage
if run_install_layout stale >/dev/null 2>&1; then fail "stale binding was accepted"; fi
run_install_layout "$binding_hash" >/dev/null
mark_owned_root "$PROJECT_ROOT"
mark_owned_root "$DOCKER_PARENT"
[ -d "$PROJECT_ROOT/releases/$RELEASE_ID/deploy" ] || fail "immutable release was not published"
[ -f "$PROJECT_ROOT/releases/$RELEASE_ID/deploy/compose.yaml" ] || fail "release contents missing"
[ -f "$PROJECT_ROOT/releases/$RELEASE_ID/release-tree.sha256" ] || fail "installed release manifest missing"
if run_install_layout "$binding_hash" >/dev/null 2>&1; then fail "release overwrite was accepted"; fi

if run_preflight_runtime >/dev/null 2>&1; then fail "runtime preflight accepted missing secrets"; fi
prepare_runtime_files
chmod 644 "$PROJECT_ROOT/secrets/session_secret"
if run_preflight_runtime >/dev/null 2>&1; then fail "runtime preflight accepted mis-moded secret"; fi
chmod 600 "$PROJECT_ROOT/secrets/session_secret"
runtime_json=$(run_preflight_runtime)
assert_contains "$runtime_json" '"mode":"runtime"'
assert_contains "$runtime_json" '"binding_hash":"'
printf 'drift\n' >"$PROJECT_ROOT/releases/$RELEASE_ID/deploy/drift.txt"
if run_preflight_runtime >/dev/null 2>&1; then fail "runtime preflight accepted release tree drift"; fi
rm "$PROJECT_ROOT/releases/$RELEASE_ID/deploy/drift.txt"

if FAKE_IMAGE_INSPECT=fail FAKE_MANIFEST_INSPECT=pass run_preflight_runtime >/dev/null 2>&1; then fail "runtime preflight accepted registry-only image evidence"; fi

if grep -E 'docker (pull|load)|docker-compose up' "$FAKE_DOCKER_LOG" >/dev/null; then
  fail "preflight invoked forbidden mutation"
fi

echo "PASS: bootstrap/runtime preflight and install layout behavior verified."
