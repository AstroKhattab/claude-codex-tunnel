#!/usr/bin/env python3
"""tunnel watch — show the Claude <-> Codex conversation live, as a readable chat.

Follows .tunnel/bus.jsonl (who started what, and the verdicts) and the live event
stream of every running engine (.tunnel/logs/<task>.<engine>.jsonl), and prints:

    Claude -> Codex   the brief (goal, scope, done-criteria)
    Codex             what it says, the commands it runs, the files it changes
    Codex -> Claude   the verdict and summary of its report

Usage: watch.py <state-dir> [--run <run-id>] [--from-start]
"""
import json
import os
import re
import shutil
import sys
import time

STATE = sys.argv[1]
ONLY = sys.argv[sys.argv.index("--run") + 1] if "--run" in sys.argv else None
FROM_START = "--from-start" in sys.argv or ONLY is not None
BUS = os.path.join(STATE, "bus.jsonl")

COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
def c(code, s):
    return f"\033[{code}m{s}\033[0m" if COLOR else s
DIM, BOLD = "2", "1"
ENGINE_COLOR = {"codex": "36", "claude": "33"}          # cyan, yellow
VERDICT_COLOR = {"DONE": "32", "APPROVE": "32", "REVISE": "33", "BLOCK": "31", "FAILED": "31"}
NAME = {"codex": "Codex", "claude": "Claude", "you": "You"}
OTHER = {"codex": "Claude", "claude": "Codex"}

def caller(r):
    """Who sent the brief: recorded by tunnel as 'from', else the other engine."""
    return NAME.get(r.get("from", ""), OTHER.get(r.get("agent", ""), "Orchestrator"))

def width():
    return min(shutil.get_terminal_size((100, 30)).columns, 110)

def rule(label, color):
    w = width()
    line = f"── {label} " + "─" * max(3, w - len(label) - 4)
    print(c(color, line))

def wrap(text, indent="  ", limit=None):
    text = text.rstrip()
    lines = text.splitlines() or [""]
    if limit and len(lines) > limit:
        lines = lines[:limit] + [c(DIM, f"… ({len(text.splitlines()) - limit} more lines)")]
    for l in lines:
        print(indent + l)

def section(md, name):
    m = re.search(rf"^## *{name}[^\n]*\n(.*?)(?=^## |\Z)", md, re.S | re.M | re.I)
    return m.group(1).strip() if m else ""

def show_brief(r):
    eng = r.get("agent", "?")
    col = ENGINE_COLOR.get(eng, "37")
    print()
    rule(f"{caller(r)} → {NAME.get(eng, eng)} · {r.get('title', '')}", col)
    print(c(DIM, f"  {r.get('ts', '')[11:19]} · role {r.get('role', '?')} · sandbox {r.get('sandbox', '?')}"
                 + (" · resumed" if r.get("resumed") else "")))
    root = os.path.dirname(STATE.rstrip("/"))
    path = os.path.join(root, r.get("brief", "")) if r.get("brief") else ""
    try:
        md = open(path).read()
    except Exception:
        md = ""
    for name in ("Goal", "Scope - in", "Definition of done"):
        body = section(md, name)
        if body:
            print(c(BOLD, f"  {name}:"))
            wrap(body, "    ", limit=8)

def say(eng, kind, text):
    col = ENGINE_COLOR.get(eng, "37")
    who = NAME.get(eng, eng)
    if kind == "msg":
        print(c(col, f"  {who}:"))
        wrap(text, "    ", limit=14)
    elif kind == "think":
        wrap(c(DIM, f"{who} thinks: " + text.strip().splitlines()[0][:width() - 20]), "  ")
    elif kind == "cmd":
        m = re.match(r"^\S*/(?:ba|z)?sh -l?c (['\"])(.*)\1$", text.strip(), re.S)
        if m:  # Codex wraps commands as /bin/zsh -lc '...'; show only the command
            text = m.group(2)
        lines = text.strip().splitlines() or [""]
        more = c(DIM, f"  … +{len(lines) - 3} lines") if len(lines) > 3 else ""
        print(c(col, f"  {who} runs ") + c(BOLD, "$ " + lines[0]))
        for l in lines[1:3]:
            print("      " + c(BOLD, l))
        if more:
            print("    " + more)
    elif kind == "out":
        wrap(c(DIM, text), "      ", limit=6)
    elif kind == "edit":
        print(c(col, f"  {who} edits ") + text)
    elif kind == "err":
        print(c("31", f"  {who} error: ") + text)

def render_codex(eng, ev):
    t = ev.get("type", "")
    item = ev.get("item") or {}
    it = item.get("type", "")
    if t == "item.completed":
        if it in ("agent_message", "assistant_message"):
            say(eng, "msg", item.get("text", ""))
        elif it == "reasoning":
            if item.get("text"):
                say(eng, "think", item["text"])
        elif it == "command_execution":
            code = item.get("exit_code")
            say(eng, "out", f"exit {code}" + ("\n" + item["aggregated_output"].strip() if item.get("aggregated_output") else ""))
        elif it == "file_change":
            for ch in item.get("changes", []):
                say(eng, "edit", f"{ch.get('kind', '')} {ch.get('path', '')}")
        elif it == "error":
            say(eng, "err", item.get("message", ""))
    elif t == "item.started" and it == "command_execution":
        say(eng, "cmd", item.get("command", ""))
    elif t in ("error", "turn.failed"):
        msg = ev.get("message") or (ev.get("error") or {}).get("message", "")
        say(eng, "err", str(msg)[:400])

def render_claude(eng, ev):
    t = ev.get("type")
    if t == "assistant":
        for part in (ev.get("message") or {}).get("content", []):
            if part.get("type") == "text" and part.get("text", "").strip():
                say(eng, "msg", part["text"])
            elif part.get("type") == "thinking" and part.get("thinking"):
                say(eng, "think", part["thinking"])
            elif part.get("type") == "tool_use":
                name, inp = part.get("name", ""), part.get("input") or {}
                if name == "Bash":
                    say(eng, "cmd", inp.get("command", ""))
                elif name in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
                    say(eng, "edit", inp.get("file_path", ""))
                else:
                    arg = inp.get("file_path") or inp.get("pattern") or inp.get("path") or ""
                    print(c(DIM, f"  {NAME[eng]} uses {name} {arg}"))
    elif t == "user":
        for part in (ev.get("message") or {}).get("content", []) or []:
            if isinstance(part, dict) and part.get("type") == "tool_result" and part.get("is_error"):
                content = part.get("content")
                text = content if isinstance(content, str) else json.dumps(content)[:300]
                say(eng, "out", "refused/failed: " + text[:300])

def show_end(r, start=None):
    eng = r.get("agent", "?")
    v = r.get("verdict", "?")
    col = VERDICT_COLOR.get(v, "37")
    root = os.path.dirname(STATE.rstrip("/"))
    try:
        md = open(os.path.join(root, r.get("report", ""))).read()
    except Exception:
        md = ""
    print()
    print(c(col + ";1", f"  {NAME.get(eng, eng)} → {caller(start or r)}: {v}")
          + c(DIM, f"   ({r.get('secs', 0)}s, exit {r.get('rc')})"))
    summary = section(md, "Summary")
    if summary:
        wrap(summary, "    ", limit=10)
    if r.get("asked"):
        print(c("33;1", "  ❓ question: ") + r.get("question", ""))
    if r.get("files"):
        print(c(DIM, "  files changed: " + ", ".join(r["files"][:8])))
    print(c(DIM, f"  report: {r.get('report', '')}"))

class Run:
    def __init__(self, r):
        self.r, self.pos, self.buf = r, 0, ""
        root = os.path.dirname(STATE.rstrip("/"))
        self.log = os.path.join(STATE, "logs", f"{r.get('task')}.{r.get('agent')}.jsonl")

    def pump(self):
        try:
            size = os.path.getsize(self.log)
        except OSError:
            return
        if size < self.pos:
            self.pos = 0
        if size == self.pos:
            return
        with open(self.log, "r", errors="replace") as f:
            f.seek(self.pos)
            chunk = f.read()
            self.pos = f.tell()
        self.buf += chunk
        *lines, self.buf = self.buf.split("\n")
        for line in lines:
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if self.r.get("agent") == "codex":
                render_codex("codex", ev)
            else:
                render_claude("claude", ev)

def main():
    print(c(BOLD, "Claude ⇄ Codex tunnel — live conversation") + c(DIM, f"   ({STATE})"))
    print(c(DIM, "Waiting for runs… (ctrl-c to close; runs keep going)"))
    pos = 0
    if not FROM_START and os.path.exists(BUS):
        pos = os.path.getsize(BUS)
    live = {}
    buf = ""
    while True:
        try:
            size = os.path.getsize(BUS)
        except OSError:
            size = 0
        if size > pos:
            with open(BUS, "r", errors="replace") as f:
                f.seek(pos)
                buf += f.read()
                pos = f.tell()
            *lines, buf = buf.split("\n")
            for line in lines:
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                run = r.get("run")
                if ONLY and run != ONLY:
                    continue
                ev = r.get("event")
                if ev == "start":
                    show_brief(r)
                    live[run] = Run(r)
                elif ev == "end":
                    start = None
                    if run in live:
                        live[run].pump()
                        start = live.pop(run).r
                    show_end(r, start)
                    if ONLY:
                        return
                elif ev == "say":
                    print(c(DIM, f"\n  orchestrator → {r.get('to')}: ") + r.get("text", ""))
                elif ev == "note":
                    print(c(DIM, f"\n  note: {r.get('text', '')}"))
                elif ev == "step":
                    print(c(DIM, f"\n  step {r.get('step')} → {r.get('status')} {r.get('detail', '')}"))
            sys.stdout.flush()
        for run in list(live.values()):
            run.pump()
        sys.stdout.flush()
        time.sleep(0.5)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
