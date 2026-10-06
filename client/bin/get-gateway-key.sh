#!/bin/bash
# LiteLLM temporary Virtual Key helper - prints only the key to stdout, exit 0.
# (Claude Code apiKeyHelper / Codex [auth] command contract)
# Returns the cached key immediately if it has 10+ minutes left (non-interactive,
# prevents key sprawl); otherwise refresh token -> new JWT -> broker (/auth/key)
# -> new temporary key.
set -euo pipefail
umask 077
. "$(dirname "$0")/../workshop.env"   # workshop: /etc/profile.d/workshop.sh
REALM_URL="$KEYCLOAK_URL/realms/workshop"
CLIENT_ID=workshop-cli
CACHE="$HOME/.gateway/virtual-key.json"
KEYFILE="$HOME/.gateway/virtual-key"   # plaintext for OpenCode {file:} reference

now=$(date +%s)
if [ -f "$CACHE" ] && key=$(jq -ers --argjson now "$now" '
  select(length == 1) | .[0]
  | select(type == "object")
  | select(.expires_epoch | type == "number")
  | select(.expires_epoch > $now + 600)
  | .key | select(type == "string" and length > 0)
  | select(test("[[:space:][:cntrl:]]") | not)
' "$CACHE" 2>/dev/null); then
  touch "$KEYFILE"
  chmod 600 "$KEYFILE"
  printf '%s\n' "$key" > "$KEYFILE"
  printf '%s\n' "$key"
  exit 0
fi

if [ ! -f "$HOME/.gateway/session.json" ]; then
  echo "no SSO session - run gateway-login.sh first" >&2; exit 1
fi
if ! refresh=$(jq -ers '
  select(length == 1) | .[0]
  | .refresh_token | select(type == "string" and length > 0)
' "$HOME/.gateway/session.json" 2>/dev/null); then
  echo "SSO session expired - run gateway-login.sh again" >&2; exit 1
fi
token=$(curl -sS --connect-timeout 2 --max-time 4 -X POST "$REALM_URL/protocol/openid-connect/token" \
  -d grant_type=refresh_token -d "client_id=$CLIENT_ID" -d "refresh_token=$refresh")
if ! token=$(printf '%s\n' "$token" | jq -ces --arg old_refresh "$refresh" '
  select(length == 1) | .[0]
  | select(type == "object")
  | select(.access_token | type == "string" and length > 0)
  | .refresh_token = (if .refresh_token == null then $old_refresh else .refresh_token end)
  | select(.refresh_token | type == "string" and length > 0)
' 2>/dev/null); then
  echo "SSO session expired - run gateway-login.sh again" >&2; exit 1
fi
access=$(printf '%s\n' "$token" | jq -r '.access_token')
# Save rotated refresh tokens, retaining the old token when rotation is omitted.
printf '%s\n' "$token" > "$HOME/.gateway/session.json" && chmod 600 "$HOME/.gateway/session.json"

resp=$(curl -sS --connect-timeout 2 --max-time 4 -X POST "$GATEWAY_URL/auth/key" -H "Authorization: Bearer $access")
if ! key=$(printf '%s\n' "$resp" | jq -ers --argjson now "$(date +%s)" '
  select(length == 1) | .[0]
  | select(type == "object")
  | select(.expires_epoch | type == "number")
  | select(.expires_epoch > $now)
  | .key | select(type == "string" and length > 0)
  | select(test("[[:space:][:cntrl:]]") | not)
' 2>/dev/null); then
  echo "temporary key issuance failed: invalid response" >&2; exit 1
fi
printf '%s\n' "$resp" > "$CACHE" && chmod 600 "$CACHE"
printf '%s\n' "$key" > "$KEYFILE" && chmod 600 "$KEYFILE"
printf '%s\n' "$key"
