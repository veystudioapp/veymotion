#!/bin/bash
# Opens VeyMotion in one of the chat setup situations, without touching your real Claude/Codex logins.
#
#   bash scripts/test-agent-setup.sh <case>
#
# Cases:
#   claude-missing     Claude Code not installed           (VEYMOTION_CLAUDE=none)
#   codex-missing      Codex CLI not installed              (VEYMOTION_CODEX=none)
#   both-missing       neither installed
#   claude-logged-out  Claude Code installed, nobody logged in (empty CLAUDE_CONFIG_DIR)
#   codex-logged-out   Codex installed, nobody logged in        (empty CODEX_HOME)
#   claude-bad-key     a refused API key at send time        (ANTHROPIC_API_KEY=invalid)
#   claude-credit      fake claude: "Credit balance is too low"
#   claude-limit       fake claude: usage limit reached
#   claude-expired     fake claude: OAuth token has expired
#   codex-quota        fake codex: quota exceeded
#   codex-auth         fake codex: 401 Unauthorized
#
# The empty config folders live under $TMPDIR/veymotion-setup-test (removed with `clean`).
set -euo pipefail

cd "$(dirname "$0")/.."
CASE="${1:-}"
ROOT="${TMPDIR:-/tmp}/veymotion-setup-test"
[ "$CASE" = clean ] && { rm -rf "$ROOT"; echo "Removed $ROOT"; exit 0; }
[ -z "$CASE" ] && { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

mkdir -p "$ROOT"
FAKE="$ROOT/bin"
mkdir -p "$FAKE"

# A logged-in `claude` whose every message fails with $FAKE_ERROR (stream-json, like `claude -p`).
cat > "$FAKE/claude" <<'EOF'
#!/bin/sh
if [ "$1" = auth ]; then echo '{"loggedIn": true}'; exit 0; fi
while IFS= read -r line; do
  case "$line" in *control_request*) continue ;; esac
  printf '{"type":"system","subtype":"init","session_id":"fake-session"}\n'
  printf '{"type":"result","subtype":"success","is_error":true,"result":"%s","session_id":"fake-session"}\n' "$FAKE_ERROR"
done
EOF

# A logged-in `codex` whose every `exec` fails with $FAKE_ERROR (`codex exec --json` events).
cat > "$FAKE/codex" <<'EOF'
#!/bin/sh
case "$1" in
  login) echo "Logged in using ChatGPT"; exit 0 ;;
  debug) echo '{"models":[]}'; exit 0 ;;
esac
cat > /dev/null # the prompt comes on stdin
printf '{"type":"thread.started","thread_id":"fake-thread"}\n{"type":"turn.started"}\n'
printf '{"type":"error","message":"%s"}\n' "$FAKE_ERROR"
printf '{"type":"turn.failed","error":{"message":"%s"}}\n' "$FAKE_ERROR"
exit 1
EOF
chmod +x "$FAKE/claude" "$FAKE/codex"

ENV=()
case "$CASE" in
  claude-missing)    ENV=(VEYMOTION_CLAUDE=none) ;;
  codex-missing)     ENV=(VEYMOTION_CODEX=none) ;;
  both-missing)      ENV=(VEYMOTION_CLAUDE=none VEYMOTION_CODEX=none) ;;
  claude-logged-out) mkdir -p "$ROOT/claude-config"; ENV=(CLAUDE_CONFIG_DIR="$ROOT/claude-config") ;;
  codex-logged-out)  mkdir -p "$ROOT/codex-home"; ENV=(CODEX_HOME="$ROOT/codex-home") ;;
  claude-bad-key)    ENV=(ANTHROPIC_API_KEY=sk-ant-api03-invalid-key-for-testing) ;;
  claude-credit)     ENV=(VEYMOTION_CLAUDE="$FAKE/claude" "FAKE_ERROR=Credit balance is too low") ;;
  claude-limit)      ENV=(VEYMOTION_CLAUDE="$FAKE/claude" "FAKE_ERROR=Claude AI usage limit reached|1767225600") ;;
  claude-expired)    ENV=(VEYMOTION_CLAUDE="$FAKE/claude" "FAKE_ERROR=OAuth token has expired. Please obtain a new token or refresh your existing token.") ;;
  codex-quota)       ENV=(VEYMOTION_CODEX="$FAKE/codex" "FAKE_ERROR=You exceeded your current quota, please check your plan and billing details.") ;;
  codex-auth)        ENV=(VEYMOTION_CODEX="$FAKE/codex" "FAKE_ERROR=unexpected status 401 Unauthorized: Missing bearer or basic authentication in header") ;;
  *) echo "Unknown case: $CASE (run without arguments for the list)"; exit 1 ;;
esac

swift build
echo "Starting VeyMotion with: ${ENV[*]}"
exec env "${ENV[@]}" .build/debug/VeyMotion
