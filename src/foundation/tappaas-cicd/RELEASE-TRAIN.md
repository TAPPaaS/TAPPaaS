# The release train

How a change reaches your site, and how an operator moves it there.

TAPPaaS releases on a **two-week boundary**. At each boundary one revision is promoted to
production and a new one starts soaking — one train, always moving in the same direction.
`tappaas-train.sh`, on the mothership, is the command that runs a boundary.

The decisions behind this are [ADR-028](https://codeberg.org/TAPPaaS/TAPPaaS/src/branch/main/docs/ADR)
(*Release Cadence and Patching*); the phase-by-phase design is `docs/design/release-train-promotion.md`
in the source repository. This page is the operator's reference.

## Channels and branches

A **channel** is a promise about risk. A **branch** is where the code sits. They are named apart
on purpose, because "stable" as a promise to an operator and `stable` as a git ref are different
statements.

| Channel | Branch | What it means | Who runs it |
|---|---|---|---|
| `unstable` | `main` | development, proven by a full deep test before it lands | the site where TAPPaaS is developed |
| `staging` | `staging` | a complete release under real use, soaking for one boundary | one real site, running real work |
| `production` | `stable` | what has soaked for a full boundary without a fault | everyone else |

Your site's channel is a field in `site.json`:

```bash
site-manager site modify --channel production
```

Changing it warns when the channel and the tracked branch disagree, and refuses a move *towards*
production — or onto a branch behind the migrations your config has already applied — without
`--force`. A site can sit on any branch; the channel says what you expect of it.

### Which branch is which channel — `channels.json`

The table above is *this* repository's mapping, and it is not hardcoded anywhere: each repository
declares its own, in `channels.json` at its root (ADR-028 D11).

```json
{
  "production": ["stable"],
  "staging":    ["staging"],
  "unstable":   ["main"]
}
```

A **list** per channel, because a repository may realize one channel from more than one branch;
usually there is a single entry. Two rules follow, both erring the same way:

- **A branch listed in no channel is unstable.** An unrecognised branch — a `pin/2026-w39`, a
  feature branch — is never mistaken for production.
- **A repository with no `channels.json` is undeclared**, which reads as unstable throughout. That
  is a *warning*, not a refusal: repositories predate this file, and a site tracking one must keep
  working. But it is said out loud, every time, because the silence it replaces was a site claiming
  `production` while tracking somebody's `main`.
- **A repository that declares no branch for your channel** — only `unstable`, say, because it has
  never cut a release — is reported separately from one that is merely on the wrong branch. There is
  nothing to switch to, so "move to X" would be nonsense; the site simply cannot claim that channel
  for that repository until a branch exists.

This matters because a site tracks **several** repositories — the TAPPaaS source, the Community
modules, often its own — and the channel is a claim about all of them. So:

```bash
tappaas-train.sh status
```

lists every registered repository with the branch it is on, the channel that branch realizes, and a
note where that disagrees with the site's channel or where nothing is declared. And:

```bash
site-manager site modify --channel production
```

checks the same thing at the moment you change it: for each repository it names the branch that
repository declares for the new channel, says which ones do not match, and prints the
`site-manager repository modify <name> --branch <b>` that would settle each. **It does not switch
them.** A branch change is a code change to a live site, and when that happens is yours to decide.

## Running a boundary

Only the `unstable` site drives a boundary. A production site promoting its own untested code is
the failure this train exists to prevent, and preflight refuses it.

```bash
tappaas-train.sh status
```

Where each channel points, how far apart they are, the estate's nixpkgs pin, how much of the soak
has elapsed, and anything that would block a boundary. It changes nothing, so it is always safe.

```bash
tappaas-train.sh init
```

**Run once, before the train's first boundary on a site.** It does two things, and refuses rather
than repair:

1. **Checks the train is usable.** All three refs — `main`, `staging`, `stable` — must exist on the
   forge, and they must satisfy `stable ⊆ staging ⊆ main`. `init` does **not** create a missing
   ref: a production channel that appears because a command invented it is exactly what this train
   exists to prevent, so it names what is missing and stops. If the three have diverged, it stops
   too — the train is fast-forward only, and a human has to reconcile that.
2. **Starts the soak clock**, recording it in `config/release-train.json` along with where each
   channel points, its version, and the estate pin.

It is safe to re-run: with the clock already running it reports the date it started and changes
nothing, so it never silently restarts a soak that is part-way through.

The clock matters because the soak is what a boundary waits on. A site that has never run `init`
has no start date, so `boundary` refuses — and this is one of the refusals `--force-boundary`
**cannot** lift, unlike an incomplete soak. A soak that has not started is not a soak you can
decide to cut short; there is nothing to cut short.

```bash
tappaas-train.sh boundary
```

Six phases, in this order:

1. **Branch and move the pin.** `pin/<yyyy>-w<ww>` off `main`, then `nix flake update` for the
   estate. Add `--to nixos-26.05` for a **version move** — the nixpkgs release branch itself
   rather than a refresh within it. That is the only way past a frozen branch, and the script
   never chooses one: `--to` is always your word.
2. **Prove it here.** The site is first pointed at the pin branch — the sweep reconciles the
   checkout to whatever `site.json` declares, so a branch that is merely checked out gets reset
   back to `main` half way through and the rest of the sweep quietly builds the old revision.
   Then one NixOS guest meets the new revision *first*, so a bad pin is caught by a machine that
   can be rolled back from a snapshot rather than by the machine that would have to do the
   repairing. Then the full sweep, then `site-manager test --deep`. **This takes hours and
   reboots nodes.** However it ends, the site is put back on `main`.

   **A `--to` move reboots this mothership.** Across a nixpkgs release an in-place switch
   cannot reload `dbus-broker`; it reports failure over it and the rollback live-locks
   (#725). So the new generation is staged with `nixos-rebuild boot` and taken at the next
   start. The boundary ends there — resume it once the machine is back:

   ```bash
   tappaas-train.sh boundary --resume --to <nixos-XX.YY> ...
   ```

   With `automaticReboot: false` in `site.json` the move is staged but not taken, and the
   boundary stops with the pending generation named. Nothing is activated either way, so
   the running system is untouched until it reboots.
3. **Land on `main`.** Fast-forward, publish, point the site back at `main`, delete the pin branch.
4. **`staging` → `stable`.** The revision that has soaked for a fortnight reaches production —
   under the version it was given two weeks ago.
5. **Record, then `main` → `staging`.** The release record and the `ROADMAP.md` cut are committed
   to `main` first (see *Versions* below), so the revision that starts its soak — tagged as the
   next version (`v2.2`) — already says what it is. Nobody edits either during a boundary.
6. **Verify the staging site** (`--staging-host <host>`), if you named one.

Steps 4 and 5 are in that order deliberately: the old staging content reaches production *before*
the new content reaches staging, so at no moment does production hold something that has not
soaked. Every promotion is fast-forward only — nothing is ever pushed sideways into a channel, and
no channel is ever rewound.

**Nothing is promoted unless step 2's deep test passed.** If it fails, the branch is intact, the
estate is untouched, and the boundary stops.

| Option | What it is for |
|---|---|
| `--dry-run` | print the plan and the preflight verdict; change nothing |
| `--resume` | continue a run that stopped half way — phases are recorded, so completed ones are not repeated |
| `--force-boundary` | proceed despite a *wait* condition (the soak is not complete). It is recorded. It cannot lift a broken one |
| `--to <nixos-XX.YY>` | a version move: rewrite the nixpkgs release branch in phase 1 |
| `--major` | cut the next major (2.7 → 3.0) instead of the next minor. Only ever your word |
| `--guest <module>` | choose the guest that meets the new pin first (default: the first module that depends on `templates:nixos`) |
| `--staging-host <host>` | run phase 6 against the staging site over ssh |
| `--staging-branch <b>` / `--production-branch <b>` | promote onto throwaway refs instead of `staging` and `stable` — a whole boundary rehearsed without touching a real channel. A rehearsal cuts no version and writes no record |

`stable` is never *created* by a promotion, only fast-forwarded. A production channel that appears
because of a typo is exactly what this is here to prevent.

## Versions

Every boundary gives the revision it cuts into staging the next version, as an annotated git
tag. The same number reaches production one boundary later, so one version names one revision
for its whole life (ADR-028 D13).

| Change | Version |
|---|---|
| a boundary | the next minor: 2.1 → 2.2 |
| a boundary with `--major` | the next major: 2.7 → 3.0 |
| an urgent fix (`patch`, below) | a third number on the channel it reaches: 2.2 → 2.2.1 |

```bash
tappaas-train.sh status      # each channel's version, and what the next boundary will cut
tappaas-train.sh releases    # every version: its commit, when it reached staging and production
site-manager site show       # the version this site runs, read from its checkout
git checkout v2.1            # the exact code of a version
```

A site on `main` between boundaries shows as `2.2+14`: fourteen commits past 2.2.

**Where the record lives.** Two places, for two jobs:

- **In the repository**, for everyone: the tags, and
  [`release/releases.json`](../../../release/releases.json) with
  [`RELEASES.md`](../../../RELEASES.md) rendered from it — every version, its commit, and the day
  it reached each channel. The boundary commits it to `main` just before `main` is promoted to
  staging (one `chore(release): …` commit), so the new tag holds its own record and every site
  has the full history after its next pull. The new version's commit cannot name its own hash:
  `RELEASES.md` shows its tag until the version reaches production, when the hash is filled in.
  After a hand edit of the JSON, `tappaas-train.sh releases --render` redraws the page.
- **[`ROADMAP.md`](../../../ROADMAP.md)**, in the same commit:
  [`release/roadmap-cut.py`](../../../release/roadmap-cut.py) moves every ✅ row out of the waves
  into a `## Release <version>` section, turns `## Next release` into its summary, and gives the
  release that reached production its date. `--dry-run` shows what it would move; a rehearsal
  cuts nothing. Keep `## Next release` current as work lands — that text is the release's
  summary.
- **On the mothership that drives the train**, for the run: `~/config/release-train.json` — the
  soak clock, a boundary half way through, a recorded fault, the urgent fixes a channel carries.
  It changes several times within one run, so it is not committed. It is written to be read:
  dates, and each channel with its version and the day it last moved.

## One pin for the estate

Every TAPPaaS-managed NixOS system — the mothership and all its guests — is built from the single
nixpkgs revision in `src/foundation/templates/flake.lock`. The mothership cannot choose a
different one; it follows that lock through a relative path input. Phase 1 re-locks both flakes
and refuses if the two resolve differently, because a control plane on a different revision from
its guests is a split nobody would notice until something broke.

Debian guests are not part of this: they patch themselves between releases (`apt-get upgrade` on
the daily sweep, `unattended-upgrades` where a guest is locked down).

## Before the pin moves: preview and ack (#788)

A boundary proves a new pin by running it — a guest first, then the sweep, then the deep test —
which takes hours. What a pin move *brings* is known much sooner: evaluating every guest against
the next pin (nothing is built) shows which packages change major version and which critical or
high CVEs the move introduces, keeps, or fixes. That takes minutes.

```bash
tappaas-train.sh preview                        # the next patch pin of the current release
tappaas-train.sh preview --to nixos-26.11       # a release move
tappaas-train.sh ack --note "read the Grafana 14 notes; CVE-… has no fix upstream yet"
```

| Option | Meaning |
|--------|---------|
| `preview` | Resolve the pin the next boundary would take, evaluate the guests the last security scan found against it, and compare. Prints the summary, writes `config/train-preview.json`. Changes nothing. |
| `preview --to <nixos-XX.YY>` | The same for a version move to another release branch. |
| `ack` | Accept everything the last `preview` reported: its major version changes and the critical/high CVEs it introduces (or a CVE match that failed). |
| `ack --note "<why>"` | The same, with the reason recorded beside it. |

**What is reported.** Only packages that *run today* are compared — the last `health-manager scan
security` says which, per guest — so build tools in a closure do not count. *Major* is the first
version number changing (`13.0.9 → 14.0.1`) — except where that number is a date or a sequence
(100 or more: `20260107`, less `692`, systemd `260`), which counts up with every release; and
except the packages `release/pin-watch-ignore.json` lists, each with the reason its major is no
break for TAPPaaS. Both are reported as "not counted as major", never hidden. A major whose
version goes *down* is labelled a downgrade. On the CVE side, the next pin's packages are matched
the way a scan matches them (`health-manager scan nix-list`): critical/high CVEs it **introduces**
need an ack; those it **keeps** and those it **fixes** are reported. A failed match is never a
clean result — it needs an ack like a finding.

**What a boundary does with it.** Right after phase 1 moves the pin — before the deep test — the
boundary computes the same findings for the pin it actually took:

- nothing found: it goes on, **no ack needed** — the common case;
- everything found is covered by the last `ack`: it goes on (the channel may have moved a few
  commits since the preview; what matters is that it brings nothing new);
- anything not covered: it **stops** before the deep test, names the new items, and leaves the
  checkout clean. Run `preview`, read the upstream notes, `ack`, run the boundary again.

The accepted items are recorded on the release (`accepted` in `release/releases.json`, shown by
`tappaas-train releases`), and the boundary uses the ack up. `boundary --dry-run` says what the
gate would do with the last preview. When the gate cannot judge — no security scan to compare
with, or the pin cannot be evaluated — it says so and lets the deep test decide.

Not covered: the mothership (a flake of its own on the same pin; compared through its guests'
packages), container images (they have their own pins, below) and Debian (patched daily).

## When staging finds a fault

**Patch forward. Nothing moves backwards.** A blocked train is a normal state, not an incident —
it means staging did its job.

```bash
tappaas-train.sh fault "identity lost its OIDC app after the sweep"
tappaas-train.sh fault --resolved <commit>
```

While a fault is recorded, the next boundary's preflight refuses and names it. Neither `staging`
nor `stable` is rewound; the fix lands on `main` and travels the train like everything else. If it
was hotfixed on `staging`, it must be back-ported — `--resolved` requires the commit to be an
ancestor of `main`, which is what makes "back-ported" a fact rather than an intention.

## When a fix cannot wait for the boundary

Rare, and deliberately hard to reach for: **data safety, a high-severity security CVE, or a
service down with the fix already written** — each only when there is no workaround (ADR-028 D12).
"It is finished" is not a reason; the soak is the test, not a queue.

Author the fix on a branch off **the channel's own tip**, merge that branch into `main`, then let
the train move the channel onto it:

```bash
git checkout -b hotfix/<what> origin/staging
# ... the fix, tested ...
git checkout main && git merge --no-ff hotfix/<what> && git push origin main
tappaas-train.sh patch staging <fix-commit> --why "service down: <what>" --dry-run   # look first
tappaas-train.sh patch staging <fix-commit> --why "service down: <what>"
```

`patch` fast-forwards the channel, tags the fix as the channel's next third number (`v2.2.1`),
records it on `main`, and keeps the reason in the mothership's state — written *before* the move —
so `status` shows the channel as carrying an urgent fix until the next boundary. It refuses a
commit that is not on `main`, one that does not build on the channel's tip, and a missing `--why`.

The channel then gains **exactly** the fix, and its tip is still an ancestor of `main`, so
`stable ⊆ staging ⊆ main` holds and `init` is satisfied. Cherry-picking straight onto the channel
breaks that ancestry and `init` refuses; fast-forwarding the channel to `main`'s tip keeps the
ancestry but promotes everything ahead of the fix, which abandons the soak rather than shortening
it. `patch` lists the commits it would move and warns when there are more than a few. Record it
with `tappaas-train.sh fault --resolved <commit>` if a fault was open.

`--why` must begin with the D12 case it invokes — `data safety:`, `security:` or `service
down:` — then what; anything else is refused, so the bar can be audited from
`release/releases.json` afterwards. The next boundary promotes the fix with everything else,
says which urgent fixes it supersedes, and records them on its release (`supersedes`).

**Who moves a channel.** An urgent fix to production is moved by the operator, by hand: the
train never moves `stable` on its own (ADR-028 D12).

**Never patch a running site in place and stop there.** `tappaas-train status` and the
control plane's self-check report what runs ahead of the checkout: uncommitted changes in it,
commits that are not on the site's channel, and a plain file in `~/bin` that differs from its
source or has none.

**For production, staging first.** Production may never get ahead of staging, so `patch
production` refuses a fix staging does not have. Author the fix off `stable`'s tip, bring it into
staging with a merge on a branch off staging's tip, land both on `main`, then patch staging with
that merge and production with the fix itself:

```bash
git checkout -b hotfix/<what> origin/stable                     # the fix: F
git checkout -b hotfix/<what>-staging origin/staging && git merge --no-ff hotfix/<what>   # M
git checkout main && git merge --no-ff hotfix/<what>-staging && git push origin main
tappaas-train.sh patch staging    <M> --why "security: <CVE>"
tappaas-train.sh patch production <F> --why "security: <CVE>"
```

**Do not patch a running site in place and stop there.** A site whose deployed scripts are ahead
of its checkout is lying about what it runs: nothing reports the divergence, and the next
control-plane refresh relinks `~/bin` from the checkout and reverts it silently. If you must, to
stop active damage, treat it as a bridge to the channel move and not a substitute.

## What preflight refuses

Every one of these is a refusal, not a warning:

- this site's channel is not `unstable`;
- the checkout is dirty, or is not at `origin/main`;
- the mothership cannot push to the forge — found out now, not after the pin has moved;
- a sweep is running here or on the staging site;
- either site's last sweep failed — a new pin must not be blamed for a failure that predates it;
- an unresolved staging fault;
- a module in this repository is missing a MUST of the blueprint (ADR-027), a service
  README's field section no longer matches its `fields.json`, or a stack README's or INSTALL.md's module
  list no longer matches the catalogue — see *The module blueprint* below;
- gitleaks finds a secret in the commits since the last release or in the tree, or the scan
  could not run — see *Secrets* below;
- the channels have diverged (`stable` ⊆ `staging` ⊆ `main` no longer holds);
- a site is pointed at a channel *behind* the commit it already runs.

The soak being incomplete is the one condition that resolves itself with time, so it is the one
`--force-boundary` can override.

## The module blueprint

Once a fortnight, not on every push: the boundary checks every module in this repository against
the blueprint ([ADR-027](../../../docs/ADR/ADR-027%20-%20Module%20Blueprint.md)) on the exact commit
it is about to promote, with `module-manager validate --blueprint --repo ~/TAPPaaS`, and checks
that every service README's generated field section matches its `fields.json` and every stack
README's and INSTALL.md's module list (`src/<stack>/`, #421) matches the catalogue. A missing MUST or
a stale README blocks the boundary, and `--force-boundary` does not lift it. Missing SHOULDs (a
module without a test) are counted and never block. Community is not checked: the train promotes
TAPPaaS only.

- **`status`** runs the same check and prints it — which modules, which files — so a gap shows
  during the fortnight rather than on boundary day. It records nothing.
- **`boundary`** records the result in `~/config/release-train.json` under `.blueprint`: the
  commit checked, when, whether it passed, and the error and warning counts. A dry run records
  nothing. The version's tag message carries the same line, so the record travels with the
  release, not only with this mothership's config backup.
- To fix a finding before the boundary, run the check yourself — it is read-only:
  `module-manager validate --blueprint --repo ~/TAPPaaS`, or for one module,
  `module-manager validate --blueprint ~/TAPPaaS/src/<stack>/<module>`.

## Secrets

The enforcing scan for secrets (#378) is here, not on every push: the boundary runs gitleaks on
the commits since the last release and on the tree, values redacted, with the repository's
`.gitleaks.toml` (the default rules plus the look-alikes it allowlists). A finding — or a scan
that could not run — refuses the boundary, and `--force-boundary` does not lift it. `status`
shows the result; `boundary` records it under `.secrets` and in the tag message. A false
positive goes in `.gitleaks.toml` with its reason; a real one is rotated first, then removed.
On the mothership a pre-commit hook (`core.hooksPath`, from `tappaas-cicd.nix`) refuses a staged
secret before it is ever committed.

## Container image pins

A module that runs its application as a container pins an image tag, and nothing moved such a pin
but a person (#748: Authentik 7½ months behind). `src/image-pins.json` lists the pins — module,
image, the file holding the value and how to read it, tag or digest, maintainer — and every
boundary reports each one ([ADR-028](../../../docs/ADR/ADR-028%20-%20Release%20Cadence%20and%20Patching.md) D14, #750):

- its **age** (when the line holding it last changed) and, for a tag, the **newest upstream** tag
  of the same form and how many are newer; a digest by its age only;
- **stale** when it is older than 45 days and upstream is newer — a warning naming the module's
  maintainer, **never a refusal**: moving a pin is the maintainer's reviewed change;
- images in the tree that are not yet in the list, so a new pin cannot hide.

`status` prints it; `boundary` records it under `.imagePins` and in the tag message
(`Images: N pin(s), M stale`). To see it yourself: `python3 src/foundation/tappaas-cicd/scripts/image-pins.py`
(`--offline` for ages only). To add a pin, add an entry to `src/image-pins.json`; the report then
says whether its `match` finds the value.
