#!/bin/bash
# 모듈 5-1: 지출·프롬프트 감사.
#   admin/audit-spend.sh                     전체 사용자 예산 사용 현황
#   admin/audit-spend.sh EMAIL [N]           해당 사용자의 최근 N건(기본 10) 요청: 시각·키 alias·모델·비용·프롬프트 앞부분
# 지출 로그는 LiteLLM이 비동기로 묶어서 DB에 쓴다 → 방금 보낸 요청은 수십 초 뒤에 보일 수 있다.
. "$(dirname "$0")/_env.sh"

if [ $# -eq 0 ]; then
  litellm_api GET "/user/list?page_size=100" | jq -r '
    ["EMAIL","SPEND($)","BUDGET($)","USED%","RPM"],
    (.users[] | select(.user_email) |
      [.user_email, (.spend*10000|round/10000), .max_budget,
       (if .max_budget then (.spend/.max_budget*100|round) else "-" end), .rpm_limit]) | @tsv' | column -t
  exit 0
fi

user_id=$(find_user_id "$1")
[ -n "$user_id" ] || { echo "no LiteLLM user with email $1" >&2; exit 1; }
litellm_api GET "/spend/logs?user_id=$user_id" | jq -r --argjson n "${2:-10}" '
  def text: if type == "array" then map(.text? // "") | join(" ") else (. // "" | tostring) end;
  def prompt: .proxy_server_request
    | if .messages then (.messages | last | .content | text) else (.input | if type == "array" then (last | .content | text) else text end) end;
  ["TIME(UTC)","KEY_ALIAS","MODEL","CALL","SPEND($)","STATUS","PROMPT"],
  (sort_by(.startTime) | reverse | .[:$n][] |
    [.startTime[0:19], .metadata.user_api_key_alias, .model_group, .call_type, .spend, .status,
     (prompt | gsub("\\s+"; " ") | .[0:60])]) | @tsv' | column -t -s $'\t'
