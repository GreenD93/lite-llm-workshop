#!/bin/bash
# Keycloak Device Grant SSO login -> caches the session (refresh token) at ~/.gateway/session.json
set -euo pipefail
. "$(dirname "$0")/../workshop.env"   # workshop: /etc/profile.d/workshop.sh
REALM_URL="$KEYCLOAK_URL/realms/workshop"
CLIENT_ID=workshop-cli
mkdir -p "$HOME/.gateway" && chmod 700 "$HOME/.gateway"

resp=$(curl -sS --connect-timeout 3 --max-time 10 -X POST "$REALM_URL/protocol/openid-connect/auth/device" -d "client_id=$CLIENT_ID")
if ! printf '%s\n' "$resp" | jq -es '
  select(length == 1) | .[0]
  | select(type == "object")
  | select(.device_code | type == "string" and length > 0)
  | select(.verification_uri_complete | type == "string" and length > 0)
  | select(.expires_in | type == "number" and . > 0 and . == floor)
  | select((if .interval == null then 5 else .interval end)
    | type == "number" and . > 0 and . == floor)
' >/dev/null 2>&1; then
  echo "device code request failed: $resp" >&2; exit 1
fi
device_code=$(echo "$resp" | jq -r '.device_code // empty')
uri=$(echo "$resp" | jq -r '.verification_uri_complete // empty')
interval=$(echo "$resp" | jq -r '.interval // 5')
expires_in=$(echo "$resp" | jq -r '.expires_in')
deadline=$(($(date +%s) + expires_in))

echo ""
echo "Open the URL below in a new tab of this browser and sign in (within 10 minutes):"
echo ""
echo "  $uri"
echo ""
# code-server's integrated terminal provides the $BROWSER helper - if present,
# open the login page in the participant's browser automatically (from SSM or
# other shells the URL must be opened manually).
if [ -n "${BROWSER:-}" ]; then
  "$BROWSER" "$uri" >/dev/null 2>&1 && echo "(opened the login page in a new browser tab)" || true
fi
printf "Waiting for login"
login_expired() {
  echo ""; echo "login failed: expired_token" >&2; exit 1
}
while true; do
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || login_expired
  delay=$interval
  [ "$delay" -le "$remaining" ] || delay=$remaining
  sleep "$delay"
  remaining=$((deadline - $(date +%s)))
  [ "$remaining" -gt 0 ] || login_expired
  request_timeout=10
  [ "$request_timeout" -le "$remaining" ] || request_timeout=$remaining
  token=$(curl -sS --connect-timeout 3 --max-time "$request_timeout" -X POST "$REALM_URL/protocol/openid-connect/token" \
    -d grant_type=urn:ietf:params:oauth:grant-type:device_code \
    -d "device_code=$device_code" -d "client_id=$CLIENT_ID")
  [ "$(date +%s)" -lt "$deadline" ] || login_expired
  err=$(echo "$token" | jq -r '.error // empty')
  if [ -z "$err" ]; then
    if ! printf '%s\n' "$token" | jq -es '
      select(length == 1) | .[0]
      | select(type == "object")
      | select(.access_token | type == "string" and length > 0)
      | select(.refresh_token | type == "string" and length > 0)
    ' >/dev/null 2>&1; then
      echo ""; echo "login failed: invalid token response" >&2; exit 1
    fi
    break
  fi
  case "$err" in
    authorization_pending) printf "." ;;
    slow_down) interval=$((interval + 5)); printf "," ;;
    *) echo ""; echo "login failed: $err" >&2; exit 1 ;;
  esac
done
echo ""
echo "$token" > "$HOME/.gateway/session.json"
chmod 600 "$HOME/.gateway/session.json"
user=$(python3 -c "import json,base64,os;p=json.load(open(os.path.expanduser('~/.gateway/session.json')))['access_token'].split('.')[1];print(json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4))).get('preferred_username','?'))" 2>/dev/null || echo "?")
echo "SSO login complete: $user"
echo "get-gateway-key.sh can now issue temporary Virtual Keys."
