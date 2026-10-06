#!/bin/bash
# 모듈 5-2: 사용자의 Virtual Key를 전부 폐기한다.
#   admin/revoke-keys.sh EMAIL
# 폐기 = 지금 들고 있는 키 무효화. SSO 세션이 살아 있으면 개발자는 새 키를 다시 받을 수 있다.
# 완전 차단은 Keycloak에서 계정을 비활성화(refresh 차단)한 뒤 이 스크립트로 남은 키를 지운다.
. "$(dirname "$0")/_env.sh"
[ $# -eq 1 ] || { echo "usage: $0 EMAIL" >&2; exit 1; }

user_id=$(find_user_id "$1")
[ -n "$user_id" ] || { echo "no LiteLLM user with email $1" >&2; exit 1; }
keys=$(litellm_api GET "/key/list?user_id=$user_id&return_full_object=true&size=100")
count=$(jq '.keys | length' <<<"$keys")
if [ "$count" -eq 0 ]; then echo "no keys for $1"; exit 0; fi

jq -r '.keys[] | "revoke  \(.key_alias)  (expires \(.expires))"' <<<"$keys"
litellm_api POST /key/delete "$(jq -c '{keys: [.keys[].token]}' <<<"$keys")" >/dev/null
echo "revoked $count key(s) for $1"
