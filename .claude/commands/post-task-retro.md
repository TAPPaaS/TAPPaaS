---
name: post-task-retro
description: "USE WHEN any task or sweep is complete. Writes a structured self-reflection (Reflexion Q1–Q6 + AI-automation aspect scan) to the specified retro_dir. Works at DW role level (dw/{role}/retro/) or any broader scope (digital-org/retro/, pack/retro/, etc.). Generic — not TAPPaaS-specific."
metadata:
  author: "ErikDaniel007"
  owner: "Gridtefy"
  ring: "4 — gdty-private agentic layer"
license: "Proprietary — Gridtefy Ring-4 (gdty-private), not for upstream donation"
---
# Post-Task Retro

## Overview

Writes a structured self-reflection file after any task or sweep.
Works standalone — no DW agent required. Invoke in any Claude Code session.

**Protocol spec:** `gdty-apps/src/digital-org/dw/shared/context/retro-protocol.md`
**Format:** See retro-protocol.md — it is the single source of truth. Do not duplicate the schema here.

---

## When to invoke

After ANY of:
- A DW task completed (module build, commission, deploy)
- An architectural sweep or audit
- A manual session with learnings worth capturing
- Any scope where a Q1–Q5 reflection adds value

---

## Input

| Field | Required | Notes |
|---|---|---|
| `task` | Yes | Short task or sweep description |
| `retro_dir` | Yes | Where to write. Default for DW tasks: `gdty-apps/src/digital-org/dw/{role}/retro/`. For org-level: `gdty-apps/src/digital-org/retro/`. |
| `scope` | No | `dw/{role}` \| `digital-org` \| `pack/{name}` \| `manual`. Used for context only. |
| `result` | Yes | `success` \| `partial` \| `failed` |
| `issues` | Optional | What went wrong or was surprising |
| `commission_ref` | Optional | Path to commission YAML if one was used |
| `duration` | Optional | Rough time spent |

---

## Process

1. Read `retro-protocol.md` — that file defines the format. Use it, don't reproduce it.
2. Answer Q1–Q6 honestly for the given task and scope, then mark EVERY block in the `aspect_scan`
   (improve-existing | add-new | none). Q6 + aspect_scan are the PROACTIVE capability pass — complete
   them even when Q1–Q4 are "none". The scan is a checklist (one line per block), not an essay.
3. Write retro to: `{retro_dir}/retro-<YYYY-MM-DD>-<task>.md`
4. Lint the retro for completeness (deterministic — zero LLM). It MUST pass before the retro counts:
```bash
bash gdty-apps/src/skills/post-task-retro/scripts/retro-lint.sh \
  {retro_dir}/retro-<YYYY-MM-DD>-<task>.md
```
Exit 1 = incomplete → fix the listed blocks (every aspect_scan ABB marked + Q6 answered), then re-lint.
5. Run release trigger check (deterministic — zero LLM tokens):
```bash
bash gdty-apps/src/skills/retro-synthesis/scripts/check-release-trigger.sh \
  {retro_dir}
```
6. Report: file path written + lint result + trigger output.
   If `RELEASE_TRIGGER: YES` → "Threshold reached. Run retro-synthesis with retro_dir={retro_dir}."

---

## Standalone invocation

```
Read:
  gdty-apps/src/digital-org/dw/shared/context/retro-protocol.md
  gdty-apps/src/skills/post-task-retro/SKILL.md

Input:
  task:      <description>
  retro_dir: <path>          # e.g. gdty-apps/src/digital-org/retro/
  scope:     <optional>
  result:    <success|partial|failed>
```
