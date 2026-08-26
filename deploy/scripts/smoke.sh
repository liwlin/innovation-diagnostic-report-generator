#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/common.sh"

require_exact_project_root
: "${SMOKE_ADMIN_USERNAME:?SMOKE_ADMIN_USERNAME is required}"
: "${SMOKE_ADMIN_PASSWORD_FILE:?SMOKE_ADMIN_PASSWORD_FILE is required}"
: "${SMOKE_TEST_PASSWORD_FILE:?SMOKE_TEST_PASSWORD_FILE is required}"
require_regular_secret_mode "$SMOKE_ADMIN_PASSWORD_FILE"
require_regular_secret_mode "$SMOKE_TEST_PASSWORD_FILE"

base_url=${SMOKE_BASE_URL:-http://127.0.0.1:18081}
admin_cookie=$(mktemp)
teacher_cookie=$(mktemp)
body_file=$(mktemp)
admin_login_body=$(mktemp)
teacher_login_body=$(mktemp)
create_user_body=$(mktemp)
create_batch_body=$(mktemp)
csrf_probe_body=$(mktemp)
create_evaluation_body=$(mktemp)
update_evaluation_body=$(mktemp)
delete_evaluation_body=$(mktemp)
disable_user_body=$(mktemp)
temp_username="mkseed-smoke-$(date -u +%Y%m%d%H%M%S)-$$"
temp_user_id=''
batch_id=''
evaluation_id=''

for request_body in "$admin_login_body" "$teacher_login_body" "$create_user_body" "$create_batch_body" "$csrf_probe_body" "$create_evaluation_body" "$update_evaluation_body" "$delete_evaluation_body" "$disable_user_body"; do
  chmod 600 "$request_body"
done

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

require_json_scalar() {
  value_name=$1
  value=$2
  case "$value" in
    *"
"*|*""*)
      echo "ABORT: $value_name must not contain control newlines" >&2
      exit 72
      ;;
  esac
}

read_single_line_secret() {
  secret_name=$1
  secret_path=$2
  line_count=$(wc -l <"$secret_path" | awk '{print $1}')
  if [ "$line_count" -gt 1 ]; then
    echo "ABORT: $secret_name must be a single line" >&2
    exit 72
  fi
  IFS= read -r secret_value <"$secret_path" || secret_value=''
  secret_value=${secret_value%}
  if [ "${#secret_value}" -lt 12 ]; then
    echo "ABORT: $secret_name must contain at least 12 characters" >&2
    exit 72
  fi
  printf '%s' "$secret_value"
}

write_json_body() {
  destination=$1
  content=$2
  printf '%s' "$content" >"$destination"
  chmod 600 "$destination"
}

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
  body_path=${5:-}
  if [ -n "$body_path" ]; then
    if [ -n "$csrf" ]; then
      curl --silent --show-error --output "$body_file" --write-out '%{http_code}' \
        --request "$method" \
        --cookie "$cookie" --cookie-jar "$cookie" \
        --header 'Content-Type: application/json' \
        --header "X-CSRF-Token: $csrf" \
        --data-binary @"$body_path" \
        "$base_url$path"
    else
      curl --silent --show-error --output "$body_file" --write-out '%{http_code}' \
        --request "$method" \
        --cookie "$cookie" --cookie-jar "$cookie" \
        --header 'Content-Type: application/json' \
        --data-binary @"$body_path" \
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
    write_json_body "$delete_evaluation_body" '{"reason":"cleanup temporary smoke test record"}'
    request DELETE "/api/evaluations/$evaluation_id" "$admin_cookie" "$admin_csrf" "$delete_evaluation_body" >/dev/null 2>&1 || true
  fi
  if [ -n "$temp_user_id" ] && [ -n "$admin_csrf" ]; then
    write_json_body "$disable_user_body" '{"is_active":false}'
    request PATCH "/api/admin/users/$temp_user_id" "$admin_cookie" "$admin_csrf" "$disable_user_body" >/dev/null 2>&1 || true
  fi
  rm -f "$admin_cookie" "$teacher_cookie" "$body_file" "$admin_login_body" "$teacher_login_body" "$create_user_body" "$create_batch_body" "$csrf_probe_body" "$create_evaluation_body" "$update_evaluation_body" "$delete_evaluation_body" "$disable_user_body"
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

require_json_scalar SMOKE_ADMIN_USERNAME "$SMOKE_ADMIN_USERNAME"
SMOKE_ADMIN_PASSWORD=$(read_single_line_secret SMOKE_ADMIN_PASSWORD_FILE "$SMOKE_ADMIN_PASSWORD_FILE")
SMOKE_TEST_PASSWORD=$(read_single_line_secret SMOKE_TEST_PASSWORD_FILE "$SMOKE_TEST_PASSWORD_FILE")
require_json_scalar SMOKE_ADMIN_PASSWORD "$SMOKE_ADMIN_PASSWORD"
require_json_scalar SMOKE_TEST_PASSWORD "$SMOKE_TEST_PASSWORD"
admin_username_json=$(json_escape "$SMOKE_ADMIN_USERNAME")
admin_password_json=$(json_escape "$SMOKE_ADMIN_PASSWORD")
test_password_json=$(json_escape "$SMOKE_TEST_PASSWORD")
temp_username_json=$(json_escape "$temp_username")

write_json_body "$admin_login_body" '{"username":"'"$admin_username_json"'","password":"'"$admin_password_json"'"}'
status=$(request POST /api/auth/login "$admin_cookie" '' "$admin_login_body")
[ "$status" = "200" ] || { echo "ABORT: admin smoke login failed" >&2; exit 72; }
admin_csrf=$(csrf_from_cookie "$admin_cookie")
[ -n "$admin_csrf" ] || { echo "ABORT: admin CSRF cookie was not set" >&2; exit 72; }

write_json_body "$create_user_body" '{"username":"'"$temp_username_json"'","display_name":"Smoke Test Teacher","role":"teacher","password":"'"$test_password_json"'"}'
status=$(request POST /api/admin/users "$admin_cookie" "$admin_csrf" "$create_user_body")
[ "$status" = "201" ] || { echo "ABORT: temporary smoke account creation failed" >&2; exit 73; }
temp_user_id=$(json_string id)
[ -n "$temp_user_id" ] || { echo "ABORT: temporary smoke account id missing" >&2; exit 73; }

write_json_body "$teacher_login_body" '{"username":"'"$temp_username_json"'","password":"'"$test_password_json"'"}'
status=$(request POST /api/auth/login "$teacher_cookie" '' "$teacher_login_body")
[ "$status" = "200" ] || { echo "ABORT: temporary smoke login failed" >&2; exit 74; }
teacher_csrf=$(csrf_from_cookie "$teacher_cookie")
[ -n "$teacher_csrf" ] || { echo "ABORT: temporary smoke CSRF cookie was not set" >&2; exit 74; }

status=$(request GET /api/session "$teacher_cookie" '' '')
[ "$status" = "200" ] || { echo "ABORT: authenticated session check failed" >&2; exit 75; }

write_json_body "$csrf_probe_body" '{"display_name":"Smoke Batch","event_date":"2026-08-25","date_label":"8月25日","teacher_label":"Smoke Test","fill_date":"2026-08-25"}'
status=$(request POST /api/batches "$teacher_cookie" '' "$csrf_probe_body")
if [ "$status" != "403" ] || ! grep -q 'csrf_failed' "$body_file"; then
  echo "ABORT: state-changing request without CSRF was not rejected" >&2
  exit 76
fi

write_json_body "$create_batch_body" '{"display_name":"Smoke Batch","event_date":"2026-08-25","date_label":"8月25日","teacher_label":"Smoke Test","fill_date":"2026-08-25"}'
status=$(request POST /api/batches "$teacher_cookie" "$teacher_csrf" "$create_batch_body")
[ "$status" = "201" ] || { echo "ABORT: smoke batch creation failed" >&2; exit 77; }
batch_id=$(json_string id)
[ -n "$batch_id" ] || { echo "ABORT: smoke batch id missing" >&2; exit 77; }

payload='{"student":{"name":"Smoke Test Student","grade":"三年级","slot":"smoke"},"payload":{"schema_version":1,"mods":[],"customMods":[],"chart":"radar","rates":[0,0,0,0,0],"skills":[{"m":"","p":"","r":0},{"m":"","p":"","r":0},{"m":"","p":"","r":0}],"obs1":"","obs2":"","dir":-1,"reason":"","classIndex":"","recommended_class":"Smoke Class","dirCustom":{"name":"","desc":""},"attendp":"是","talk":"已完成","intent":"高","why":"","ref":"","follow":"","note":"","generated":false}}'
write_json_body "$create_evaluation_body" "$payload"
status=$(request POST "/api/batches/$batch_id/evaluations" "$teacher_cookie" "$teacher_csrf" "$create_evaluation_body")
[ "$status" = "201" ] || { echo "ABORT: smoke evaluation creation failed" >&2; exit 78; }
evaluation_id=$(json_string evaluation_id)
version=$(json_number version)
[ -n "$evaluation_id" ] && [ -n "$version" ] || { echo "ABORT: smoke evaluation identity missing" >&2; exit 78; }

status=$(request GET '/api/evaluations?q=Smoke%20Test%20Student' "$teacher_cookie" '' '')
[ "$status" = "200" ] && grep -q "$evaluation_id" "$body_file" || { echo "ABORT: smoke search failed" >&2; exit 79; }

update_payload='{"version":'"$version"',"student":{"name":"Smoke Test Student","grade":"四年级","slot":"smoke"},"payload":{"schema_version":1,"mods":[],"customMods":[],"chart":"radar","rates":[1,1,1,1,1],"skills":[{"m":"","p":"","r":0},{"m":"","p":"","r":0},{"m":"","p":"","r":0}],"obs1":"updated by smoke","obs2":"","dir":-1,"reason":"","classIndex":"","recommended_class":"Smoke Class Updated","dirCustom":{"name":"","desc":""},"attendp":"是","talk":"已完成","intent":"高","why":"","ref":"","follow":"","note":"","generated":false}}'
write_json_body "$update_evaluation_body" "$update_payload"
status=$(request PUT "/api/evaluations/$evaluation_id" "$teacher_cookie" "$teacher_csrf" "$update_evaluation_body")
[ "$status" = "200" ] || { echo "ABORT: smoke update failed" >&2; exit 79; }

status=$(request POST "/api/evaluations/$evaluation_id/trash" "$teacher_cookie" "$teacher_csrf" '')
[ "$status" = "200" ] || { echo "ABORT: smoke trash failed" >&2; exit 79; }
status=$(request GET '/api/evaluations?trashed=true&q=Smoke%20Test%20Student' "$teacher_cookie" '' '')
[ "$status" = "200" ] && grep -q "$evaluation_id" "$body_file" || { echo "ABORT: smoke trashed search failed" >&2; exit 79; }
status=$(request POST "/api/evaluations/$evaluation_id/restore" "$teacher_cookie" "$teacher_csrf" '')
[ "$status" = "200" ] || { echo "ABORT: smoke restore failed" >&2; exit 79; }
status=$(request POST "/api/evaluations/$evaluation_id/trash" "$teacher_cookie" "$teacher_csrf" '')
[ "$status" = "200" ] || { echo "ABORT: smoke final trash failed" >&2; exit 79; }
write_json_body "$delete_evaluation_body" '{"reason":"cleanup temporary smoke test record"}'
status=$(request DELETE "/api/evaluations/$evaluation_id" "$admin_cookie" "$admin_csrf" "$delete_evaluation_body")
[ "$status" = "204" ] || { echo "ABORT: smoke permanent delete cleanup failed" >&2; exit 79; }
evaluation_id=''

write_json_body "$disable_user_body" '{"is_active":false}'
status=$(request PATCH "/api/admin/users/$temp_user_id" "$admin_cookie" "$admin_csrf" "$disable_user_body")
[ "$status" = "200" ] || { echo "ABORT: smoke temporary account cleanup failed" >&2; exit 79; }
temp_user_id=''

trap - EXIT HUP INT TERM
cleanup_smoke
echo "SMOKE_OK: health=200 unauthenticated_session=401 login csrf create search update trash restore cleanup"
