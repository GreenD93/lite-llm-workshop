#!/bin/bash
# 워크샵 전체 흐름 시나리오 테스트. developer002로 모듈 2~5를 종단으로 돌린다.
#   tests/e2e.sh
# 전제: docker compose up -d, 호스트 Ollama에 qwen3:4b.
# 개발자 PC는 임시 디렉터리(DEV_HOME)에 새로 깔기 때문에 sandbox/(사용자 실습 환경)는 건드리지 않는다.
# 모델 호출이 로컬 CPU/GPU에서 돌아서 전체 2~5분 걸린다.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/admin/_env.sh"
set +e
EMAIL=developer002@example.com
USERNAME=developer002
PASSWORD='Workshop123!'
LOG_WAIT_SECONDS=120   # 지출 로그 비동기 기록 대기 상한

export DEV_HOME
DEV_HOME=$(mktemp -d)
cleanup() {
  rm -rf "$DEV_HOME"
  "$ROOT/admin/block-user.sh" "$USERNAME" --unblock >/dev/null 2>&1
  "$ROOT/admin/onboard-users.sh" "$EMAIL" >/dev/null 2>&1
}
trap cleanup EXIT
dev() { BROWSER= "$ROOT/client/dev-shell.sh" "$@"; }

fails=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2" | head -c 400; fails=$((fails + 1)); }
step() { printf '\n%s\n' "$1"; }
# http_code METHOD URL [curl args...] → HTTP 상태코드만
http_code() { curl -s -o /dev/null -w '%{http_code}' -X "$@"; }

step "① 스택 상태"
[ "$(http_code GET "$GATEWAY_URL/auth/health")" = 200 ] && pass "broker /auth/health 200" || fail "broker /auth/health"
models=$(litellm_api GET /v1/models | jq -r '[.data[].id] | sort | join(",")')
[ "$models" = "claude-haiku-4-5,claude-sonnet-5,gpt-5.6-sol,qwen3-coder" ] && pass "모델 4개 등록" || fail "모델 목록" "$models"

step "② broker 거절 경로"
[ "$(http_code POST "$GATEWAY_URL/auth/key")" = 401 ] && pass "토큰 없음 → 401" || fail "토큰 없음"
[ "$(http_code POST "$GATEWAY_URL/auth/key" -H 'Authorization: Bearer not-a-jwt')" = 401 ] && pass "위조 토큰 → 401" || fail "위조 토큰"
admin_token=$(curl -s "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d username=admin -d "password=$KEYCLOAK_ADMIN_PASSWORD" | jq -r .access_token)
[ "$(http_code POST "$GATEWAY_URL/auth/key" -H "Authorization: Bearer $admin_token")" = 401 ] \
  && pass "다른 realm(master) 토큰 → 401" || fail "다른 realm 토큰"

step "③ SSO 로그인 (Device Grant, 헤드리스 승인)"
"$ROOT/client/install.sh" >/dev/null
login_log=$(mktemp)
dev gateway-login.sh >"$login_log" 2>&1 &
login_pid=$!
uri=""
for _ in $(seq 1 20); do
  uri=$(grep -oE 'https?://[^ ]+user_code=[A-Z-]+' "$login_log" || true)
  [ -n "$uri" ] && break; sleep 0.5
done
"$ROOT/tests/lib/approve-device.sh" "$uri" "$USERNAME" "$PASSWORD" >/dev/null
wait "$login_pid" && grep -q "SSO login complete: $USERNAME" "$login_log" \
  && pass "gateway-login.sh → session.json" || fail "로그인" "$(cat "$login_log")"

step "④ 온보딩 전에는 키를 못 받는다"
user_id=$(find_user_id "$EMAIL")
[ -n "$user_id" ] && litellm_api POST /user/delete "{\"user_ids\":[\"$user_id\"]}" >/dev/null
out=$(dev get-gateway-key.sh 2>&1)
[ $? -ne 0 ] && pass "미등록 사용자 → 키 발급 실패" || fail "미등록 사용자에게 키가 발급됨" "$out"
"$ROOT/admin/onboard-users.sh" "$EMAIL" >/dev/null
key=$(dev get-gateway-key.sh)
[[ "$key" == sk-* ]] && pass "온보딩 후 → 임시 키 발급" || fail "온보딩 후 키 발급" "$key"
[ "$(dev get-gateway-key.sh)" = "$key" ] && pass "두 번째 호출은 캐시된 같은 키" || fail "캐시 미사용"
[ "$(stat -f %Lp "$DEV_HOME/.gateway/virtual-key" 2>/dev/null || stat -c %a "$DEV_HOME/.gateway/virtual-key")" = 600 ] \
  && pass "키 파일 권한 600" || fail "키 파일 권한"
[ "$(litellm_api GET "/key/list?user_id=$(find_user_id "$EMAIL")" | jq '.keys | length')" = 1 ] \
  && pass "사용자 키는 broker가 발급한 1개뿐 (정적 키 없음)" || fail "키 개수"

step "⑤ 세 가지 API 포맷 (Claude Code · Codex · OpenCode가 쓰는 경로)"
code=$(http_code POST "$GATEWAY_URL/v1/messages" -H "x-api-key: $key" -H 'anthropic-version: 2023-06-01' \
  -H 'content-type: application/json' -d '{"model":"claude-sonnet-5","max_tokens":512,"messages":[{"role":"user","content":"hi"}]}')
[ "$code" = 200 ] && pass "Anthropic /v1/messages (claude-sonnet-5)" || fail "/v1/messages HTTP $code"
code=$(http_code POST "$GATEWAY_URL/v1/responses" -H "Authorization: Bearer $key" \
  -H 'content-type: application/json' -d '{"model":"gpt-5.6-sol","input":"hi"}')
[ "$code" = 200 ] && pass "OpenAI /v1/responses (gpt-5.6-sol)" || fail "/v1/responses HTTP $code"
code=$(http_code POST "$GATEWAY_URL/v1/chat/completions" -H "Authorization: Bearer $key" \
  -H 'content-type: application/json' -d '{"model":"qwen3-coder","messages":[{"role":"user","content":"주민번호 900101-1234567 연락처 010-1234-5678 를 그대로 따라 써줘"}]}')
[ "$code" = 200 ] && pass "OpenAI /v1/chat/completions (qwen3-coder)" || fail "/v1/chat/completions HTTP $code"

step "⑥ PII 마스킹 + 감사 로그 (비동기 기록, 최대 ${LOG_WAIT_SECONDS}s 대기)"
user_id=$(find_user_id "$EMAIL")
prompt=""
deadline=$(($(date +%s) + LOG_WAIT_SECONDS))
while [ "$(date +%s)" -lt "$deadline" ]; do
  prompt=$(litellm_api GET "/spend/logs?user_id=$user_id" \
    | jq -r '[.[] | select(.call_type == "acompletion")][0].proxy_server_request.messages[0].content // empty')
  [ -n "$prompt" ] && break; sleep 5
done
[[ "$prompt" == *"[KR-RESIDENT-ID]"*"[KR-MOBILE]"* ]] && pass "로그에 마스킹된 프롬프트만 남음" || fail "PII 마스킹" "$prompt"
[[ "$prompt" != *"900101-1234567"* ]] && pass "원문 주민번호는 로그에 없음" || fail "원문 PII가 로그에 남음"
spend=$(litellm_api GET "/user/info?user_id=$user_id" | jq '.user_info.spend')
awk "BEGIN{exit !($spend > 0)}" && pass "사용자 지출 집계 (\$$spend)" || fail "지출 집계" "$spend"

step "⑦ 예산 초과 → 422"
"$ROOT/admin/onboard-users.sh" "$EMAIL" 0.0000001 >/dev/null
code=$(http_code POST "$GATEWAY_URL/v1/chat/completions" -H "Authorization: Bearer $key" \
  -H 'content-type: application/json' -d '{"model":"qwen3-coder","messages":[{"role":"user","content":"hi"}]}')
[ "$code" = 422 ] && pass "예산 초과 요청 거절 422" || fail "예산 초과 HTTP $code"
"$ROOT/admin/onboard-users.sh" "$EMAIL" >/dev/null

step "⑧ 키 폐기 → 401, 캐시 삭제 후 SSO 세션으로 재발급"
"$ROOT/admin/revoke-keys.sh" "$EMAIL" >/dev/null
[ "$(http_code GET "$GATEWAY_URL/v1/models" -H "Authorization: Bearer $key")" = 401 ] && pass "폐기된 키 → 401" || fail "폐기된 키가 여전히 동작"
[ "$(dev get-gateway-key.sh)" = "$key" ] && pass "헬퍼는 캐시가 유효하면 폐기된 키를 계속 돌려준다 (알려진 한계)" || fail "캐시 동작 변경됨"
rm -f "$DEV_HOME/.gateway/virtual-key.json"
new_key=$(dev get-gateway-key.sh)
[ "$(http_code GET "$GATEWAY_URL/v1/models" -H "Authorization: Bearer $new_key")" = 200 ] && [ "$new_key" != "$key" ] \
  && pass "캐시 삭제 → 새 키 발급 → 200" || fail "재발급"

step "⑨ 완전 차단 (Keycloak 비활성화 + 키 폐기)"
"$ROOT/admin/block-user.sh" "$USERNAME" >/dev/null 2>&1
[ "$(http_code GET "$GATEWAY_URL/v1/models" -H "Authorization: Bearer $new_key")" = 401 ] && pass "차단 후 기존 키 → 401" || fail "차단 후 키가 동작"
rm -f "$DEV_HOME/.gateway/virtual-key.json"
out=$(dev get-gateway-key.sh 2>&1)
[ $? -ne 0 ] && pass "차단 후 새 키 발급 불가 ($out)" || fail "차단 후에도 키 발급됨"
"$ROOT/admin/block-user.sh" "$USERNAME" --unblock >/dev/null 2>&1

printf '\n'
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
