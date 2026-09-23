# Release train promotion — the boundary, as a script

How the two-week boundary of [ADR-028](../ADR/ADR-028%20-%20Release%20Cadence%20and%20Patching.md)
D9 is actually performed: one command the operator runs on the test site's mothership, what it
checks before it touches anything, and what it refuses to do.

| | |
|---|---|
| **Status** | Design — not implemented |
| **Owner** | `tappaas-cicd` |
| **Decides** | ADR-028 D9 (the train), D2 (the beat), D10 (the control plane's net) |
| **Date** | 2026-09-23 |

---

## The shape of the thing

The instinct is "a script that promotes". The honest shape is different, and getting it wrong
is how release scripts become dangerous:

> **A boundary is not one run. It is two runs, two weeks apart, joined by recorded state.**

The first sitting moves the pin, proves it here, and promotes both channels. Then a fortnight
passes while staging soaks under real use — that is the *point* of staging, and no script can
compress it. The next boundary's preflight is what finally judges the soak: it refuses to
promote if staging found a fault that is not yet resolved.

So the state file is not bookkeeping around the script. It **is** the script's memory, and the
only thing that makes "did staging survive?" answerable two weeks later.

## Where it lives

`src/foundation/tappaas-cicd/scripts/tappaas-train.sh`, linked into `~/bin` like the other
mothership scripts.

**Not** `site-manager repository release` — that verb already exists and means "release a pull
*hold*" (#653). Overloading it would make two unrelated operations share a name in the one place
an operator reaches for under time pressure.

It runs on the **unstable** site's mothership (the test site) and refuses to run anywhere else:
the train is a project-wide action driven from where development is proven, and running it from
a production site would promote code that site has never tested.

## Commands

```
tappaas-train status                     where each channel points, what is due, what blocks
tappaas-train init                       one-time: create staging and stable from main
tappaas-train boundary [--dry-run]       the boundary: phases 1-6 below
tappaas-train boundary --resume          continue from the last phase that passed
tappaas-train fault <text>               record a staging fault; blocks the next promotion
tappaas-train fault --resolved <commit>  clear it, naming the fix that must be on main
```

`--dry-run` stops after preflight and prints the plan: the pin move it would make, the four
pushes it would do, and the two sites it would touch.

## Phase 0 — preflight, and the refusals that matter

Every one of these is a refusal, not a warning. A release script that warns and proceeds is a
release script nobody reads the output of.

| Check | Why it refuses |
|---|---|
| this site's channel is `unstable` | a production site promoting its own untested code is the failure this train exists to prevent |
| working tree clean; `main` == `origin/main` after fetch | promoting a tree nobody can reproduce |
| `git push --dry-run` authenticates | find out now, not after the pin has moved |
| no sweep active here **or** on the staging site | a sweep mid-flight is reading the branch this is about to move |
| both sites' `last-update-result.json` is `ok` | never promote on top of an estate that is already failing — the new pin would be blamed for it |
| **no unresolved staging fault recorded** | ADR-028 D9's rule; see below |
| `staging` and `stable` exist and are ancestors of `main` | the train is fast-forward-only; if they have diverged, something pushed sideways and a human must look |
| the soak is complete (≥ the boundary interval since the last promotion) | promoting early silently converts staging from a soak into a formality; `--force-boundary` overrides, and says so in the record |

## Phases 1–6

**1 — Branch and move the pin.** `pin/<yyyy>-w<ww>` from `main`; `nix flake update` on the
estate pin. Reports old → new revision with both dates and the age delta. If the lock does not
move — a frozen branch, or an already-current one — it stops and says so rather than making an
empty commit; `--allow-no-pin-change` continues for a feature-only boundary.

**2 — Prove it here, guest first.** ADR-028 D9's rule, and the order is the point: one
representative NixOS guest is updated against the new pin *before* the mothership takes it, so a
bad revision is caught by a machine that can be rolled back (`update-module.sh` snapshots) rather
than by the machine that would have to fix it. Then the full sweep, then `site-manager test
--deep`. Any failure stops the boundary with the branch intact and the fault recorded.

**3 — Land on `main`.** Fast-forward `main` to the branch, push, point this site back at `main`.

**4 — `staging` → `stable`.** Fast-forward only. This promotes the revision that has been
soaking for a fortnight — *not* the one just built.

**5 — `main` → `staging`.** Fast-forward only. The new revision starts its soak.

Steps 4 and 5 are in this order deliberately: the old staging content reaches production before
the new content reaches staging, so at no moment does a revision sit in production that has not
soaked.

**6 — Verify staging on the staging site.** Trigger `site-manager update` there, read its result,
run its tests. A failure here does not undo anything — see the rule below — it records a fault
and blocks the *next* promotion.

## The rule for a fault found in staging (ADR-028 D9)

**Patch forward. Nothing moves backwards.**

- **Promotion to production is blocked** until the fault is resolved. The next boundary's
  preflight refuses, naming the recorded fault. Staging keeps the revision; production keeps what
  it has.
- **The resolution lands on `main`** — wherever it was authored. If it was hotfixed on `staging`,
  it is back-ported to `main` before the block lifts, because the next boundary promotes `main`
  into `staging` and would otherwise reintroduce exactly the fault just fixed.
- **`tappaas-train fault --resolved <commit>`** requires the commit to be an ancestor of `main`.
  That is the check that makes "back-ported" a fact rather than an intention.
- Neither `staging` nor `stable` is ever rewound. §10.2 rule 5 already says `stable` never moves
  backwards; this extends the same promise to `staging`, because a channel that can be rewound is
  not a channel anyone can trust.

A blocked train is a normal state, not an incident: it means staging did its job.

## State

`config/release-train.json` on the unstable site's mothership:

```json
{
  "lastBoundary": "2026-09-23",
  "pin": { "from": "b77b3de8…", "to": "…", "movedAt": "2026-09-23T09:12:00Z" },
  "channels": { "unstable": "…", "staging": "…", "production": "…" },
  "phasesPassed": ["preflight", "pin", "test-here", "main", "stable", "staging"],
  "soakEnds": "2026-10-07",
  "fault": null
}
```

Backed up with the rest of `config/` (it is small, and losing it means losing the answer to "has
staging soaked?"). A `fault` object carries what was seen, where, and the commit that resolved it.

## What must exist first

These are prerequisites, not nice-to-haves. The script cannot be written honestly without them:

1. **A channel per site.** Today `site.json` records only a tracked *branch*, and **both sites
   track `main`** — so there is no staging audience and no production audience. ADR-028 open
   question 2 asks for a channel field; this script needs it, both to know where it may run and
   to know which site to verify in phase 6.
2. **The `staging` and `stable` branches.** Neither exists yet; `tappaas-train init` creates them
   from `main` and is the only command allowed to create a channel ref.
3. **D10's self-check** (#713), so phase 2's sweep cannot leave the test site's control plane
   broken and unnoticed half way through a boundary.
4. **A push credential on the mothership.** Verified present on the test site — `git push
   --dry-run` authenticates. Worth stating plainly: this machine can move `stable`, so the
   fast-forward-only checks are a safety property, not a formality.

## Deliberately not in scope

- **Rolling anything back.** Patch forward is the whole rule.
- **Choosing the nixpkgs branch.** A version move (`flake.nix`) is an operator decision taken in
  phase 1 with `--to <branch>`; the script never picks a branch on its own.
- **Deciding the boundary date.** The interval is policy (ADR-028 D2); the script only checks it
  has elapsed.
