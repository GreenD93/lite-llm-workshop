#!/bin/bash
# "개발자 PC로 들어가기": HOME=sandbox 로 셸(또는 인자로 받은 명령)을 실행한다.
# Claude Code·Codex·OpenCode·키 캐시(~/.gateway)가 전부 sandbox 안의 것을 쓰므로 실제 홈 설정과 섞이지 않는다.
#   client/dev-shell.sh                  대화형 셸
#   client/dev-shell.sh claude -p "hi"   명령 하나만 실행
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV_HOME="${DEV_HOME:-$ROOT/sandbox}"   # 테스트는 임시 디렉터리로 바꿔 쓴다
[ -f "$DEV_HOME/workshop.env" ] || { echo "run client/install.sh first" >&2; exit 1; }

export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"   # pyenv shim은 $HOME 기준이라 실제 위치를 고정
export HOME="$DEV_HOME" PATH="$DEV_HOME/bin:$PATH"
# 게이트웨이를 우회하는 자격증명이 환경에 남아 있지 않게 한다 (모듈 4-5 "자격증명 계층").
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY CLAUDE_CONFIG_DIR CODEX_HOME
cd "$DEV_HOME/project"

if [ $# -eq 0 ]; then
  export PS1='[dev-sandbox] \w $ '
  exec bash --norc --noprofile -i
fi
exec "$@"
