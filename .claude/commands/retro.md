---
name: retro
description: USE WHEN a task or session is complete and you want a fast, role-neutral "breed vangnet" retro. One-command front door — captures a broad-net retro into the inbox (dw: manual, full aspect_scan across every AI-automation building block), lints it for completeness, and runs the release-trigger. Thin wrapper over post-task-retro for the inbox path. Cross-DW.
metadata:
  author: "ErikDaniel007"
  owner: "Gridtefy"
  ring: "4 — gdty-private agentic layer"
license: "Proprietary — Gridtefy Ring-4 (gdty-private), not for upstream donation"
---
# retro — broad-net capture front door

Thin wrapper. It does NOT re-define the retro schema — it pins the inbox defaults and chains
the deterministic checks so one command gives you a complete, counted retro.

**Delegates to:** `post-task-retro` (schema + Q1–Q6 + aspect_scan).
**Protocol SSOT:** `src/digital-org/dw/shared/context/retro-protocol.md`.

## When to use

- End of a session/task where the owning role is unclear or cross-cutting → capture now, triage later.
- Any time you want the proactive per-ABB scan without choosing a role bucket up front.

If you already know the role, write straight to `dw/{role}/self-improvement/retro/` instead (no wrapper needed).

## What it does (in order)

1. **Capture** — run `post-task-retro` with:
   - `retro_dir = src/digital-org/retro/inbox/`
   - `dw = manual`
   - `task`, `result` from your input
   - Answer Q1–Q6 and mark **every** aspect_scan block (A1–A11, B1–B5, C). Optionally add a
     non-binding `triage_hint: {role, dp}` if you sense the owner.
2. **Lint** — verify completeness (must pass):
   ```bash
   bash src/skills/post-task-retro/scripts/retro-lint.sh \
     src/digital-org/retro/inbox/retro-<YYYY-MM-DD>-<task>.md
   ```
3. **Trigger** — count signals across the inbox:
   ```bash
   bash src/skills/retro-synthesis/scripts/check-release-trigger.sh \
     src/digital-org/retro/inbox/
   ```
4. **Report** — file path + lint result + trigger verdict. If `READY`, point to the sweep/triage:
   *"Inbox at threshold — run retro-sweep, then triage into a role bucket."*

## Input

| Field | Required | Notes |
|---|---|---|
| `task` | Yes | Short description |
| `result` | Yes | `success` \| `partial` \| `failed` |
| `issues` | No | What went wrong / was surprising |

## Standing trigger — make it fire every session (gdty-apps ONLY)

Three layers, weakest→strongest enforcement. All project-scoped — never global, so they
cannot activate in a tappaas/itops session (no agentic leakage — CLAUDE.md rule 24).

1. **`/retro` slash skill** — the one-command front door (this skill). Fastest manual entry.
2. **CLAUDE.md rules 22–23** — behavioural mandate: capture a retro after any session with
   learnings; mark every aspect_scan block (lint-enforced).
3. **Stop hook** — `scripts/retro-session-check.sh`, wired in `gdty-apps/.claude/settings.json`
   (project, gitignored = local). Once per session it confirms+lints the retro you wrote, or
   nudges you if none. Non-blocking (a retro is judgment; a hook reminds, never writes it).

To wire the hook in a fresh gdty-apps checkout, add to `.claude/settings.json` (NOT `~/.claude`):
```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "bash /home/tappaas/repos/gdty-apps/src/skills/retro/scripts/retro-session-check.sh" } ] } ] } }
```

## Constraints

- **Inbox is staging, not an archive.** Triage routes each signal to a role bucket (`triage-helper.sh`);
  synthesis runs there, not on the inbox.
- **Routing stays human.** This wrapper captures and lints; it never assigns role/DP (Step 0 triage does, with HITL).
- **gdty IP, this repo only.** The Reflect/retro layer is Ring 4 agentic IP — never upstream to tappaas.
