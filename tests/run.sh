#!/usr/bin/env bash
# tests/run.sh — offline end-to-end tests. Uses fake `codex` and `claude` programs,
# so it needs no account, no network and no API credit. Runs in a throwaway HOME.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/tunnel-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CODEX_HOME="$T/home/.codex" TUNNEL_NOTIFY=0
unset CLAUDE_CONFIG_DIR TUNNEL_DIR TUNNEL_DEPTH TUNNEL_ENGINE CLAUDECODE
for v in $(env | sed -n 's/^\(CODEX_[A-Za-z0-9_]*\)=.*/\1/p'); do [ "$v" = CODEX_HOME ] || unset "$v"; done
mkdir -p "$HOME" "$T/fakebin"
export PATH="$T/fakebin:$HOME/.local/bin:$PATH"

pass=0; fail=0
# Every check has a time limit, so a bug shows up as a failure, never a hang.
tmo() { perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or exit 127' "$@"; }
check() { # check <name> <command...>
  local name="$1"; shift
  if tmo "${CHECK_TIMEOUT:-60}" "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "  ✓ $name"
  else fail=$((fail+1)); echo "  ✗ $name"; fi
}

# Fake codex: records its args, writes a report to -o, prints a JSONL thread event.
cat > "$T/fakebin/codex" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "codex-cli 0.0.0-fake"; exit 0; }
[ "$1" = "login" ] && exit 0
printf '%s\n' "$*" >> "$FAKE_LOG"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
prompt="$(cat)"
echo '{"type":"thread.started","thread_id":"11111111-2222-3333-4444-555555555555"}'
case "$prompt" in *"MAKE-IT-FAIL"*) echo "boom" >&2; exit 3 ;; esac
case "$prompt" in *"EDIT-A-FILE"*) echo "changed" > "$PWD/edited.txt" ;; esac
verdict=DONE; case "$prompt" in *"role: review"*) verdict=APPROVE ;; esac
q="none"; case "$prompt" in *"ASK-A-QUESTION"*) q="- Which database should I use?" ;; esac
printf '## Verdict: %s\n\n## Summary\nfake codex did it\n\n## Open questions\n%s\n' "$verdict" "$q" > "$out"
EOF
# Fake claude: records args, prints the -p stream-json event shape.
cat > "$T/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "0.0.0 (Fake Claude)"; exit 0; }
printf '%s\n' "$*" >> "$FAKE_LOG"
cat >/dev/null
python3 - <<'PYEOF'
import json
sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
print(json.dumps({"type": "system", "subtype": "init", "session_id": sid}))
print(json.dumps({"type": "assistant", "session_id": sid, "message": {"content": [
    {"type": "text", "text": "Looking at the code now."},
    {"type": "tool_use", "name": "Bash", "input": {"command": "git diff"}}]}}))
print(json.dumps({"type": "result", "subtype": "success", "session_id": sid,
    "result": "## Verdict: DONE\n\n## Summary\nfake claude did it\n\n## Open questions\nnone\n"}))
PYEOF
EOF
chmod +x "$T/fakebin/codex" "$T/fakebin/claude"
export FAKE_LOG="$T/calls.log"

echo "install"
check "install.sh runs" "$SRC/install.sh" --no-trust
check "tunnel command linked" test -x "$HOME/.local/bin/tunnel"
check "Claude skill installed" test -f "$HOME/.claude/skills/claude-codex-tunnel/SKILL.md"
check "Claude subagents installed" test -f "$HOME/.claude/agents/codex-reviewer.md"
check "Codex skill installed" test -f "$HOME/.agents/skills/claude-codex-tunnel/SKILL.md"
check "doctor passes" tunnel doctor
check "install again is safe" "$SRC/install.sh" --no-trust
check "trust adds Claude permission" sh -c "'$SRC/install.sh' --trust && grep -q 'Bash(tunnel:\*)' '$HOME/.claude/settings.json'"
check "trust adds Codex rule" test -f "$CODEX_HOME/rules/claude-codex-tunnel.rules"

# A throwaway project
P="$T/proj"; mkdir -p "$P"; cd "$P" && git init -q && git commit -q --allow-empty -m init

echo "briefs and runs"
B="$(tunnel new fix-login --to codex --role implement)"
check "new writes a brief" test -f "$B"
check "brief has engine" grep -q '^to: codex' "$B"
check "state dir ignored by git" sh -c "git status --porcelain | grep -vq '.tunnel' || true; test -f .tunnel/.gitignore"
printf '\n## Goal\nEDIT-A-FILE please\n' >> "$B"
check "codex run succeeds" tunnel codex "$B"
ID="$(basename "$B" .task.md)"
check "codex report saved" grep -q 'Verdict: DONE' ".tunnel/reports/$ID.codex.report.md"
check "codex got writing sandbox" grep -q -- '--sandbox workspace-write' "$FAKE_LOG"
check "codex prompt sent on stdin (no prompt arg)" sh -c "tail -1 '$FAKE_LOG' | grep -q -- ' -\$'"
check "thread id saved for resume" grep -q 11111111 ".tunnel/threads/$ID.codex"
check "files touched measured" grep -q 'edited.txt' .tunnel/bus.jsonl
check "run recorded start+end" sh -c "grep -c '\"run\"' .tunnel/bus.jsonl | grep -q 2"

R="$(tunnel new check-login --to codex --role review)"
check "review brief is read-only" grep -q '^sandbox: read-only' "$R"
tunnel codex "$R" >/dev/null 2>&1
check "review runs read-only" sh -c "tail -1 '$FAKE_LOG' | grep -q -- '--sandbox read-only'"
check "review verdict APPROVE" grep -q 'APPROVE' ".tunnel/reports/$(basename "$R" .task.md).codex.report.md"

check "resume uses codex exec resume" sh -c "tunnel codex '$B' --resume 11111111-2222-3333-4444-555555555555 && tail -1 '$FAKE_LOG' | grep -q '^exec resume 11111111'"

C="$(tunnel new explain-auth --to claude --role research)"
check "claude run succeeds (called from Codex)" env CODEX_THREAD_ID=test tunnel claude "$C"
check "caller recorded as codex" sh -c "grep '\"agent\": \"claude\"' .tunnel/bus.jsonl | grep -q '\"from\": \"codex\"'"
check "a person running it is recorded as you" sh -c "grep '\"event\": \"start\"' .tunnel/bus.jsonl | head -1 | grep -q '\"from\": \"you\"'"
check "claude report saved" grep -q 'fake claude did it' ".tunnel/reports/$(basename "$C" .task.md).claude.report.md"
check "claude research is read-only" sh -c "tail -1 '$FAKE_LOG' | grep -q 'disallowedTools Edit,Write'"
check "claude session saved" grep -q aaaaaaaa ".tunnel/threads/$(basename "$C" .task.md).claude"
W="$(tunnel new add-test --to claude)"
tunnel run "$W" >/dev/null 2>&1
check "run reads engine from brief" sh -c "tail -1 '$FAKE_LOG' | grep -q 'permission-mode acceptEdits'"

F="$(tunnel new broken --to codex)"; printf '\nMAKE-IT-FAIL\n' >> "$F"
tunnel codex "$F" >/dev/null 2>&1; rc=$?
check "failed run returns engine exit code" test "$rc" = 3
check "failed run writes FAILED report" grep -q 'Verdict: FAILED' ".tunnel/reports/$(basename "$F" .task.md).codex.report.md"

Q="$(tunnel new needs-answer --to codex)"; printf '\nASK-A-QUESTION\n' >> "$Q"
tunnel codex "$Q" >/dev/null 2>&1
check "open question flagged" sh -c "tail -1 .tunnel/bus.jsonl | grep -q '\"asked\": true'"

echo "detach, wait, nesting"
D="$(tunnel new background --to codex)"
RID="$(tunnel codex "$D" --detach | sed -n 's/^run: //p')"
check "detach prints a run id" test -n "$RID"
check "wait returns the report" sh -c "tunnel wait '$RID' --timeout 30 | grep -q 'Verdict: DONE'"
check "depth guard refuses deep nesting" sh -c "! TUNNEL_DEPTH=2 tunnel codex '$D'"

echo "conversation view, allow"
CRID="$(python3 -c 'import json; print([json.loads(l)["run"] for l in open(".tunnel/bus.jsonl") if json.loads(l).get("event")=="end" and json.loads(l).get("agent")=="claude"][0])')"
WOUT="$(tunnel watch --run "$CRID" 2>&1)"
check "watch shows the brief going out" sh -c "printf '%s' \"\$1\" | grep -q 'Codex → Claude'" _ "$WOUT"
check "watch shows Claude's message and command" sh -c "printf '%s' \"\$1\" | grep -q 'git diff'" _ "$WOUT"
check "watch shows the verdict coming back" sh -c "printf '%s' \"\$1\" | grep -q 'Claude → Codex: DONE'" _ "$WOUT"
AL="$(tunnel new with-tests --to claude)"
sed -i.bak 's/^allow:.*/allow: Bash(npm test:*)/' "$AL"
tunnel claude "$AL" >/dev/null 2>&1
check "brief allow: reaches Claude" sh -c "tail -1 '$FAKE_LOG' | grep -q 'Bash(npm test:'"
check "stream-json used for Claude" sh -c "tail -1 '$FAKE_LOG' | grep -q 'stream-json'"

echo "dispatch, flow, status"
A1="$(tunnel new step-one --to codex)"
A2="$(tunnel new step-two --to codex)"
sed -i.bak "s/^depends_on: none/depends_on: $(basename "$A1" .task.md)/" "$A2"
check "dispatch dry-run plans 2 waves" sh -c "tunnel dispatch --dry-run '$A2' '$A1' | grep 'wave 2' >/dev/null"
if [ -n "${CI:-}" ] && ! tmo 20 tunnel dispatch --dry-run "$A2" "$A1" >/dev/null 2>&1; then
  echo "---- trace (CI debug) ----"; bash --version | head -1; command -v bash
  tmo 10 bash -x "$(command -v tunnel)" dispatch --dry-run "$A2" "$A1" 2>&1 | head -120
fi
check "dispatch runs in order" tunnel dispatch "$A2" "$A1"
check "flow init" tunnel flow init "Demo" s1:"Plan" s2:"Build"
check "flow step" tunnel flow step s1 done "planned"
check "flow status" sh -c "tunnel flow status | grep -q Plan"
check "status lists runs" sh -c "tunnel status | grep -q DONE"

echo "uninstall"
check "uninstall.sh runs" "$SRC/uninstall.sh"
check "skills removed" test ! -e "$HOME/.claude/skills/claude-codex-tunnel"
check "permission removed" sh -c "! grep -q 'Bash(tunnel' '$HOME/.claude/settings.json'"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
