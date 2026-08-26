#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_project_root_identity
: "${PREFLIGHT_MODE:?PREFLIGHT_MODE is required}"
: "${APP_IMAGE:?APP_IMAGE is required}"
: "${PREFLIGHT_NONCE:?PREFLIGHT_NONCE is required}"
: "${REPORT_ROOT_PHASE:=isolated}"

MIN_DOCKER_VERSION=${MIN_DOCKER_VERSION:-24.0.0}
MIN_COMPOSE_VERSION=${MIN_COMPOSE_VERSION:-2.20.0}
ISOLATED_REPORT_ROOT="$PROJECT_ROOT/reports-staging"
PROMOTED_REPORT_ROOT=/volume1/科创诊断报告
APP_REPOSITORY=ghcr.io/liwlin/innovation-diagnostic-report-generator

case "$REPORT_ROOT_PHASE" in
  isolated) APPROVED_REPORT_ROOT=$ISOLATED_REPORT_ROOT ;;
  promoted) APPROVED_REPORT_ROOT=$PROMOTED_REPORT_ROOT ;;
  *) echo "ABORT: REPORT_ROOT_PHASE must be isolated or promoted" >&2; exit 50 ;;
esac

case "$PREFLIGHT_NONCE" in
  [A-Za-z0-9._-][A-Za-z0-9._-][A-Za-z0-9._-][A-Za-z0-9._-]*) ;;
  *) echo "ABORT: PREFLIGHT_NONCE must be at least four safe characters" >&2; exit 50 ;;
esac

validate_app_image() {
  case "$APP_IMAGE" in
    "$APP_REPOSITORY"@sha256:*) ;;
    *) echo "ABORT: APP_IMAGE must include an immutable SHA-256 digest for $APP_REPOSITORY" >&2; exit 55 ;;
  esac
  image_digest=${APP_IMAGE#"$APP_REPOSITORY"@sha256:}
  if ! printf '%s\n' "$image_digest" | grep -E '^[0-9a-f]{64}$' >/dev/null 2>&1; then
    echo "ABORT: APP_IMAGE digest must be exactly 64 lowercase hex characters" >&2
    exit 55
  fi
}
validate_app_image

version_ge() {
  actual=$1
  minimum=$2
  awk -v actual="$actual" -v minimum="$minimum" '
    BEGIN {
      split(actual, a, ".")
      split(minimum, m, ".")
      for (i = 1; i <= 3; i++) {
        av = a[i] + 0
        want = m[i] + 0
        if (av > want) exit 0
        if (av < want) exit 1
      }
      exit 0
    }'
}

common_host_checks() {
  if [ "$(uname -m)" != "x86_64" ]; then
    echo "ABORT: NAS architecture must be x86_64" >&2
    exit 50
  fi
  command -v docker >/dev/null 2>&1 || { echo "ABORT: docker is missing" >&2; exit 50; }
  command -v docker-compose >/dev/null 2>&1 || { echo "ABORT: docker-compose is missing" >&2; exit 50; }
  docker_version=$(docker version --format '{{.Server.Version}}')
  compose_version=$(docker-compose version --short 2>/dev/null || docker-compose version | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p')
  compose_version=${compose_version#v}
  if ! version_ge "$docker_version" "$MIN_DOCKER_VERSION"; then
    echo "ABORT: Docker Engine must be at least $MIN_DOCKER_VERSION" >&2
    exit 50
  fi
  if ! version_ge "$compose_version" "$MIN_COMPOSE_VERSION"; then
    echo "ABORT: Docker Compose must be at least $MIN_COMPOSE_VERSION" >&2
    exit 50
  fi
  case "$PREFLIGHT_MODE" in
    bootstrap) df_root=/volume1 ;;
    runtime) df_root=/volume1/docker ;;
    *) df_root=/volume1 ;;
  esac
  if [ "$PREFLIGHT_MODE" = "bootstrap" ]; then
    [ -d /volume1 ] && [ ! -L /volume1 ] || { echo "ABORT: verified volume /volume1 is missing or unsafe" >&2; exit 51; }
  else
    [ -d /volume1/docker ] && [ ! -L /volume1/docker ] || { echo "ABORT: verified Docker parent /volume1/docker is missing or unsafe" >&2; exit 51; }
  fi
  free_kb=$(df -Pk "$df_root" | awk 'NR==2 {print $4}')
  available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
  if [ -z "$free_kb" ] || [ "$free_kb" -lt 5242880 ]; then
    echo "ABORT: less than 5 GiB is available on the target volume" >&2
    exit 53
  fi
  if [ -z "$available_kb" ] || [ "$available_kb" -lt 2097152 ]; then
    echo "ABORT: less than 2 GiB of memory is available" >&2
    exit 53
  fi
}

verify_container_owner() {
  container_id=$1
  purpose=$2
  owner_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container_id" 2>/dev/null || true)
  owner_dir=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_id" 2>/dev/null || true)
  if [ "$owner_project" != "makerseed-diagnostic" ] || [ "$owner_dir" != "$PROJECT_ROOT" ]; then
    echo "ABORT: $purpose is owned by another Compose project/root" >&2
    exit 54
  fi
}

collision_checks() {
  collision_result=clear
  port_owners=$(docker ps --filter publish=18081 --format '{{.ID}}')
  for container_id in $port_owners; do
    verify_container_owner "$container_id" "port 18081"
  done
  for expected_container_name in makerseed-diagnostic-app-1 makerseed-diagnostic-db-1; do
    exact_container_ids=$(docker ps -a --filter "name=^/${expected_container_name}$" --format '{{.ID}}')
    for container_id in $exact_container_ids; do
      verify_container_owner "$container_id" "container $expected_container_name"
    done
  done
  foreign_project_containers=$(docker ps -a --filter label=com.docker.compose.project=makerseed-diagnostic --format '{{.ID}}')
  for container_id in $foreign_project_containers; do
    verify_container_owner "$container_id" "Compose project makerseed-diagnostic"
  done
}

proof_value() {
  key=$1
  file=$2
  count=$(grep -c "^$key=" "$file" || true)
  [ "$count" -eq 1 ] || { echo "ABORT: image tar proof must contain exactly one $key field" >&2; exit 56; }
  sed -n "s/^$key=//p" "$file"
}

verify_bootstrap_app_image_evidence() {
  image_source=local-digest
  image_tar_path=''
  image_tar_hash=''
  image_tar_proof_hash=''
  if docker image inspect "$APP_IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${IMAGE_TAR:-}" ]; then
    : "${IMAGE_TAR_PROOF:?IMAGE_TAR_PROOF is required when IMAGE_TAR is used}"
    [ -f "$IMAGE_TAR" ] && [ ! -L "$IMAGE_TAR" ] || { echo "ABORT: IMAGE_TAR is missing or unsafe" >&2; exit 56; }
    [ -f "$IMAGE_TAR_PROOF" ] && [ ! -L "$IMAGE_TAR_PROOF" ] || { echo "ABORT: IMAGE_TAR_PROOF is missing or unsafe" >&2; exit 56; }
    image_tar_path=$(safe_realpath "$IMAGE_TAR")
    image_tar_proof_path=$(safe_realpath "$IMAGE_TAR_PROOF")
    case "$image_tar_path" in "$BOOTSTRAP_STAGE"/*) ;; *) echo "ABORT: IMAGE_TAR must be inside the bootstrap stage" >&2; exit 56 ;; esac
    case "$image_tar_proof_path" in "$BOOTSTRAP_STAGE"/*) ;; *) echo "ABORT: IMAGE_TAR_PROOF must be inside the bootstrap stage" >&2; exit 56 ;; esac
    proof_version=$(proof_value proof_version "$IMAGE_TAR_PROOF")
    proof_app_image=$(proof_value app_image "$IMAGE_TAR_PROOF")
    proof_tar_path=$(proof_value image_tar_path "$IMAGE_TAR_PROOF")
    proof_tar_hash=$(proof_value image_tar_sha256 "$IMAGE_TAR_PROOF")
    [ "$proof_version" = "1" ] || { echo "ABORT: image tar proof version is unsupported" >&2; exit 56; }
    [ "$proof_app_image" = "$APP_IMAGE" ] || { echo "ABORT: image tar proof does not match APP_IMAGE" >&2; exit 56; }
    [ "$proof_tar_path" = "$image_tar_path" ] || { echo "ABORT: image tar proof does not match canonical tar path" >&2; exit 56; }
    image_tar_hash=$(sha256sum "$IMAGE_TAR" | awk '{print $1}')
    if ! printf '%s\n' "$proof_tar_hash" | grep -E '^[0-9a-f]{64}$' >/dev/null 2>&1; then
      echo "ABORT: image tar proof hash must be lowercase SHA-256" >&2
      exit 56
    fi
    [ "$proof_tar_hash" = "$image_tar_hash" ] || { echo "ABORT: image tar proof hash mismatch" >&2; exit 56; }
    image_tar_proof_hash=$(sha256sum "$IMAGE_TAR_PROOF" | awk '{print $1}')
    image_source=verified-tar
    return 0
  fi
  if docker manifest inspect "$APP_IMAGE" >/dev/null 2>&1; then
    image_source=ghcr-manifest
    return 0
  fi
  echo "ABORT: app image digest is not locally present and no read-only GHCR/tar proof is available" >&2
  exit 56
}

verify_runtime_app_image_evidence() {
  image_source=local-digest
  image_tar_path=''
  image_tar_hash=''
  image_tar_proof_hash=''
  if docker image inspect "$APP_IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  echo "ABORT: runtime preflight requires APP_IMAGE to be locally inspectable at the exact digest" >&2
  exit 56
}

project_root_before_state() {
  if [ -L "$PROJECT_ROOT" ]; then
    echo "symlink"
  elif [ -e "$PROJECT_ROOT" ]; then
    echo "exists"
  else
    echo "absent"
  fi
}

emit_verdict() {
  mode=$1
  release_id=$2
  release_path=$3
  manifest_hash=$4
  tree_hash=$5
  before_state=$6
  report_root=$7
  binding_hash=$(printf '%s\n' \
    "nonce=$PREFLIGHT_NONCE" \
    "mode=$mode" \
    "release_id=$release_id" \
    "release_path=$release_path" \
    "manifest_hash=$manifest_hash" \
    "tree_hash=$tree_hash" \
    "app_version=${APP_VERSION:-}" \
    "commit=${COMMIT_SHA:-}" \
    "app_image=$APP_IMAGE" \
    "image_source=$image_source" \
    "image_tar_path=$image_tar_path" \
    "image_tar_hash=$image_tar_hash" \
    "image_tar_proof_hash=$image_tar_proof_hash" \
    "report_root_phase=$REPORT_ROOT_PHASE" \
    "report_root=$report_root" \
    "project_root=$PROJECT_ROOT" \
    "project_root_before_state=$before_state" \
    "collision_result=$collision_result" | sha256sum | awk '{print $1}')
  printf '{"result":"pass","mode":"%s","nonce":"%s","binding_hash":"%s","architecture":"x86_64","project_root":"%s","project_root_before_state":"%s","release_id":"%s","release_path":"%s","release_manifest_hash":"%s","release_tree_hash":"%s","image_source":"%s","image_tar_path":"%s","image_tar_hash":"%s","image_tar_proof_hash":"%s","app_image":"%s","compose_version":"%s","report_root_phase":"%s","report_root":"%s"}\n' \
    "$(json_escape "$mode")" "$(json_escape "$PREFLIGHT_NONCE")" "$binding_hash" "$(json_escape "$PROJECT_ROOT")" "$(json_escape "$before_state")" \
    "$(json_escape "$release_id")" "$(json_escape "$release_path")" "$manifest_hash" "$tree_hash" "$(json_escape "$image_source")" \
    "$(json_escape "$image_tar_path")" "$image_tar_hash" "$image_tar_proof_hash" "$(json_escape "$APP_IMAGE")" "$(json_escape "$compose_version")" "$(json_escape "$REPORT_ROOT_PHASE")" "$(json_escape "$report_root")"
}

bootstrap_preflight() {
  : "${RELEASE_ID:?RELEASE_ID is required}"
  case "$RELEASE_ID" in
    ''|*[!A-Za-z0-9._-]*) echo "ABORT: RELEASE_ID must contain only safe characters" >&2; exit 52 ;;
  esac
  before_state=$(project_root_before_state)
  case "$before_state" in
    absent) ;;
    *) echo "ABORT: PROJECT_ROOT must not exist for bootstrap" >&2; exit 51 ;;
  esac
  BOOTSTRAP_STAGE=${BOOTSTRAP_STAGE:-/volume1/.makerseed-diagnostic-bootstrap/$RELEASE_ID-$PREFLIGHT_NONCE}
  STAGED_RELEASE_ROOT=${STAGED_RELEASE_ROOT:-$BOOTSTRAP_STAGE/release/deploy}
  RELEASE_TREE_MANIFEST=${RELEASE_TREE_MANIFEST:-$BOOTSTRAP_STAGE/release-tree.sha256}
  expected_stage=/volume1/.makerseed-diagnostic-bootstrap/$RELEASE_ID-$PREFLIGHT_NONCE
  [ "$BOOTSTRAP_STAGE" = "$expected_stage" ] || { echo "ABORT: BOOTSTRAP_STAGE must be nonce-bound under /volume1/.makerseed-diagnostic-bootstrap" >&2; exit 52; }
  [ -d "$BOOTSTRAP_STAGE" ] && [ ! -L "$BOOTSTRAP_STAGE" ] || { echo "ABORT: bootstrap stage is missing or unsafe" >&2; exit 52; }
  [ "$(safe_realpath "$BOOTSTRAP_STAGE")" = "$expected_stage" ] || { echo "ABORT: bootstrap stage resolves outside the approved root" >&2; exit 52; }
  [ "$(file_mode "$BOOTSTRAP_STAGE")" = "700" ] || { echo "ABORT: bootstrap stage must be mode 0700" >&2; exit 52; }
  [ "$(file_uid "$BOOTSTRAP_STAGE")" = "0" ] || { echo "ABORT: bootstrap stage must be owned by root" >&2; exit 52; }
  [ "$STAGED_RELEASE_ROOT" = "$BOOTSTRAP_STAGE/release/deploy" ] || { echo "ABORT: STAGED_RELEASE_ROOT must be \$BOOTSTRAP_STAGE/release/deploy" >&2; exit 52; }
  [ "$RELEASE_TREE_MANIFEST" = "$BOOTSTRAP_STAGE/release-tree.sha256" ] || { echo "ABORT: RELEASE_TREE_MANIFEST must be \$BOOTSTRAP_STAGE/release-tree.sha256" >&2; exit 52; }
  verify_release_tree "$BOOTSTRAP_STAGE/release" "$RELEASE_TREE_MANIFEST"
  [ -d "$STAGED_RELEASE_ROOT" ] || { echo "ABORT: staged deploy root is missing" >&2; exit 52; }
  release_manifest_hash=$(sha256sum "$RELEASE_TREE_MANIFEST" | awk '{print $1}')
  release_tree_hash=$release_manifest_hash
  verify_bootstrap_app_image_evidence
  emit_verdict bootstrap "$RELEASE_ID" "$PROJECT_ROOT/releases/$RELEASE_ID/deploy" "$release_manifest_hash" "$release_tree_hash" "$before_state" "$ISOLATED_REPORT_ROOT"
}

runtime_preflight() {
  require_exact_project_root
  : "${RELEASE_ID:?RELEASE_ID is required}"
  : "${RELEASE_ROOT:?RELEASE_ROOT is required}"
  : "${SECRETS_ROOT:?SECRETS_ROOT is required}"
  : "${REPORT_ROOT:?REPORT_ROOT is required}"
  [ -f "$PROJECT_ROOT/.env" ] && [ ! -L "$PROJECT_ROOT/.env" ] || { echo "ABORT: project .env is missing or unsafe" >&2; exit 58; }
  resolved_release=$(safe_realpath "$RELEASE_ROOT")
  case "$resolved_release" in
    "$PROJECT_ROOT"/releases/*/deploy) ;;
    *) echo "ABORT: RELEASE_ROOT must match $PROJECT_ROOT/releases/*/deploy" >&2; exit 52 ;;
  esac
  [ "$resolved_release" = "$PROJECT_ROOT/releases/$RELEASE_ID/deploy" ] || { echo "ABORT: RELEASE_ROOT must match RELEASE_ID" >&2; exit 52; }
  [ -f "$RELEASE_ROOT/compose.yaml" ] && [ -f "$RELEASE_ROOT/Dockerfile" ] || { echo "ABORT: release files are incomplete" >&2; exit 52; }
  final_release_base="$PROJECT_ROOT/releases/$RELEASE_ID"
  final_release_manifest="$final_release_base/release-tree.sha256"
  verify_release_tree "$final_release_base" "$final_release_manifest"
  resolved_secrets=$(safe_realpath "$SECRETS_ROOT")
  case "$resolved_secrets" in
    "$PROJECT_ROOT"/secrets) ;;
    *) echo "ABORT: SECRETS_ROOT must resolve to the project secrets directory" >&2; exit 58 ;;
  esac
  for secret_name in postgres_owner_password postgres_runtime_password database_url database_owner_url session_secret bootstrap_secret; do
    secret_path="$SECRETS_ROOT/$secret_name"
    require_regular_secret "$secret_path"
    secret_mode=$(stat -c %a "$secret_path")
    case "$secret_mode" in
      400|600) ;;
      *) echo "ABORT: secret $secret_name must be mode 400 or 600" >&2; exit 58 ;;
    esac
  done
  resolved_data=$(canonical_bind_source "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/data/postgres" exact)
  resolved_backups=$(canonical_bind_source "$PROJECT_ROOT/backups" "$PROJECT_ROOT/backups" exact)
  resolved_init=$(canonical_bind_source "$RELEASE_ROOT/postgres-init/10-create-runtime-role.sh" "$RELEASE_ROOT/postgres-init/10-create-runtime-role.sh" exact)
  resolved_report=$(canonical_bind_source "$REPORT_ROOT" "$APPROVED_REPORT_ROOT" exact)
  case "$resolved_report" in
    "$APPROVED_REPORT_ROOT") ;;
    *) echo "ABORT: REPORT_ROOT must resolve exactly to the approved $REPORT_ROOT_PHASE report root" >&2; exit 59 ;;
  esac
  case "$resolved_report" in
    *company*|*Company*|*公司*) echo "ABORT: report mount must not target company shares" >&2; exit 59 ;;
  esac
  for declared_mount in "$PROJECT_ROOT/data/postgres" "$PROJECT_ROOT/backups" "$REPORT_ROOT" "$RELEASE_ROOT/postgres-init/10-create-runtime-role.sh"; do
    case "$declared_mount" in
      "$PROJECT_ROOT"/data/postgres|"$PROJECT_ROOT"/backups|"$REPORT_ROOT"|"$RELEASE_ROOT"/postgres-init/10-create-runtime-role.sh) ;;
      *) echo "ABORT: declared mount is outside approved roots" >&2; exit 59 ;;
    esac
  done
  for resolved_mount in "$resolved_data" "$resolved_backups" "$resolved_report" "$resolved_init"; do
    case "$resolved_mount" in
      "$PROJECT_ROOT"/data/postgres|"$PROJECT_ROOT"/backups|"$ISOLATED_REPORT_ROOT"|"$PROMOTED_REPORT_ROOT"|"$RELEASE_ROOT"/postgres-init/10-create-runtime-role.sh) ;;
      *) echo "ABORT: resolved mount is outside approved roots" >&2; exit 59 ;;
    esac
  done
  for child in "$PROJECT_ROOT"/* "$PROJECT_ROOT"/.[!.]*; do
    [ -e "$child" ] || continue
    name=$(basename "$child")
    case "$name" in
      data|backups|reports-staging|secrets|releases|current|deployment-state|.env|.deploy-lock) ;;
      *) echo "ABORT: unexpected entry exists in project root: $name" >&2; exit 57 ;;
    esac
  done
  release_manifest_hash=$(sha256sum "$final_release_manifest" | awk '{print $1}')
  release_tree_hash=$release_manifest_hash
  verify_runtime_app_image_evidence
  emit_verdict runtime "$RELEASE_ID" "$RELEASE_ROOT" "$release_manifest_hash" "$release_tree_hash" exists "$resolved_report"
}

common_host_checks
collision_checks

case "$PREFLIGHT_MODE" in
  bootstrap) bootstrap_preflight ;;
  runtime) runtime_preflight ;;
  *) echo "ABORT: PREFLIGHT_MODE must be bootstrap or runtime" >&2; exit 50 ;;
esac
