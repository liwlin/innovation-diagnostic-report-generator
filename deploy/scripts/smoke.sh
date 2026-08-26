#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${SMOKE_ADMIN_USERNAME:?SMOKE_ADMIN_USERNAME is required}"
: "${SMOKE_ADMIN_PASSWORD:?SMOKE_ADMIN_PASSWORD is required}"
: "${SMOKE_TEST_PASSWORD:?SMOKE_TEST_PASSWORD is required}"

base_url=${SMOKE_BASE_URL:-http://127.0.0.1:18081}
admin_cookie=$(mktemp)
teacher_cookie=$(mktemp)
body_file=$(mktemp)
temp_username="mkseed-smoke-$(date -u +%Y%m%d%H%M%S)-$$"
temp_user_id=''
batch_id=''
evaluation_id=''

csrf_from_cookie() {
  awk '$6 == "mkseed_csrf" {value=$7} END {print value}' "$1"
}

json_string() {
  field=$1
  sed -n 's/.*"'"$field"'":"\([^"]*\)".*/\1/p' "$body_file" | head -n 1
}

json_number() {
  field=$1
  sed -n 's/.*"'"$field"'":\([0-9][0-9]*\).*/\1/p' "$body_file" | head -n 1
}

request() {
  method=$1
  path=$2
  cookie=$3
  csrf=$4
  data=${5:-}
  if [ -n "$data" ]; then
    if [ -n "$csrf" ]; then
      curl --silent --show-error --output "$body_file" --write-out '%{http_code}' \
        --request "$method" \
        --cookie "$cookie" --cookie-jar "$cookie" \
        --header 'Content-Type: application/json' \
        --header "X-CSRF-Token: $csrf" \
        --data "$data" \
        "$base_url$path"
    else
      curl --silent --show-error --output "$body_file" --write-out '%{http_code}' \
        --request "$method" \
        --cookie "$cookie" --cookie-jar "$cookie" \
        --header 'Content-Type: application/json' \
        --data "$data" \
        "$base_url$path"
    fi
  else
    if [ -n "$csrf" ]; then
      curl --silent --show-error --output "$body_file" --write-out '%{http_code}' \
        --request "$method" \
        --cookie "$cookie" --cookie-jar "$cookie" \
        --header "X-CSRF-Token: $csrf" \
        "$base_url$path"
    else
      curl --silent --show-error --output "$body_file" --write-out '%{http_code}' \
        --request "$method" \
        --cookie "$cookie" --cookie-jar "$cookie" \
        "$base_url$path"
    fi
  fi
}

cleanup_smoke() {
  admin_csrf=$(csrf_from_cookie "$admin_cookie" 2>/dev/null || true)
  if [ -n "$evaluation_id" ] && [ -n "$admin_csrf" ]; then
    request POST "/api/evaluations/$evaluation_id/trash" "$admin_cookie" "$admin_csrf" '' >/dev/null 2>&1 || true
    request DELETE "/api/evaluations/$evaluation_id" "$admin_cookie" "$admin_csrf" '{"reason":"cleanup temporary smoke test record"}' >/dev/null 2>&1 || true
  fi
  if [ -n "$temp_user_id" ] && [ -n "$admin_csrf" ]; then
    request PATCH "/api/admin/users/$temp_user_id" "$admin_cookie" "$admin_csrf" '{"is_active":false}' >/dev/null 2>&1 || true
  fi
  rm -f "$admin_cookie" "$teacher_cookie" "$body_file"
}
trap cleanup_smoke EXIT HUP INT TERM

health=$(curl --fail --silent --show-error "$base_url/api/health")
case "$health" in
  *'"status":"ok"'*) ;;
  *) echo "ABORT: unexpected health response" >&2; exit 70 ;;
esac

unauthorized=$(curl --silent --output /dev/null --write-out '%{http_code}' "$base_url/api/session")
if [ "$unauthorized" != "401" ]; then
  echo "ABORT: unauthenticated session request did not return 401" >&2
  exit 71
fi

status=$(request POST /api/auth/login "$admin_cookie" '' '{"username":"'"$SMOKE_ADMIN_USERNAME"'","password":"'"$SMOKE_ADMIN_PASSWORD"'"}')
[ "$status" = "200" ] || { echo "ABORT: admin smoke login failed" >&2; exit 72; }
admin_csrf=$(csrf_from_cookie "$admin_cookie")
[ -n "$admin_csrf" ] || { echo "ABORT: admin CSRF cookie was not set" >&2; exit 72; }

status=$(request POST /api/admin/users "$admin_cookie" "$admin_csrf" '{"username":"'"$temp_username"'","display_name":"Smoke Test Teacher","role":"teacher","password":"'"$SMOKE_TEST_PASSWORD"'"}')
[ "$status" = "201" ] || { echo "ABORT: temporary smoke account creation failed" >&2; exit 73; }
temp_user_id=$(json_string id)
[ -n "$temp_user_id" ] || { echo "ABORT: temporary smoke account id missing" >&2; exit 73; }

status=$(request POST /api/auth/login "$teacher_cookie" '' '{"username":"'"$temp_username"'","password":"'"$SMOKE_TEST_PASSWORD"'"}')
[ "$status" = "200" ] || { echo "ABORT: temporary smoke login failed" >&2; exit 74; }
teacher_csrf=$(csrf_from_cookie "$teacher_cookie")
[ -n "$teacher_csrf" ] || { echo "ABORT: temporary smoke CSRF cookie was not set" >&2; exit 74; }

status=$(request GET /api/session "$teacher_cookie" '' '')
[ "$status" = "200" ] || { echo "ABORT: authenticated session check failed" >&2; exit 75; }

status=$(request POST /api/batches "$teacher_cookie" '' '{"display_name":"Smoke Batch","event_date":"2026-08-25","date_label":"8月25日","teacher_label":"Smoke Test","fill_date":"2026-08-25"}')
if [ "$status" != "403" ] || ! grep -q 'csrf_failed' "$body_file"; then
  echo "ABORT: state-changing request without CSRF was not rejected" >&2
  exit 76
fi

status=$(request POST /api/batches "$teacher_cookie" "$teacher_csrf" '{"display_name":"Smoke Batch","event_date":"2026-08-25","date_label":"8月25日","teacher_label":"Smoke Test","fill_date":"2026-08-25"}')
[ "$status" = "201" ] || { echo "ABORT: smoke batch creation failed" >&2; exit 77; }
batch_id=$(json_string id)
[ -n "$batch_id" ] || { echo "ABORT: smoke batch id missing" >&2; exit 77; }

payload='{"student":{"name":"Smoke Test Student","grade":"三年级","slot":"smoke"},"payload":{"schema_version":1,"mods":[],"customMods":[],"chart":"radar","rates":[0,0,0,0,0],"skills":[{"m":"","p":"","r":0},{"m":"","p":"","r":0},{"m":"","p":"","r":0}],"obs1":"","obs2":"","dir":-1,"reason":"","classIndex":"","recommended_class":"Smoke Class","dirCustom":{"name":"","desc":""},"attendp":"是","talk":"已完成","intent":"高","why":"","ref":"","follow":"","note":"","generated":false}}'
status=$(request POST "/api/batches/$batch_id/evaluations" "$teacher_cookie" "$teacher_csrf" "$payload")
[ "$status" = "201" ] || { echo "ABORT: smoke evaluation creation failed" >&2; exit 78; }
evaluation_id=$(json_string evaluation_id)
version=$(json_number version)
[ -n "$evaluation_id" ] && [ -n "$version" ] || { echo "ABORT: smoke evaluation identity missing" >&2; exit 78; }

status=$(request GET '/api/evaluations?q=Smoke%20Test%20Student' "$teacher_cookie" '' '')
[ "$status" = "200" ] && grep -q "$evaluation_id" "$body_file" || { echo "ABORT: smoke search failed" >&2; exit 79; }

update_payload='{"version":'"$version"',"student":{"name":"Smoke Test Student","grade":"四年级","slot":"smoke"},"payload":{"schema_version":1,"mods":[],"customMods":[],"chart":"radar","rates":[1,1,1,1,1],"skills":[{"m":"","p":"","r":0},{"m":"","p":"","r":0},{"m":"","p":"","r":0}],"obs1":"updated by smoke","obs2":"","dir":-1,"reason":"","classIndex":"","recommended_class":"Smoke Class Updated","dirCustom":{"name":"","desc":""},"attendp":"是","talk":"已完成","intent":"高","why":"","ref":"","follow":"","note":"","generated":false}}'
status=$(request PUT "/api/evaluations/$evaluation_id" "$teacher_cookie" "$teacher_csrf" "$update_payload")
[ "$status" = "200" ] || { echo "ABORT: smoke update failed" >&2; exit 79; }

status=$(request POST "/api/evaluations/$evaluation_id/trash" "$teacher_cookie" "$teacher_csrf" '')
[ "$status" = "200" ] || { echo "ABORT: smoke trash failed" >&2; exit 79; }
status=$(request GET '/api/evaluations?trashed=true&q=Smoke%20Test%20Student' "$teacher_cookie" '' '')
[ "$status" = "200" ] && grep -q "$evaluation_id" "$body_file" || { echo "ABORT: smoke trashed search failed" >&2; exit 79; }
status=$(request POST "/api/evaluations/$evaluation_id/restore" "$teacher_cookie" "$teacher_csrf" '')
[ "$status" = "200" ] || { echo "ABORT: smoke restore failed" >&2; exit 79; }
status=$(request POST "/api/evaluations/$evaluation_id/trash" "$teacher_cookie" "$teacher_csrf" '')
[ "$status" = "200" ] || { echo "ABORT: smoke final trash failed" >&2; exit 79; }
status=$(request DELETE "/api/evaluations/$evaluation_id" "$admin_cookie" "$admin_csrf" '{"reason":"cleanup temporary smoke test record"}')
[ "$status" = "204" ] || { echo "ABORT: smoke permanent delete cleanup failed" >&2; exit 79; }
evaluation_id=''

status=$(request PATCH "/api/admin/users/$temp_user_id" "$admin_cookie" "$admin_csrf" '{"is_active":false}')
[ "$status" = "200" ] || { echo "ABORT: smoke temporary account cleanup failed" >&2; exit 79; }
temp_user_id=''

trap - EXIT HUP INT TERM
cleanup_smoke
echo "SMOKE_OK: health=200 unauthenticated_session=401 login csrf create search update trash restore cleanup"
