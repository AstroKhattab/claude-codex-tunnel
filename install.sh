#!/usr/bin/env bash
# install.sh — set up claude-codex-tunnel for Claude Code and Codex.
#
#   ./install.sh                 install for your user (all projects)
#   ./install.sh --project DIR   install the skills into one repo instead (share via git)
#   ./install.sh --trust         also let Claude and Codex run `tunnel` without asking
#   ./install.sh --no-trust      never ask about that
#   ./install.sh --bin-dir DIR   where the `tunnel` command goes (default ~/.local/bin)
#
# Safe to run again: it updates its own files and touches nothing else.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
PROJECT=""
TRUST=""
MARK="installed by claude-codex-tunnel"

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a folder}"; shift 2 ;;
    --bin-dir) BIN_DIR="${2:?--bin-dir needs a folder}"; shift 2 ;;
    --trust) TRUST=yes; shift ;;
    --no-trust) TRUST=no; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "claude-codex-tunnel installer"

# 1. Requirements
have git || { echo "git is required" >&2; exit 1; }
have python3 || { echo "python3 is required" >&2; exit 1; }
have codex  || warn "codex CLI not found. Install it so Claude can send work to Codex: npm i -g @openai/codex"
have claude || warn "claude CLI not found. Install it so Codex can send work to Claude: npm i -g @anthropic-ai/claude-code"

# 2. The command
chmod +x "$SRC/bin/tunnel"
mkdir -p "$BIN_DIR"
ln -sf "$SRC/bin/tunnel" "$BIN_DIR/tunnel"
ok "command: $BIN_DIR/tunnel -> $SRC/bin/tunnel"

# 3. Where the skills go
if [ -n "$PROJECT" ]; then
  [ -d "$PROJECT" ] || { echo "no such folder: $PROJECT" >&2; exit 1; }
  PROJECT="$(cd "$PROJECT" && pwd)"
  CLAUDE_BASE="$PROJECT/.claude"
  CODEX_SKILLS="$PROJECT/.agents/skills"
  CLAUDE_SETTINGS="$PROJECT/.claude/settings.json"
else
  CLAUDE_BASE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  CODEX_SKILLS="$HOME/.agents/skills"
  CLAUDE_SETTINGS="$CLAUDE_BASE/settings.json"
fi
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"

# 4. Claude Code: skill + two subagents
mkdir -p "$CLAUDE_BASE/skills" "$CLAUDE_BASE/agents"
rm -rf "$CLAUDE_BASE/skills/claude-codex-tunnel"
cp -R "$SRC/claude/skills/claude-codex-tunnel" "$CLAUDE_BASE/skills/"
ok "Claude skill: $CLAUDE_BASE/skills/claude-codex-tunnel"
for a in codex-builder codex-reviewer; do
  dst="$CLAUDE_BASE/agents/$a.md"
  if [ -f "$dst" ] && ! grep -q "$MARK" "$dst"; then
    warn "kept your own $dst (not ours); skipped"
  else
    cp "$SRC/claude/agents/$a.md" "$dst"
    ok "Claude subagent: $dst"
  fi
done

# 5. Codex: skill
mkdir -p "$CODEX_SKILLS"
rm -rf "$CODEX_SKILLS/claude-codex-tunnel"
cp -R "$SRC/codex/skills/claude-codex-tunnel" "$CODEX_SKILLS/"
ok "Codex skill: $CODEX_SKILLS/claude-codex-tunnel"

# 6. Trust (optional): no permission prompt each time an agent runs `tunnel`
if [ -z "$TRUST" ]; then
  if [ -t 0 ]; then
    printf '\nLet Claude and Codex run the `tunnel` command without asking each time? [y/N] '
    read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) TRUST=yes ;; *) TRUST=no ;; esac
  else
    TRUST=no
  fi
fi
if [ "$TRUST" = yes ]; then
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, os, shutil, sys
p = sys.argv[1]
d = {}
if os.path.exists(p):
    shutil.copy(p, p + ".bak-tunnel")
    try:
        d = json.load(open(p))
    except Exception:
        sys.exit("could not read " + p + " as JSON; left it alone")
allow = d.setdefault("permissions", {}).setdefault("allow", [])
if "Bash(tunnel:*)" not in allow:
    allow.append("Bash(tunnel:*)")
json.dump(d, open(p, "w"), indent=2)
PY
  ok "Claude may run tunnel without asking ($CLAUDE_SETTINGS)"
  mkdir -p "$CODEX_HOME_DIR/rules"
  cat > "$CODEX_HOME_DIR/rules/claude-codex-tunnel.rules" <<'EOF'
# installed by claude-codex-tunnel: let Codex run `tunnel` outside its sandbox
# without asking (Claude Code needs the network and its own sign-in files).
prefix_rule(pattern=["tunnel"], decision="allow")
EOF
  ok "Codex may run tunnel without asking ($CODEX_HOME_DIR/rules/claude-codex-tunnel.rules)"
fi

# 7. PATH
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say ""
     warn "$BIN_DIR is not on your PATH. Add this line to your shell profile (~/.zshrc or ~/.bashrc):"
     say "      export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

say ""
PATH="$BIN_DIR:$PATH" "$SRC/bin/tunnel" doctor || true
say ""
say "Done. Restart Claude Code and Codex so they load the new skills, then try:"
say "  In Claude Code:  \"Ask Codex to review my last commit.\""
say "  In Codex:        \"Ask Claude to review my last commit.\""
