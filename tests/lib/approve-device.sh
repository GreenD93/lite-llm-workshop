#!/bin/bash
# 브라우저 없이 Keycloak Device Grant를 승인한다 (테스트 자동화 전용).
# 사람이 브라우저에서 하는 3단계를 그대로 HTTP로 재현한다:
#   ① verification_uri_complete 열기 → 로그인 폼
#   ② username/password 제출       → 동의(OAUTH_GRANT) 폼. device grant는 consentRequired=false여도 항상 묻는다.
#   ③ 동의(accept=Yes) 제출         → "Device Login Successful"
# 사용: approve-device.sh <verification_uri_complete> <username> <password>
set -euo pipefail
uri=$1 username=$2 password=$3
jar=$(mktemp); trap 'rm -f "$jar"' EXIT
origin=$(printf '%s' "$uri" | grep -oE '^https?://[^/]+')

# 페이지에서 첫 form의 action을 꺼내 절대 URL로 만든다.
form_action() {
  local action
  action=$(grep -oE '<form[^>]*action="[^"]+"' | head -1 | sed -E 's/.*action="([^"]+)"/\1/; s/&amp;/\&/g')
  [ -n "$action" ] || { echo "no form on page - login page layout changed?" >&2; return 1; }
  case "$action" in http*) echo "$action" ;; *) echo "$origin$action" ;; esac
}

page=$(curl -sS -L -c "$jar" -b "$jar" "$uri")
page=$(curl -sS -L -c "$jar" -b "$jar" "$(form_action <<<"$page")" \
  --data-urlencode "username=$username" --data-urlencode "password=$password")
code=$(grep -oE 'name="code" value="[^"]+"' <<<"$page" | sed -E 's/.*value="([^"]+)"/\1/')
[ -n "$code" ] || { echo "login rejected (wrong password?) - no consent form" >&2; exit 1; }
page=$(curl -sS -L -c "$jar" -b "$jar" "$(form_action <<<"$page")" -d "code=$code" -d accept=Yes)
grep -q "Device Login Successful" <<<"$page" || { echo "consent step did not succeed" >&2; exit 1; }
echo "device approved: $username"
