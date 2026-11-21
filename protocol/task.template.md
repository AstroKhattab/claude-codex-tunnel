---
id: <ID>
to: <TO>                  # codex | claude
role: <ROLE>              # implement | review | test | research
sandbox: <SANDBOX>        # workspace-write (may edit) | read-only (may not edit)
depends_on: none          # comma-separated task ids that must be DONE/APPROVE first
allow:                    # Claude workers only: extra tools, e.g. Bash(npm test:*)
title: <TITLE>
---

## Goal
<One sentence. What must be true when this is finished.>

## Context
<Every fact the agent needs: repro steps, exact error output, decisions already
made, shared interface shapes, why the obvious approach was rejected. Assume zero
prior knowledge. This brief is the only channel.>

## Scope - in
- path/to/file

## Scope - out
- <anything forbidden: other modules, migrations, auth, payments...>

## Constraints
- Smallest correct diff. No drive-by refactors.
- No new dependencies unless this brief says so.

## Definition of done (objective; the reviewer checks these)
1. <criterion>
2. <the original problem no longer reproduces>
3. <one neighbouring feature on the same path still works>

## Prior art
- Previous report: none
- Iteration: 1 of 3
