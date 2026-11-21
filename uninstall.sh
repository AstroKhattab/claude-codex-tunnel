#!/usr/bin/env bash
# uninstall.sh — remove what install.sh added. Your projects' .tunnel/ folders
# (briefs, reports, logs) are left alone.
#
#   ./uninstall.sh [--project DIR] [--bin-dir DIR]
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
PROJECT=""
MARK="installed by claude-codex-tunnel"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$(cd "${2:?}" && pwd)"; shift 2 ;;
    --bin-dir) BIN_DIR="${2:?}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$PROJECT" ]; then
  CLAUDE_BASE="$PROJECT/.claude"; CODEX_SKILLS="$PROJECT/.agents/skills"
else
  CLAUDE_BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; CODEX_SKILLS="$HOME/.agents/skills"
fi

if [ -L "$BIN_DIR/tunnel" ] && [ "$(readlink "$BIN_DIR/tunnel")" = "$SRC/bin/tunnel" ]; then
  rm "$BIN_DIR/tunnel"; echo "  - $BIN_DIR/tunnel"
fi
rm -rf "$CLAUDE_BASE/skills/claude-codex-tunnel" "$CODEX_SKILLS/claude-codex-tunnel"
echo "  - skills"
for a in codex-builder codex-reviewer; do
  f="$CLAUDE_BASE/agents/$a.md"
  if [ -f "$f" ] && grep -q "$MARK" "$f"; then rm "$f"; echo "  - $f"; fi
done
rm -f "${CODEX_HOME:-$HOME/.codex}/rules/claude-codex-tunnel.rules"
python3 - "$CLAUDE_BASE/settings.json" <<'PY'
import json, os, sys
p = sys.argv[1]
if os.path.exists(p):
    try:
        d = json.load(open(p))
        allow = d.get("permissions", {}).get("allow", [])
        if "Bash(tunnel:*)" in allow:
            allow.remove("Bash(tunnel:*)")
            json.dump(d, open(p, "w"), indent=2)
            print("  - Bash(tunnel:*) permission")
    except Exception:
        pass
PY
echo "uninstalled."
