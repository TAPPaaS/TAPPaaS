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
| `stable` ⊆ `staging` ⊆ `main` (each an ancestor of the one above) | the train is fast-forward-only; if they have diverged, something was pushed sideways into a channel and a human must look |
| no site is pointed at a channel **behind the commit it already runs** | switching a live site to an older ref silently removes code it depends on. The migration floor does not catch this: a pure code difference changes no migration number (observed while putting makerfloss on `staging`, 2026-09-23) |
| the soak is complete (≥ the boundary interval since the last promotion) | promoting early silently converts staging from a soak into a formality; `--force-boundary` overrides, and says so in the record |

## Phases 1–6

**1 — Branch and move the pin.** `pin/<yyyy>-w<ww>` from `main`; `nix flake update` in
`src/foundation/templates`, then again in `src/foundation/tappaas-cicd`, and the two resolved
revisions are compared. `follows` (ADR-028 D1) decides where the mothership *looks*, not what its
own lock *holds* — measured on hrossen 2026-09-23: templates moved to `nixos-26.05` and the
mothership's flake still resolved the May revision until it was re-locked. Each update resolves
the ref independently, so if the branch tip moves between them the phase refuses rather than
leave the control plane on a different revision from every guest. Note the branch must be a real git
checkout: the relative path input resolves against the git tree, so a `tar`-made copy cannot
build the mothership's flake at all. Reports old → new revision with both dates and the age delta. If the lock does not
move — a frozen branch, or an already-current one — it stops and says so rather than making an
empty commit, and points at `--to`.

A **version move** — the nixpkgs release branch itself, `nixos-25.11 → nixos-26.05` — is the same
phase with one extra step: `--to <nixos-XX.YY>` rewrites `inputs.nixpkgs.url` in
`src/foundation/templates/flake.nix` *before* the update, so the lock is re-resolved against the
new branch. Only that one file carries a ref (D1: the mothership follows it), and both files go
into the pin commit — a lock whose rev came from a ref nobody committed is a pin nobody else can
reproduce. This is the only way past a frozen branch: `nixos-25.11`'s last commit is 2026-06-30,
so no refresh within it will ever produce `nextcloud34` (#709). The script refuses to guess the
branch; `--to` is always the operator's word. If any step fails, the branch is deleted and the
two files restored — the next run's preflight refuses a dirty checkout, so a half-moved pin left
behind would be sticky.

**2 — Point the site at the pin branch, then prove it here, guest first.**

The declaration comes first, and it is not a formality. The sweep in this phase refreshes the
control plane, and that reconciles the checkout to the branch **`site.json` declares** — so a
checkout merely *parked* on the pin branch is reset back to `main` part-way through, and every
module after the first guest is rebuilt against the **old** revision while the run reports
progress. Measured on hrossen, 2026-09-23: the guest-first step ran on `nixos-26.05`, the sweep
behind it silently did not. Phase 1 therefore publishes the pin branch (the site can only track
what the forge has, and it republishes with a lease, because a boundary blocked in phase 2 leaves
that branch behind and a retry in the same week cuts the same name from a moved `main`), phase 2
declares it with `site-manager repository modify`, and after the
sweep the phase re-checks which branch the checkout is on — a sweep that moved it stops the
boundary rather than deep-testing the old revision and calling it proof. Every exit from this
phase restores the declaration to `main`, because a site left tracking a pin branch would take
its next scheduled sweep from a branch nobody maintains.

ADR-028 D9's rule, and the order is the point: one
representative NixOS guest is updated against the new pin *before* the mothership takes it, so a
bad revision is caught by a machine that can be rolled back (`update-module.sh` snapshots) rather
than by the machine that would have to fix it. Then the full sweep, then `site-manager test
--deep`. Any failure stops the boundary with the branch intact and the fault recorded.

**A version move ends this phase in a reboot.** Across a nixpkgs release the mothership cannot be
switched in place — `dbus-broker` will not reload, the switch reports failure over it, and the
rollback live-locks (#725, ADR-028 D8). The sweep therefore stages the new generation with
`nixos-rebuild boot` and reboots into it, which kills the boundary along with everything else on
the machine. That is expected: phases are recorded, so the run resumes with `--resume` once the
mothership is back, and picks up at the deep test. A patch refresh within one release still
switches in place and does not reboot.

**Relink before testing.** `~tappaas/bin/<manager>` is a symlink into a *specific* nix store
path, planted by each component's `install.sh`. A `nixos-rebuild` updates the system closure and
leaves those links pointing at the previous build — so "the mothership rebuilt" and "the
operator's managers are new" are different facts (learned the hard way on 2026-09-23: the
mothership was rebuilt and `site-manager` still did not know an option added in that commit).
Without the relink a boundary would test the *old* manager binaries against the new base, which
is the one combination nobody will ever run.

**3 — Land on `main`.** Fast-forward `main` to the branch, push, point this site back at `main`,
and delete the pin branch — its commit is an ancestor of `main` by then, so it holds nothing
`main` does not, and left behind one accumulates every fortnight.

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
  "soakStartedAt": 1790178802,
  "channels": { "unstable": "ede8f4c8", "staging": "4c9c846a", "production": "d796e254" },
  "pin": "1bc55b9def8165e82073919945c3239903fe4dc2",
  "lastBoundary": { "at": 1790178802, "forced": false },
  "fault": null
}
```

`soakStartedAt` is an epoch, and it restarts from the **promotion**, not from when someone
remembered to run `init` — "has staging soaked?" must not be answerable by waiting to ask. While a
boundary is in flight a `boundary` object is also present, carrying the pin branch, the revisions
it moved between, and `phasesDone`; that is what `--resume` reads, and it is cleared when the
boundary completes. `forced` records a `--force-boundary`, because a soak that was skipped should
be visible afterwards rather than only in someone's memory.

Backed up with the rest of `config/` (it is small, and losing it means losing the answer to "has
staging soaked?"). A `fault` object carries what was seen, where, and the commit that resolved it.

## What must exist first

These are prerequisites, not nice-to-haves. The script cannot be written honestly without them:

1. **A channel per site — done (2026-09-23).** `site.json` carries `channel`
   (`unstable | staging | production`), and `site-manager site modify --channel` sets it, warning
   when it disagrees with the tracked branch and refusing a move towards production without
   `--force`. hrossen is `unstable` on `main`; makerfloss is `staging` on `staging`.
2. **The three branches — they exist.** `main`, `staging` and `stable` are all on the forge.
   `stable` has been there all along (`d796e254`, 2026-09-18); `staging` was cut on 2026-09-23.
   So `tappaas-train init` does **not** create them — its job is to **verify** them, which is the
   more useful check anyway:

   > `stable` ⊆ `staging` ⊆ `main` — each channel ref an ancestor of the one above it.

   That single assertion is what makes the train promotable: it proves every promotion is a
   fast-forward and that nothing has been pushed sideways into a channel. `init` reports the
   distance between them and refuses to do anything else while they have diverged.
3. **D10's self-check** (#713), so phase 2's sweep cannot leave the test site's control plane
   broken and unnoticed half way through a boundary.
4. **A push credential on the mothership.** Verified present on the test site — `git push
   --dry-run` authenticates. Worth stating plainly: this machine can move `stable`, so the
   fast-forward-only checks are a safety property, not a formality.

## The first boundary is not a boundary

Measured 2026-09-23: `stable` is **196 commits behind `main`** (`d796e254`, 2026-09-18), and a
clean ancestor of it — so the promotion is mechanically a fast-forward with nothing to
reconcile. That is the good news and also the trap.

A routine boundary promotes one fortnight of reviewed work. The *first* one would promote five
days of unusually dense change in a single step: the satellite's NixOS path retired, the RTC
flag fixed on every guest, identity's SSO skip, the `stack` enumeration, the control plane's
self-check and rollback, and the channel field itself. Every one of those has been tested, but
**none of them has soaked anywhere**, which is precisely what the staging channel exists to
provide.

So the first run is a **migration into the train**, not an exercise of it:

1. let `staging` (makerfloss) soak the current content for a full boundary, under real use;
2. only then promote `staging → stable`, which is the first honest `production` release;
3. from there the ordinary two-week rhythm applies.

Running `tappaas-train boundary` today would be mechanically valid and operationally wrong. The
script should therefore refuse a promotion whose soak has not elapsed (preflight already
requires this) — and on the first run, "elapsed" has no recorded start, so `init` sets one.

## Deliberately not in scope

- **Rolling anything back.** Patch forward is the whole rule.
- **Choosing the nixpkgs branch.** The script performs a version move (`--to`, phase 1) but never
  decides one: which release to move to is an operator judgement, taken from the release notes.
- **Deciding the boundary date.** The interval is policy (ADR-028 D2); the script only checks it
  has elapsed.
