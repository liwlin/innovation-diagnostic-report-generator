#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${RELEASE_ROOT:?RELEASE_ROOT is required}"
: "${APP_IMAGE:?APP_IMAGE is required}"
: "${SECRETS_ROOT:?SECRETS_ROOT is required}"
: "${REPORT_ROOT:?REPORT_ROOT is required}"
: "${PREFLIGHT_NONCE:?PREFLIGHT_NONCE is required}"

MIN_DOCKER_VERSION=${MIN_DOCKER_VERSION:-24.0.0}
MIN_COMPOSE_VERSION=${MIN_COMPOSE_VERSION:-2.20.0}
APPROVED_REPORT_ROOT=${APPROVED_REPORT_ROOT:-/volume1/科创诊断报告}

case "$PREFLIGHT_NONCE" in
  [A-Za-z0-9._-][A-Za-z0-9._-][A-Za-z0-9._-][A-Za-z0-9._-]*) ;;
  *) echo "ABORT: PREFLIGHT_NONCE must be at least four safe characters" >&2; exit 50 ;;
esac

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

if [ ! -d /volume1/docker ] || [ -L /volume1/docker ]; then
  echo "ABORT: verified Docker parent /volume1/docker is missing or unsafe" >&2
  exit 51
fi
if [ -e "$PROJECT_ROOT" ] && [ -L "$PROJECT_ROOT" ]; then
  echo "ABORT: project root is a symbolic link" >&2
  exit 51
fi
if [ ! -f "$RELEASE_ROOT/compose.yaml" ] || [ ! -f "$RELEASE_ROOT/Dockerfile" ]; then
  echo "ABORT: release files are incomplete" >&2
  exit 52
fi
resolved_release=$(readlink -f "$RELEASE_ROOT")
case "$resolved_release" in
  "$PROJECT_ROOT"/releases/*/deploy|"$PROJECT_ROOT"/current/deploy) ;;
  *) echo "ABORT: RELEASE_ROOT must be a deploy release path" >&2; exit 52 ;;
esac

free_kb=$(df -Pk /volume1/docker | awk 'NR==2 {print $4}')
available_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
if [ -z "$free_kb" ] || [ "$free_kb" -lt 5242880 ]; then
  echo "ABORT: less than 5 GiB is available on the target volume" >&2
  exit 53
fi
if [ -z "$available_kb" ] || [ "$available_kb" -lt 2097152 ]; then
  echo "ABORT: less than 2 GiB of memory is available" >&2
  exit 53
fi

if docker ps --format '{{.Ports}}' | grep -Eq '(^|[:.])18081->|127\.0\.0\.1:18081'; then
  existing_project=$(docker ps --filter label=com.docker.compose.project=makerseed-diagnostic --format '{{.ID}}')
  if [ -z "$existing_project" ]; then
    echo "ABORT: loopback port 18081 is already used outside this project" >&2
    exit 54
  fi
fi
foreign_project_containers=$(docker ps -a --filter label=com.docker.compose.project=makerseed-diagnostic --format '{{.Names}} {{.Label "com.docker.compose.project.working_dir"}}' | awk -v root="$PROJECT_ROOT" '$2 != "" && $2 != root {print $1}')
if [ -n "$foreign_project_containers" ]; then
  echo "ABORT: Compose project name is already used by another root" >&2
  exit 54
fi
if docker ps -a --format '{{.Names}}' | grep -Eq '^(makerseed-diagnostic[-_](app|db)[-_]?[0-9]*|makerseed-diagnostic-(app|db))$'; then
  conflicting_names=$(docker ps -a --filter label=com.docker.compose.project=makerseed-diagnostic --format '{{.Names}}')
  [ -n "$conflicting_names" ] || { echo "ABORT: app/db container names collide outside this project" >&2; exit 54; }
fi

case "$APP_IMAGE" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) echo "ABORT: APP_IMAGE must include an immutable SHA-256 digest" >&2; exit 55 ;;
esac

if ! docker image inspect "$APP_IMAGE" >/dev/null 2>&1; then
  if [ -z "${IMAGE_TAR:-}" ] || [ ! -f "$IMAGE_TAR" ] || [ -L "$IMAGE_TAR" ] || [ ! -f "$IMAGE_TAR.sha256" ]; then
    echo "ABORT: app image is absent and no verified IMAGE_TAR is available" >&2
    exit 56
  fi
  (cd "$(dirname "$IMAGE_TAR")" && sha256sum -c "$(basename "$IMAGE_TAR").sha256") >/dev/null
fi

resolved_secrets=$(readlink -f "$SECRETS_ROOT")
case "$resolved_secrets" in
  "$PROJECT_ROOT"/secrets) ;;
  *) echo "ABORT: SECRETS_ROOT must resolve to the project secrets directory" >&2; exit 58 ;;
esac
for secret_name in postgres_owner_password postgres_runtime_password database_url session_secret bootstrap_secret; do
  secret_path="$SECRETS_ROOT/$secret_name"
  require_regular_secret "$secret_path"
  secret_mode=$(stat -c %a "$secret_path")
  case "$secret_mode" in
    400|600) ;;
    *) echo "ABORT: secret $secret_name must be mode 400 or 600" >&2; exit 58 ;;
  esac
done

resolved_report=$(readlink -f "$REPORT_ROOT")
case "$resolved_report" in
  "$APPROVED_REPORT_ROOT") ;;
  *) echo "ABORT: REPORT_ROOT must resolve exactly to the approved File Station share" >&2; exit 59 ;;
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

if [ -e "$PROJECT_ROOT" ]; then
  for child in "$PROJECT_ROOT"/* "$PROJECT_ROOT"/.[!.]*; do
    [ -e "$child" ] || continue
    name=$(basename "$child")
    case "$name" in
      data|backups|reports-staging|secrets|releases|current|deployment-state|.env|.deploy-lock) ;;
      *) echo "ABORT: unexpected entry exists in project root: $name" >&2; exit 57 ;;
    esac
  done
fi

printf '{"result":"pass","nonce":"%s","architecture":"x86_64","project_root":"%s","port":18081,"app_image":"%s","compose_version":"%s","report_root":"%s"}\n' "$PREFLIGHT_NONCE" "$PROJECT_ROOT" "$APP_IMAGE" "$compose_version" "$resolved_report"
