#!/bin/bash
# 모듈 2-3: LiteLLM에 개발자를 등록하고 사용자별 예산·Rate Limit을 건다.
# broker는 Keycloak 토큰의 email로 이 사용자를 찾아 키를 발급한다 → 여기 없는 사람은 SSO에 성공해도 키를 못 받는다.
#   admin/onboard-users.sh                                  developer001, developer002 (기본 정책)
#   admin/onboard-users.sh dev3@example.com [BUDGET] [RPM]  한 명만 등록/갱신
# 이미 있으면 정책만 갱신한다 (재실행 안전).
. "$(dirname "$0")/_env.sh"

onboard() {
  local email=$1 budget=${2:-$USER_MAX_BUDGET} rpm=${3:-$USER_RPM_LIMIT}
  local policy user_id
  policy=$(jq -nc --arg email "$email" --argjson budget "$budget" --arg dur "$USER_BUDGET_DURATION" --argjson rpm "$rpm" \
    '{user_email:$email, user_role:"internal_user", auto_create_key:false, max_budget:$budget, budget_duration:$dur, rpm_limit:$rpm}')
  user_id=$(find_user_id "$email")
  if [ -n "$user_id" ]; then
    litellm_api POST /user/update "$(jq -c --arg id "$user_id" '. + {user_id:$id}' <<<"$policy")" >/dev/null
    echo "updated  $email (user_id=$user_id, budget=\$$budget/$USER_BUDGET_DURATION, rpm=$rpm)"
  else
    user_id=$(litellm_api POST /user/new "$policy" | jq -r .user_id)
    echo "created  $email (user_id=$user_id, budget=\$$budget/$USER_BUDGET_DURATION, rpm=$rpm)"
  fi
}

if [ $# -gt 0 ]; then
  onboard "$@"
else
  onboard developer001@example.com
  onboard developer002@example.com
fi
