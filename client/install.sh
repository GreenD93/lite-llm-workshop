#!/bin/bash
# 개발자 PC 프로비저닝 재현 (워크샵에서는 code-server EC2에 미리 깔려 있던 것들).
# sandbox/ 를 "개발자의 $HOME"으로 만들고 헬퍼 스크립트·툴 설정을 배치한다. 여러 번 실행해도 안전하다.
#   sandbox/workshop.env              ← /etc/profile.d/workshop.sh
#   sandbox/bin/*.sh                  ← /home/ec2-user/bin/*.sh
#   sandbox/.claude/settings.json     ← Claude Code
#   sandbox/.codex/config.toml        ← Codex
#   sandbox/.config/opencode/opencode.json ← OpenCode
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV_HOME="${DEV_HOME:-$ROOT/sandbox}"   # 테스트는 임시 디렉터리로 바꿔 쓴다
[ -f "$ROOT/.env" ] || { echo ".env not found - cp .env.example .env" >&2; exit 1; }
# 개발자 PC에는 공개 URL만 내려간다. master key 같은 서버 비밀값은 넘기지 않는다.
eval "$(grep -E '^(GATEWAY_URL|KEYCLOAK_URL)=' "$ROOT/.env")"
BROWSER_CMD=$(command -v open || command -v xdg-open || true)

mkdir -p "$DEV_HOME"/{bin,project,.claude,.codex,.config/opencode}
cat > "$DEV_HOME/workshop.env" <<ENV
KEYCLOAK_URL=$KEYCLOAK_URL
GATEWAY_URL=$GATEWAY_URL
BROWSER=\${BROWSER-$BROWSER_CMD}
ENV
install -m 755 "$ROOT/client/bin/gateway-login.sh" "$ROOT/client/bin/get-gateway-key.sh" "$DEV_HOME/bin/"

render() {
  sed -e "s|__GATEWAY_URL__|$GATEWAY_URL|g" -e "s|__DEV_HOME__|$DEV_HOME|g" "$ROOT/client/templates/$1" > "$DEV_HOME/$2"
}
render claude-settings.json .claude/settings.json
render codex-config.toml    .codex/config.toml
render opencode.json        .config/opencode/opencode.json

echo "installed developer environment at $DEV_HOME"
echo "next: client/dev-shell.sh  →  gateway-login.sh"
