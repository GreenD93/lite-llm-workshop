#!/bin/bash
# 모듈 5-2: 사용자 완전 차단 = ① Keycloak 계정 비활성화(새 키 발급 경로 차단) + ② 남은 Virtual Key 폐기.
# 키 폐기만 하면 SSO 세션이 살아 있어 개발자가 새 키를 다시 받는다 → 둘 다 해야 차단이다.
#   admin/block-user.sh developer001              차단
#   admin/block-user.sh developer001 --unblock    해제 (키는 개발자가 다시 발급받는다)
. "$(dirname "$0")/_env.sh"
[ $# -ge 1 ] || { echo "usage: $0 KEYCLOAK_USERNAME [--unblock]" >&2; exit 1; }
username=$1
enabled=false; [ "${2:-}" = "--unblock" ] && enabled=true

kcadm() { docker compose -f "$ROOT/docker-compose.yml" exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kcadm config credentials --server http://localhost:8080 --realm master \
  --user admin --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1
kc_user=$(kcadm get users -r workshop -q "username=$username" -q exact=true --fields id,email)
kc_id=$(jq -r '.[0].id // empty' <<<"$kc_user")
email=$(jq -r '.[0].email // empty' <<<"$kc_user")
[ -n "$kc_id" ] || { echo "no Keycloak user $username" >&2; exit 1; }

kcadm update "users/$kc_id" -r workshop -s "enabled=$enabled"
if [ "$enabled" = true ]; then
  echo "unblocked $username"
  exit 0
fi
kcadm create "users/$kc_id/logout" -r workshop >/dev/null   # 기존 SSO 세션(refresh token)도 끊는다
echo "disabled Keycloak user $username and ended its SSO sessions"
"$(dirname "$0")/revoke-keys.sh" "$email"
