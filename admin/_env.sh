# 운영자 스크립트 공통: .env 로드 + 마스터 키로 LiteLLM 관리 API 호출.
# 운영자는 LiteLLM에 직접 붙지 않고 개발자와 같은 게이트웨이 URL을 쓴다.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
set -a; . "$ROOT/.env"; set +a

# litellm_api METHOD PATH [JSON_BODY]  → 응답 JSON. HTTP 4xx/5xx면 본문을 stderr로 내고 실패.
litellm_api() {
  local method=$1 path=$2 body=${3:-}
  local out status
  out=$(curl -sS -w '\n%{http_code}' -X "$method" "$GATEWAY_URL$path" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    ${body:+-d "$body"})
  status=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$status" -ge 400 ]; then echo "$method $path → HTTP $status: $out" >&2; return 1; fi
  printf '%s\n' "$out"
}

# find_user_id EMAIL → user_id (없으면 빈 문자열). /user/list 필터는 부분 일치라 정확히 다시 거른다.
find_user_id() {
  litellm_api GET "/user/list?user_email=$1" \
    | jq -r --arg e "$1" '[.users[] | select((.user_email // "" | ascii_downcase) == ($e | ascii_downcase))][0].user_id // empty'
}
