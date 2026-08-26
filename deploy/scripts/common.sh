#!/bin/sh
set -eu

EXPECTED_PROJECT_ROOT=/volume1/docker/makerseed-diagnostic

require_project_root_identity() {
  : "${PROJECT_ROOT:?PROJECT_ROOT is required}"
  if [ "$PROJECT_ROOT" != "$EXPECTED_PROJECT_ROOT" ]; then
    echo "ABORT: PROJECT_ROOT must be exactly $EXPECTED_PROJECT_ROOT" >&2
    exit 20
  fi
}

safe_realpath() {
  path=$1
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$path"
  else
    echo "ABORT: no supported realpath implementation is available" >&2
    exit 20
  fi
}

file_mode() {
  path=$1
  stat -c %a "$path" 2>/dev/null || {
    echo "ABORT: stat -c %a is required for mode validation" >&2
    exit 20
  }
}

file_uid() {
  path=$1
  stat -c %u "$path" 2>/dev/null || {
    echo "ABORT: stat -c %u is required for owner validation" >&2
    exit 20
  }
}

link_count() {
  path=$1
  stat -c %h "$path" 2>/dev/null || {
    echo "ABORT: stat -c %h is required for link-count validation" >&2
    exit 20
  }
}

require_exact_project_root() {
  require_project_root_identity
  if [ -L "$PROJECT_ROOT" ]; then
    echo "ABORT: project root must not be a symbolic link" >&2
    exit 20
  fi
  if [ ! -d "$PROJECT_ROOT" ]; then
    echo "ABORT: project root is missing" >&2
    exit 20
  fi
  resolved=$(safe_realpath "$PROJECT_ROOT")
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

require_regular_secret_mode() {
  secret_path=$1
  require_regular_secret "$secret_path"
  secret_mode=$(file_mode "$secret_path")
  case "$secret_mode" in
    400|600) ;;
    *) echo "ABORT: required secret file must be mode 0400 or 0600" >&2; exit 21 ;;
  esac
}

canonical_bind_source() {
  bind_path=$1
  expected=$2
  mode=$3
  if [ -L "$bind_path" ]; then
    echo "ABORT: bind source must not be a symbolic link: $bind_path" >&2
    exit 59
  fi
  if [ -e "$bind_path" ]; then
    resolved=$(safe_realpath "$bind_path")
  else
    parent=$bind_path
    suffix=''
    while [ ! -e "$parent" ]; do
      suffix="/$(basename "$parent")$suffix"
      next_parent=$(dirname "$parent")
      if [ "$next_parent" = "$parent" ]; then
        echo "ABORT: bind source has no existing safe parent: $bind_path" >&2
        exit 59
      fi
      parent=$next_parent
    done
    if [ -L "$parent" ]; then
      echo "ABORT: bind source parent must not be a symbolic link: $parent" >&2
      exit 59
    fi
    resolved_parent=$(safe_realpath "$parent")
    resolved="$resolved_parent$suffix"
  fi
  case "$mode" in
    exact)
      [ "$resolved" = "$expected" ] || { echo "ABORT: bind source escapes approved root: $bind_path" >&2; exit 59; }
      ;;
    prefix)
      case "$resolved" in
        "$expected"|"$expected"/*) ;;
        *) echo "ABORT: bind source escapes approved root: $bind_path" >&2; exit 59 ;;
      esac
      ;;
    *) echo "ABORT: invalid bind source validation mode" >&2; exit 59 ;;
  esac
  printf '%s\n' "$resolved"
}

verify_release_tree() {
  release_base=$1
  manifest=$2
  [ -d "$release_base" ] && [ ! -L "$release_base" ] || { echo "ABORT: staged release tree is missing or unsafe" >&2; exit 52; }
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || { echo "ABORT: release tree manifest is missing or unsafe" >&2; exit 52; }
  release_real=$(safe_realpath "$release_base")
  manifest_real=$(safe_realpath "$manifest")
  manifest_rel=''
  case "$manifest_real" in
    "$release_real"/*) manifest_rel=${manifest_real#"$release_real"/} ;;
  esac
  if find "$release_base" -type l -print | grep . >/dev/null 2>&1; then
    echo "ABORT: release tree must not contain symlinks" >&2
    exit 52
  fi
  if find "$release_base" ! -type f ! -type d ! -type l -print | grep . >/dev/null 2>&1; then
    echo "ABORT: release tree contains non-regular entries" >&2
    exit 52
  fi
  if find "$release_base" -type f ! -links 1 -print | grep . >/dev/null 2>&1; then
    echo "ABORT: release tree contains hardlinked files" >&2
    exit 52
  fi
  if ! LC_ALL=C awk '
    index($0, "  ") == 65 {
      hash = substr($0, 1, 64)
      rel = substr($0, 67)
      if (hash !~ /^[0-9a-f]{64}$/ || rel == "" || rel ~ /^\// || rel ~ /(^|\/)-/ || rel ~ /\\/ || rel ~ /(^|\/)\.\.(\/|$)/ || rel ~ /[[:cntrl:]]/) exit 1
      if (rel !~ /^[ -~]+$/) exit 1
      if (last != "" && rel <= last) exit 1
      if (seen[rel]++) exit 1
      last = rel
      next
    }
    { exit 1 }
  ' "$manifest"; then
    echo "ABORT: release tree manifest contains an unsafe path or hash" >&2
    exit 52
  fi
  (
    cd "$release_base"
    find . -type f | sed 's#^\./##' | LC_ALL=C sort
  ) | while IFS= read -r rel; do
    [ "$rel" != "$manifest_rel" ] || continue
    matches=$(awk -v p="$rel" 'index($0, "  ") == 65 { if (substr($0, 67) == p) c++ } END { print c + 0 }' "$manifest")
    [ "$matches" -eq 1 ] || { echo "ABORT: regular staged file is missing from manifest: $rel" >&2; exit 52; }
  done
  file_count=0
  while IFS= read -r line; do
    [ -n "$line" ] || { echo "ABORT: release tree manifest must not contain empty lines" >&2; exit 52; }
    expected_hash=${line%%  *}
    rel=${line#*  }
    target=$release_base/$rel
    [ -f "$target" ] && [ ! -L "$target" ] || { echo "ABORT: manifest path is missing or not a regular file: $rel" >&2; exit 52; }
    [ "$(link_count "$target")" -eq 1 ] || { echo "ABORT: manifest path is hardlinked: $rel" >&2; exit 52; }
    actual_hash=$(sha256sum "$target" | awk '{print $1}')
    [ "$actual_hash" = "$expected_hash" ] || { echo "ABORT: release tree hash mismatch: $rel" >&2; exit 52; }
    file_count=$((file_count + 1))
  done < "$manifest"
  [ "$file_count" -gt 0 ] || { echo "ABORT: release tree manifest is empty" >&2; exit 52; }
  for required in \
    deploy/compose.yaml \
    deploy/Dockerfile \
    deploy/postgres-init/10-create-runtime-role.sh \
    deploy/scripts/common.sh \
    deploy/scripts/preflight.sh \
    deploy/scripts/prepare-manual-rollback-smoke.sh \
    deploy/scripts/install-layout.sh \
    deploy/scripts/migrate.sh \
    deploy/scripts/backup.sh \
    deploy/scripts/restore-verify.sh \
    deploy/scripts/deploy.sh \
    deploy/scripts/rollback.sh \
    deploy/scripts/smoke.sh
  do
    [ -f "$release_base/$required" ] || { echo "ABORT: required release file is missing: $required" >&2; exit 52; }
  done
  for script in "$release_base"/deploy/scripts/*.sh "$release_base"/deploy/postgres-init/10-create-runtime-role.sh; do
    [ -x "$script" ] || { echo "ABORT: required release script is not executable: $script" >&2; exit 52; }
  done
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

verify_container_config_binding() {
  owner_dir=$1
  owner_config_files=$2
  purpose=$3
  case "$owner_config_files" in
    ''|*","*|*":"*)
      echo "ABORT: $purpose has unsafe Compose config_files ownership proof" >&2
      exit 54
      ;;
  esac
  if printf '%s' "$owner_config_files" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then
    echo "ABORT: $purpose has unsafe Compose config_files ownership proof" >&2
    exit 54
  fi
  case "$owner_config_files" in
    "$PROJECT_ROOT"/releases/*/deploy/compose.yaml) ;;
    *)
      echo "ABORT: $purpose is owned by another Compose project/root" >&2
      exit 54
      ;;
  esac
  release_tail=${owner_config_files#"$PROJECT_ROOT"/releases/}
  owner_release_id=${release_tail%/deploy/compose.yaml}
  case "$owner_release_id" in
    ''|*[!A-Za-z0-9._-]*|*/*|-*)
      echo "ABORT: $purpose has unsafe Compose release ownership proof" >&2
      exit 54
      ;;
  esac
  owner_release_base=$PROJECT_ROOT/releases/$owner_release_id
  owner_release_deploy=$owner_release_base/deploy
  case "$owner_dir" in
    "$PROJECT_ROOT"|"$owner_release_deploy") ;;
    *)
      echo "ABORT: $purpose is owned by another Compose project/root" >&2
      exit 54
      ;;
  esac
  [ -d "$owner_release_base" ] && [ ! -L "$owner_release_base" ] || { echo "ABORT: $purpose release ownership root is missing or unsafe" >&2; exit 54; }
  [ -d "$owner_release_deploy" ] && [ ! -L "$owner_release_deploy" ] || { echo "ABORT: $purpose release deploy ownership root is missing or unsafe" >&2; exit 54; }
  [ -f "$owner_config_files" ] && [ ! -L "$owner_config_files" ] || { echo "ABORT: $purpose Compose config file is missing or unsafe" >&2; exit 54; }
  owner_release_real=$(safe_realpath "$owner_release_base")
  owner_deploy_real=$(safe_realpath "$owner_release_deploy")
  owner_config_real=$(safe_realpath "$owner_config_files")
  [ "$owner_release_real" = "$owner_release_base" ] || { echo "ABORT: $purpose release ownership root resolves outside the project" >&2; exit 54; }
  [ "$owner_deploy_real" = "$owner_release_deploy" ] || { echo "ABORT: $purpose release deploy ownership root resolves outside the project" >&2; exit 54; }
  [ "$owner_config_real" = "$owner_release_deploy/compose.yaml" ] || { echo "ABORT: $purpose Compose config file resolves outside the release" >&2; exit 54; }
  owner_manifest=$owner_release_base/release-tree.sha256
  [ -f "$owner_manifest" ] && [ ! -L "$owner_manifest" ] || { echo "ABORT: $purpose release manifest is missing or unsafe" >&2; exit 54; }
  compose_manifest_lines=$(awk 'index($0, "  ") == 65 && substr($0, 67) == "deploy/compose.yaml" { c++ } END { print c + 0 }' "$owner_manifest")
  [ "$compose_manifest_lines" -eq 1 ] || { echo "ABORT: $purpose release manifest must bind exactly one deploy/compose.yaml" >&2; exit 54; }
  compose_manifest_line=$(awk 'index($0, "  ") == 65 && substr($0, 67) == "deploy/compose.yaml" { print }' "$owner_manifest")
  compose_manifest_hash=${compose_manifest_line%%  *}
  if ! printf '%s\n' "$compose_manifest_hash" | grep -E '^[0-9a-f]{64}$' >/dev/null 2>&1; then
    echo "ABORT: $purpose release manifest has malformed deploy/compose.yaml hash" >&2
    exit 54
  fi
  actual_compose_hash=$(sha256sum "$owner_config_files" | awk '{print $1}')
  [ "$actual_compose_hash" = "$compose_manifest_hash" ] || { echo "ABORT: $purpose Compose config hash does not match release manifest" >&2; exit 54; }
}

verify_container_owner() {
  container_id=$1
  purpose=$2
  owner_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container_id" 2>/dev/null || true)
  owner_dir=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_id" 2>/dev/null || true)
  owner_config_files=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$container_id" 2>/dev/null || true)
  if [ "$owner_project" != "makerseed-diagnostic" ]; then
    echo "ABORT: $purpose is owned by another Compose project/root" >&2
    exit 54
  fi
  verify_container_config_binding "$owner_dir" "$owner_config_files" "$purpose"
}

compose() {
  docker-compose -p makerseed-diagnostic --project-directory "$PROJECT_ROOT" --env-file "$PROJECT_ROOT/.env" -f "$RELEASE_ROOT/compose.yaml" "$@"
}
