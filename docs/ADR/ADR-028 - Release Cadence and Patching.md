# ADR-028 — Release Cadence and Patching

| | |
|---|---|
| **Status** | **Accepted** (2026-09-23) — agreed by the operator. D10 is built (#713), so D2's cadence no longer leans on a gap. |
| **Version** | 1.2 |
| **Date** | 2026-09-22 |
| **Author** | Lars Rossen |
| **Related** | **#713** (the control plane's missing verification and rollback — D10, built) · **#712** (retire the satellite's `--os nixos` remains — raised by D7) · **#680** (the baseline lock decides every site's nixpkgs; its code half landed, its cadence half is this ADR) · **#709** (Nextcloud cannot advance past 33 on a frozen branch — the first concrete demand for a branch move) · **#324** (modules copy the baseline instead of importing it) · **#675** (no extension point for a site's own NixOS modules) · **#166** (the earlier single-path clock fix) · [ADR-017](<ADR-017 - Update scheduling and mothership self-update.md>) D3 (the mothership rebuilds itself from the checkout, before the sweep) · [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) D8 (`rebootOk` — whether a kernel change may land) · [ADR-025](<ADR-025 - Config migrations and the upgrade path.md>) (how a release brings `config/` forward; this ADR is its counterpart for the OS) · [ADR-026](<ADR-026 - Managed Machines as Modules.md>) (`debianhost` and the machine OS lifecycle) |
| **Changelog** | **v1.2 (2026-09-23)** — D8 gains the release move: across a nixpkgs release an in-place switch cannot reload `dbus-broker`, reports exit 4 over it, and its rollback live-locks (#725), so the mothership stages a release move with `nixos-rebuild boot` and reboots into it. · **v1.1 (2026-09-23)** — D1 corrected on measurement: `follows` removes the mothership's *choice* of revision but not its lock's *copy* of it, so moving the estate re-locks both flakes and compares them; `--to` in `tappaas-train` phase 1 performs a version move (#709). · **v1.0 (2026-09-23)** — D1 and D4 built: the mothership follows the estate pin through a relative path input (same derivation before and after, verified as root), and the tripwire now watches `templates/flake.lock` at 45 days and fails if a second pin reappears. · v0.9 (2026-09-23) — D9 gains the rule for a fault found in staging: patch forward, block promotion until the fix is an ancestor of `main`, and never rewind a channel; the boundary itself is designed as one command in `docs/design/release-train-promotion.md`. · **v0.8 (2026-09-23) — ACCEPTED.** Channels are named for what a site runs — **unstable**, **staging**, **production** — on the branches `main`, `staging` and `stable`; the two are named apart on purpose, because "stable" as a promise to an operator and `stable` as a ref are different statements. · v0.7 (2026-09-23) — the satellite's flake is deleted, not merely proposed for retirement (#712 landed), so Context names two pins and D7 records the deletion; adds what a bump costs, measured on the test site: a daily sweep re-downloads nothing (0.03 s to resolve a cached revision, 0.335 s to revalidate), while a pin change costs ~1 GB of fetches and ~10 GB of store across 22 guests, each fetching from GitHub on its own. · v0.6 (2026-09-22) — D10 built and verified on hrossen (#713): the control plane checks itself after a switch and rolls back the generation it replaced when that check fails. · v0.5 (2026-09-22) — retitled from *OS Version Tracking*: once the alpha/beta/stable train landed, the ADR was about release cadence and patching, of which the nixpkgs pin is one input. · v0.4 (2026-09-22) — the operator's train: three channels (alpha/beta/stable) on two-week boundaries, so `stable` is at most four weeks behind and a CVE **accelerates** the train instead of cherry-picking a pin onto code it was never built against; D9 gains the guest-first validation rule (a guest proves a revision before the mothership takes it, without reordering the sweep); D2's beat restated as the boundary. · v0.3 (2026-09-22) — D2 collapsed to **one weekly rhythm** with a full `--deep` test, on a NixOS expert's advice relayed by the operator: a version move is a bigger weekly bump, not a separate cadence (the ~1-month backport overlap is slack, not licence to linger). New D9 (how a bump reaches `main`, and why `stable` takes the pin with its monthly release rather than by weekly cherry-pick) and D10 (the mothership has no rollback, goes first, and needs one before the cadence leans on it). · v0.2 (2026-09-22) — a primer on flake vs non-flake Nix and on patch vs version moves in both OS families, so the decisions read without prior Nix knowledge; D1 states why the mothership keeps its own flake (upgrade safety, four reasons); the satellite corrected to Debian and its `--os nixos` remains proposed for retirement (#712); D5 separated the three Debian patch paths. · v0.1 (2026-09-22) — first draft, from the operator's questions of 2026-09-22 and a read of the shipped code. |

When TAPPaaS releases, and how OS and software patches reach a site — the channels, the cadence, and what each OS family does between releases.

---

## Primer — two ways a machine gets its versions

*Skip this if you already know flakes. It is here because the rest of the ADR is unreadable
without it, and because the two OS families in a TAPPaaS estate work by opposite principles.*

### Debian: the system is a set of packages, changed in place

A Debian machine *is* whatever `apt` has installed on it. The distribution publishes an archive
that moves continuously, and `apt-get upgrade` pulls in whatever is current for the release the
machine is on. The machine's state is the accumulated result of every upgrade it has ever run.

- **Patch upgrade** — new package versions *within* the same release (`bookworm` stays
  `bookworm`). This is where security fixes arrive, continuously, and it is what the sweep does.
- **Version upgrade** — moving to the *next* release (`bookworm` → `trixie`). A different
  operation entirely (`do-release-upgrade` / a `dist-upgrade` across pinned sources), done
  deliberately, occasionally, and with a plan.

### NixOS: the system is a build output, replaced whole

A NixOS machine is **built**, not mutated. You describe the machine in a `.nix` file, a build
turns that description plus a package set into a complete system ("a generation"), and switching
activates it. Nothing is upgraded in place; a new system is built beside the old one and you move
to it — which is why the previous generation is still there to roll back to.

The consequence that matters here: **a NixOS machine's package versions are decided entirely by
*which package set it was built against*.** That package set is nixpkgs, identified by a git
revision. Same revision in, same system out — every time, forever.

So "rebuild" and "upgrade" are different things on NixOS, and this is the single most important
sentence in this ADR:

> **Rebuilding a NixOS machine against the same nixpkgs revision changes nothing.** The nightly
> sweep rebuilds every guest and delivers no patches at all, unless the revision has moved.

On Debian the equivalent daily action *does* deliver patches, because the archive moved under it.
Same sweep, opposite outcomes.

### Naming a package set: with a flake, or without

There are two ways to tell a NixOS build which nixpkgs to use, and TAPPaaS uses both — for
different jobs.

**Without a flake (the classic way).** nixpkgs comes either from a *channel* — a moving pointer
the machine subscribes to and refreshes with `nix-channel --update` — or from an explicit path
handed to the build: `nixos-rebuild switch -I nixpkgs=<url of an exact revision>`. A channel is
mutable and machine-local, so the same command on two machines, or on the same machine next
week, can produce different systems. The `-I` form is the opposite: whoever runs the build
decides the revision, and it overrides the channel.

**With a flake.** Two files work together, and the split between them is what readers most often
miss:

| File | Answers | Changed by |
|---|---|---|
| `flake.nix` | *Which branch do I follow?* e.g. `github:NixOS/nixpkgs/nixos-25.11` | a human, editing it — a **version** move |
| `flake.lock` | *Which exact commit am I on right now?* e.g. `b77b3de8…` | `nix flake update`, which re-resolves the branch and rewrites **only this file** — a **patch** move |

A build from a flake uses the locked commit, not "whatever the branch holds today". That is what
makes it reproducible and reviewable: the version the estate runs is a line in git, with a
history and a diff.

### How TAPPaaS combines them

- **Flakes decide and record** the revision. Two lock files exist, and between them they pin
  everything (D1 reduces this to one).
- **The non-flake `-I nixpkgs=` mechanism applies it.** Guests have no flake and no channel of
  their own: the mothership reads the locked revision and passes it to each guest's rebuild.
  A guest therefore cannot drift, and cannot opt out.

### The two kinds of move, in both families

| | Debian | NixOS |
|---|---|---|
| **Patch** | `apt-get upgrade` — automatic, every sweep, from the moving archive | `nix flake update` → new commit in `flake.lock` → rebuild. **A human action, or it never happens** |
| **Version** | `bookworm` → `trixie`: an explicit release upgrade | `nixos-25.11` → `nixos-26.05`: edit `flake.nix`, then update the lock, then rebuild |
| **Who initiates** | the distribution | us |
| **Rollback** | restore from backup | boot the previous generation |

`system.stateVersion` is not a version to chase. It records which NixOS release a machine's
*mutable state* (databases, home directories, service data layouts) was first initialised for, so
that later NixOS releases keep treating that state compatibly. It stays where it is across a
version move.

---

## Context

Two OS families run in a TAPPaaS estate, and they get their updates by opposite means.

**NixOS guests are built, not upgraded.** A guest has no flake and no channel of its own. On
every sweep `update-os.sh` copies the module's `<vmname>.nix` to `/etc/nixos/` and runs, on the
guest:

```
sudo nixos-rebuild switch -I nixpkgs=https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz \
                          -I nixos-config=/etc/nixos/<vmname>.nix
```

`<rev>` is read on the mothership from `src/foundation/templates/flake.lock`
(`update-os.sh:443`). The `-I` deliberately overrides whatever channel the VM carries, so the
module's `.nix` decides *which options are set* and the pin decides *which package set those
options resolve against*. A guest cannot opt out, and nothing on the guest records a version.

**Debian and Ubuntu guests are upgraded in place.** The same script runs `apt-get update` and
`apt-get -y upgrade` on every sweep (`update-os.sh:583-592`). They track their distribution's
archive, so security updates arrive on the distribution's schedule with no action from us.

That asymmetry is the whole of this ADR: **the Debian half patches itself and the NixOS half
patches only when a human moves a file in git.** Nothing in the tree runs `nix flake update`,
and `system.autoUpgrade` is `enable = false` wherever it appears.

### Where the estate stands today (measured 2026-09-22)

| Pin | Tracks | Locked revision | Decides |
|---|---|---|---|
| `templates/flake.lock` | `nixos-25.11` | `b77b3de87756`, 2026-05-22 | every NixOS **guest**, via `update-os.sh` |
| `tappaas-cicd/flake.lock` | `nixos-25.11` | `b77b3de87756`, 2026-05-22 | the **mothership**, via `tappaas-self-rebuild.sh` |

**There are exactly two.** A third, `satellite/flake.nix`, tracked `nixos-25.05` with no lock
file; it backed an `--os nixos` option nothing used, and #712 deleted it on 2026-09-22. A
satellite is Debian.

Two observations, each of which a decision below answers:

1. They are byte-identical today. Nothing keeps them so — they are two files, refreshed by hand,
   and #709 proposes moving one of them.
2. `nixos-25.11` went end-of-life around the end of June 2026 (its last commit is
   2026-06-30). We are running an unsupported branch, and have been for roughly three months.
   **A frozen branch cannot deliver a security backport, so the NixOS half of the estate has had
   no security patches since May.**

### What a bump costs, measured

`-I nixpkgs=<url>` is a real download, and the rebuild runs **on each guest** — the mothership
does not fetch once and distribute. Measured on the test site, 2026-09-23:

| | |
|---|---|
| the tarball | **48.3 MB** from `codeload.github.com`, ~5.6 s on the test site's link |
| unpacked in each guest's store | **445 MB** |
| each guest's fetch cache (`/root/.cache/nix`) | 61 MB |
| resolving an already-fetched revision | **0.03 s**, no network |
| resolving it with the TTL forced to zero | **0.335 s** — a revalidation, not a re-download |

So a daily sweep over 22 NixOS guests does **not** re-download nixpkgs, even though `tarball-ttl`
is an hour and the sweep runs a day apart: the revision is already in each guest's store, and
the worst case is a sub-second revalidation. Roughly 1 GB a day of pointless traffic is the
thing that does *not* happen.

What a **pin change** costs, on the other hand, is real and should be said out loud, because the
cadence in D2 decides how often it is paid: each guest fetches its own copy, so a bump is about
**22 × 48 MB ≈ 1 GB** of downloads for the estate, and about **22 × 445 MB ≈ 10 GB** of new
store content until the old revision is garbage-collected. (The packages themselves are a
separate and larger download from `cache.nixos.org`.) Nothing shares a mirror: each guest goes to
GitHub on its own. At a fortnightly cadence that is affordable; it is worth knowing before anyone
proposes daily.

### What reaches an existing VM, and what does not

The template image and the estate pin live in the same directory, which invites the assumption
that refreshing the image patches the estate. It does not.

| What moves | Reaches | How |
|---|---|---|
| the estate pin (`templates/flake.lock`) | **every existing NixOS VM**, next sweep | `-I nixpkgs=<rev>` at rebuild |
| the module's `<vmname>.nix` | **every existing VM**, next sweep | copied to `/etc/nixos/` each update |
| the site fragment `tappaas-site.nix` (time, locale, NTP) | **every existing VM**, next sweep | generated and shipped each update |
| the template image (`version`, `imageLocation`) and the `tappaas-common.nix` baked into it | **new clones only** | full clone at creation |

`update-os.sh:414` states the last row's consequence: the baseline itself is not shipped. A VM
keeps its birth baseline for life, because modules carry their own copies of it rather than
importing it — that is #324, still open. The image's package staleness, by contrast, is washed
out on the guest's first rebuild against the pin.

---

## Decisions

### D1 — One pin for the estate

`src/foundation/templates/flake.lock` is the **single source of truth** for the nixpkgs revision
every TAPPaaS-managed NixOS system is built from. The mothership's flake takes its nixpkgs from
that same lock rather than carrying a second one:

```nix
# src/foundation/tappaas-cicd/flake.nix
inputs.templates.url = "path:../templates";
inputs.nixpkgs.follows = "templates/nixpkgs";
```

`follows` removes the *choice*, not the *copy*: `tappaas-cicd/flake.lock` still records a
`nixpkgs` node, and it keeps the old revision until that flake is re-locked too (measured on the
test site, 2026-09-23). Moving the estate is therefore two `nix flake update` runs and an
equality check, which is what `tappaas-train` phase 1 does — one pin, two files.

The mothership **keeps its own flake and its own build path** —
`nixos-rebuild switch --flake .#tappaas-cicd`, used by both `bootstrap.sh` and
`tappaas-self-rebuild.sh`. That is deliberate, and the reason is **upgrade safety**:

1. **It upgrades itself without using the machinery it is upgrading.** The mothership is the
   machine that performs every *other* machine's upgrade. If its own rebuild went through
   `update-os.sh` and `module-manager`, then a bad upgrade could take out the very tools needed
   to diagnose and repair it — and those tools are *built by this flake*, so they would be
   broken by exactly the change that needs undoing. The flake path needs only git and nix: no
   control plane, no config cascade, no manager binaries. It is the one build in the estate with
   no dependency on TAPPaaS itself.

2. **The mothership's OS and its own software move as one atomic build.** The flake produces
   both `nixosConfigurations.tappaas-cicd` and the eleven managers and controllers as packages,
   from the same pinned nixpkgs. So a rebuild can never leave managers compiled against one
   package set running on a system built from another — a split that would be invisible until
   something crashed at 2am. One build, one revision, both halves.

3. **A failed upgrade is one rollback away.** Because this is an ordinary NixOS system build, the
   previous generation is still on disk and bootable. The recovery story for the control plane is
   "boot the last generation", not "restore the VM and hope".

4. **The recovery path is the everyday path, so it cannot rot.** `bootstrap.sh` uses the same
   command on day one that `tappaas-self-rebuild.sh` uses every night. A recovery mechanism
   exercised only during recovery is a recovery mechanism that has quietly stopped working.

What the mothership does *not* need is a second **pin**. Its flake can follow the estate's
without giving up any of the four properties above: the `follows` line changes where the
revision comes from, not how the system is built.

So: **separate build path, shared pin.** Divergence becomes structurally impossible rather than
something a check has to notice afterwards.

**Built 2026-09-23.** `tappaas-cicd/flake.nix` declares no nixpkgs of its own; its lock records
`nixpkgs → templates/nixpkgs`. Verified on the test site: the configuration evaluates to the
**same derivation** as before the change (`…-nixos-system-tappaas-cicd-25.11.20260522.b77b3de`),
as root with the rebuild's own `HOME`, so the mothership it builds is bit-identical today and
the change is purely structural. The suite asserts both halves — the flake follows, and the two
locks name the same revision.

**One consequence, worth knowing before it surprises someone.** A relative path input resolves
against the **git tree**, not the flake directory. Both flakes must therefore stay in this
repository, and the mothership's flake can no longer be built from a copy that is not a git
checkout — outside one, `path:../templates` resolves to `/nix/store/templates` and evaluation
fails with "access to absolute path … is forbidden". The sweep is unaffected, because it builds
from `~/TAPPaaS`; a scratch copy made by `tar` is not.

### D2 — One rhythm: bump every train boundary, deep-test every time

**Every two weeks**, at the train boundary (D9): `nix flake update` on the estate pin, a full
`--deep` test on the test site, then promote. Not a patch cadence and a separate branch cadence
— **one beat**. The unstable channel may take a revision more often than that if there is reason to; the
boundary is what *promotes*, and it is the only commitment being made here.

A **version** move (`flake.nix`, e.g. `nixos-25.11` → `nixos-26.05`) is not a different rhythm;
it is the week where the bump is bigger, taken when the new release exists. Sitting on the old
branch buys nothing: once the successor ships, the old branch stops receiving anything worth
having, and the longer the wait the larger and more frightening the eventual move. Weekly bumps
keep the diff small; a branch week is the one week the diff is large, and it is *still* the same
process.

Two facts qualify this, neither of which changes the beat:

- **The old branch's backports do not stop dead on release day.** NixOS keeps backporting to the
  previous release for roughly a month after its successor ships. That overlap is slack for a
  missed week around release time, not a reason to linger: at the end of it the branch is dead,
  which is exactly how this estate ended up three months past EOL.
- **A branch week may need code changes.** Options get renamed and packages get dropped between
  releases, so a version bump can fail to build or to evaluate until modules are adjusted
  (#709 is a live instance). That week's branch therefore may live a few days rather than an
  afternoon. It is a longer week, not a second rhythm.

**Why a short beat is affordable, and why it is safer than a long one.** The test is automated —
a sweep plus `site-manager test --deep` on the test site is about an hour, unattended. Small
diffs fail in ways you can read; a quarter of accumulated nixpkgs changes fails in ways you
bisect. And the
estate already has the safety net that makes frequent bumps reasonable: a module update takes a
snapshot, rebuilds, runs the module's tests, and rolls the guest back when they fail. **That net
covers guests but not the control plane — see D10, which this cadence depends on.**

### D3 — The ref is always a channel branch, and the lock always a Hydra-built revision

`flake.nix` points at a `nixos-*` branch — never `nixpkgs-unstable`, never a bare commit from
`master`. Those branches are what Hydra has built, so `cache.nixos.org` carries binaries and each
guest substitutes them. A revision Hydra has not built means every guest compiles from source on
a two-core VM, which turns a routine patch into an estate-wide outage.

### D4 — A tripwire, tighter than the cadence

The pin-age check introduced with #680 reports the estate pin's age on every sweep and in the
suite. Two changes:

- it reads the **estate pin** (D1), which governs every guest, not only the mothership's lock;
- its warning threshold is **45 days**, not 90. A tripwire looser than the policy it guards can
  never catch a missed cycle; it must fire while the next one is still due.

**Built 2026-09-23**, together with D1 — the same check now also fails when the mothership's
lock resolves nixpkgs itself rather than following the estate pin, so a second pin re-added by
hand is caught by the suite rather than by a divergence months later.

It stays **non-fatal**. A stale pin is a release decision, and failing there would abort a
healthy site's update — the #694 lesson.

This check detects branch EOL for free: a frozen branch cannot refresh its `lastModified`, so
`nix flake update` leaves the date untouched and the lock simply keeps ageing. The "122 days old"
line in the sweep of 2026-09-21 *was* the EOL signal, read correctly for the first time here.

### D5 — Debian and Ubuntu: rolling patches, explicit releases

**Security patches are automatic**, by three paths that differ in more than spelling:

| What | Command | Where |
|---|---|---|
| a Debian/Ubuntu **guest** (a VM the cluster hosts) | `apt-get update` + `apt-get -y upgrade` | `update-os.sh:583-592`, each sweep |
| a managed **machine** — `debianhost`, and a managed satellite, which delegates to it | `apt-get update` + `apt-get -y full-upgrade`, keeping local config files (`--force-confdef`, `--force-confold`) | `debianhost/update.sh:28`, each sweep |
| a **locked-down (unmanaged) satellite** — the off-site vault | `unattended-upgrades`, security-only, with its own reboot window | on the machine itself; nothing at home can log in to it (ADR-010 §7.3, §8.4.4) |

The distinction between `upgrade` and `full-upgrade` is deliberate and worth keeping: `upgrade`
never adds or removes a package, so it cannot resolve a changed dependency; `full-upgrade` will.
A guest is a disposable workload we can rebuild; a machine is not, and its packages are expected
to move as a set.

No pin, no cadence decision, no TAPPaaS release is needed for any of the three: the
distribution's archive is the source of truth and its security team sets the pace. The vault
keeps patching itself even while it refuses every login from home — which is the point of it.

**Distribution release upgrades are not automatic and must not become so.** `apt-get upgrade`
never crosses a release boundary (it is deliberately not `dist-upgrade`, and not
`do-release-upgrade`). Moving a Debian guest from one release to the next is an explicit,
tested, per-module operation with the same standing as a NixOS branch move, and it is out of
scope for the sweep.

**The consequence worth stating plainly:** a Debian guest is patched by default and a NixOS
guest is frozen by default. The safety of the NixOS half rests entirely on D2 being *performed*.
Nothing in the machinery will chase it.

### D6 — Application majors are separate from OS majors

A module may pin an application major independently of the OS — `ncMajor = 33` in
`nextcloud.nix` is the worked example, driving both the package and its app-set. Rules:

- Application majors move **one at a time** where the application requires it (Nextcloud refuses
  to skip: 33 → 34 → 35), each with its own `update-module.sh` run, as the module's `UPGRADE.md`
  documents.
- An application major bump is a **separate change** from the OS branch move, landed after it,
  never folded into it.
- A module does **not** carry its own nixpkgs pin for this (D7). Where an application major is
  only available on a newer branch, that is a request for a branch move (D2), which is exactly
  what #709 is.

### D7 — No module pins its own base; if we ever allow it, it owns its own CVEs

Today a module cannot choose its nixpkgs: `update-os.sh` passes `-I nixpkgs=` and that wins over
anything the guest declares. This is stated here because the opposite is a natural assumption,
and advice to "bring your own flake" would silently not work.

**The satellite's `--os nixos` path was the one place a second base still existed. It is gone**
— retired on 2026-09-22 (#712), with `flake.nix`, `disk-config.nix`, `satellite.nix` and
`satellite-settings.nix` deleted and `os` accepting only `debian`. It had tracked `nixos-25.05`
with no lock file, no test in the module's suite exercised it, and the `backup` role refused it
outright, so choosing it produced an unpinned, untested machine that could not be the vault a
satellite mostly exists to be. ADR-010 §5.1 is amended to match; the diversity argument that
originally kept it is untouched, because the default is Debian.

### D8 — A kernel change is not applied until the reboot

`nixos-rebuild switch` activates userspace immediately and restarts changed services; a new
kernel takes effect only at the next boot. A patch refresh that carries a kernel fix is therefore
not complete until the sweep's reboot pass has run, governed by `rebootOk` (ADR-020 D8).

When an out-of-band bump is made *for* a kernel CVE, the reboot is part of the remediation and
must be planned with it — not left to whenever a module next happens to restart.

**A RELEASE move needs a reboot for a second reason, and in both directions.** Measured on the
test site, 2026-09-23, moving 25.11 → 26.05: `switch-to-configuration` cannot reload
`dbus-broker` in place across a release. The switch applies correctly and then reports exit 4
over the failed reload — and the rollback, which is the *old* generation's
`switch-to-configuration`, live-locks at 100% CPU attempting the same thing in reverse (#725).
A boot has nothing to reload: it activates from scratch.

So on the mothership a release move is **staged** with `nixos-rebuild boot` and taken at the next
start, rather than switched in place. The running system is untouched until it reboots, which
makes this the safer operation as well as the only one that works: a staged generation that is
never booted costs nothing, where a half-applied switch costs the control plane. The reboot is
governed by `automaticReboot`, the same gate the cluster reboot pass uses; with it off the move
is staged, reported, and the sweep stops. A boundary interrupted this way resumes with
`tappaas-train boundary --resume`.

---

### D9 — Guests before the mothership, and a three-channel train

#### Within a bump: prove it on a guest before risking the control plane

The mothership rebuilds **first** in a normal sweep — the self-rebuild is an `ExecStartPre`
(ADR-017 D3) — so by default the machine that runs everything is the first to meet a new
revision. During a *bump's validation* that order is avoidable, and should be avoided. No code
change is needed: on the test site, with the branch checked out,

1. `update-module.sh <guest>` for a representative NixOS guest — this rebuilds that guest against
   the new pin while the mothership is still on the old one;
2. read the result; a guest that fails here is snapshot-rolled back automatically, and the
   control plane is untouched and still able to investigate;
3. only then run the sweep, which rebuilds the mothership and everything else.

So the rule for a bump's validation is: **a guest proves the revision before the mothership
takes it.**

Why this is a validation procedure and not a change to the sweep's order: the self-rebuild goes
first *by design*, because it delivers the managers the rest of the run uses. Moving it to the
end would make every sweep run new module scripts from the freshly pulled checkout against last
generation's manager binaries — a version skew ADR-017 D3 exists to prevent. The answer is to
order the *testing*, not to reorder the run.

#### Between sites: the train does the rest of the staging

Three channels, two-week boundaries. **The channel is what a site runs; the branch is where the
code sits** — they are named differently on purpose, because "stable" as a channel promise and
`stable` as a git ref are not the same statement:

| Channel | Git branch | Who runs it | What it is |
|---|---|---|---|
| **unstable** | `main` | the test site | where development happens and where a new nixpkgs revision is first taken |
| **staging** | `staging` | a few production and pre-production sites | the previous *unstable*, soaking under real use |
| **production** | `stable` | everyone else | the previous *staging* |

At each two-week boundary, in order:

1. **staging → production** (`staging` fast-forwards `stable`).
2. **unstable takes the latest NixOS** (`nix flake update`, and `flake.nix` too when a new release
   exists) and gets a full `--deep` test, guest-first per the rule above.
3. **unstable → staging** (`main` fast-forwards `staging`).

A revision therefore spends two weeks in **staging** under real load before any production site
sees it, and production is at most **two boundaries — four weeks — behind** on patches. That is
the compromise this ADR proposes: currency traded for two weeks of soak on sites whose operators
know they are soaking.

**If step 2's `--deep` fails, the pin does not promote.** Staging is cut from unstable *without*
the bump — the feature work still promotes, the revision waits, and the fix is worked in unstable
for the next boundary. A failing revision must never be the reason a fortnight of work misses its
train, and a fortnight of work must never drag a failing revision with it.

**A high-severity CVE accelerates the train; it does not bypass it.** Pull the boundary forward
and run the sequence early, rather than cherry-picking a lock onto `stable`. This is the better
instrument for a reason worth stating: **a cherry-picked pin arrives next to code it was never
built against.** A revision that needs a renamed option or a replaced package is only safe beside
the module changes made for it, and those live on `main`. Moving the whole train keeps every
revision with the code that proved it — which is also why the earlier draft's worry ("nothing
runs the production branch, so an out-of-band bump cannot be tested against it") disappears:
nothing needs to be tested against `stable`'s code, because nothing lands on `stable` that did
not arrive through staging.

#### A fault found in staging: patch forward, and block promotion

Staging exists to find faults, so finding one is staging working, not an incident. What must not
happen is the fault reaching production, or being fixed in a way that lets the next train carry
it back.

- **Promotion to production is blocked** until it is resolved. The next boundary refuses, naming
  the fault. Staging keeps the revision; production keeps what it already has.
- **Nothing moves backwards.** §10.2 rule 5 already promises that of `stable`; this extends it to
  `staging`. A channel that can be rewound is not a channel an operator can plan against, and a
  rewind discards the fortnight of soak that made the fault visible in the first place.
- **The resolution lands on `main`**, wherever it was authored. A hotfix applied to `staging` is
  back-ported before the block lifts — otherwise the next boundary promotes `main` into `staging`
  and reintroduces precisely the fault just fixed. "Resolved" therefore means *the fix is an
  ancestor of `main`*, which is a checkable fact rather than an intention.

The general principle, of which this is one case: **patch forward.** The estate's way back is a
guest snapshot (`update-module.sh`) or a NixOS generation (D10) — machine-level, immediate, and
local. A *channel* never reverses.

How a boundary is performed, and which refusals enforce this rule, is designed in
[release-train-promotion.md](../design/release-train-promotion.md).

### D10 — The control plane needs a net before the cadence leans on one

A short bump cadence is defensible because a bad revision is caught and undone. That is true of guests
and **not** true of the mothership:

| | on a bad revision |
|---|---|
| a guest | `update-module.sh` snapshots, rebuilds, runs the module's tests, and **rolls the guest back** when they fail |
| the mothership | `tappaas-self-rebuild.sh` runs `nixos-rebuild switch`. A non-zero exit aborts the sweep and fires the failure notice — but a rebuild that **succeeds into a subtly broken system** is not noticed at all, and nothing rolls it back |

The mothership also goes **first** — the self-rebuild is an `ExecStartPre` of the sweep (ADR-017
D3) — so it is the machine most exposed to a new revision and the one with no net, twenty-six
times a year instead of twice.

NixOS makes the net cheap, because the previous generation is already on disk. After the switch:
run a health check (the control-plane checks the suite already has — managers answer, the
config cascade resolves, the forge is reachable); on failure, `nixos-rebuild --rollback`, notify,
and abort the sweep rather than running the estate from a system that just failed its own tests.

**Built 2026-09-22 (#713).** `tappaas-selfcheck.sh` answers "does the control plane work?" in
about a second — the seven managers this flake built still run, the module catalogue still
resolves, and no unit failed that was not already failing (a delta against a baseline recorded
before the switch, because a site can carry an unrelated failure for days; the sweep's own unit
is excluded, since the check runs inside it). `tappaas-self-rebuild.sh` captures the outgoing
generation by path *before* switching and, when the check fails, activates it again with its own
`switch-to-configuration` and **aborts the sweep** — the estate is not updated from a control
plane that just failed its own check. A rollback that itself fails is loud and prints the manual
command rather than reporting recovery.

With that in place the cadence of D2 is defensible for the mothership as well as the guests: it
is the last machine in the estate to gain a way back, and it now has one.

## Consequences

- One `nix flake update`, reviewed and tested once, patches the mothership and every guest on
  their next sweep. Two locks become one decision.
- The estate can still be staged deliberately — a branch move may be proven on the test site
  before the main site pulls it — because staging is a matter of *when each site pulls*, not of
  keeping two pins that might differ by accident.
- The 45-day tripwire will fire immediately and keep firing until D2 is performed for the first
  time. That is the intended behaviour: it is reporting a real, three-month-old gap.
- Debian guests are unaffected by all of this and keep patching themselves.

## Alternatives considered

**Run `nix flake update` from `tappaas-cicd/update.sh` on each site.** Rejected. It patches only
the mothership; it dirties a tracked file so the next sweep's `git pull --ff-only` fails, which
under ADR-017 D3 aborts the run; it makes each site resolve its own revision at whatever minute
its sweep fired, destroying the reproducibility the pin exists for; and it applies an untested
kernel and service restart straight to production on a schedule.

**Merge the two flakes into one.** Rejected. A root-level flake copies the whole repository into
the nix store on every evaluation, and a single flake removes the ability to stage the mothership
behind the guests during a branch move. D1 gets the one-pin guarantee without either cost.

**Assert the two locks are equal in the test suite.** Superseded by D1: a check detects the split
after it happens, `follows` prevents it.

---

## Open questions for review

1. **The existing release machinery.** D9's three refs — `main`, `staging`, `stable` — absorb the
   `rc/<ver>` step of §10.2 rule 2 into the staging channel. Whether `rc/<ver>` tags survive as
   release markers, or the boundary itself becomes the release event, is not settled here.

2. **Who runs staging, and do they know what they signed up for?** The plan's safety rests on "a
   few production and pre-production sites" taking a revision two weeks before everyone else.
   That is a real commitment by real operators, and it should be recorded per site (a channel
   field in `site.json`, naming `unstable` / `staging` / `production`), not held as a shared
   understanding.

3. ~~**Does D10 land before the cadence changes?**~~ **Answered: it landed first** (#713,
   2026-09-22). The remaining judgement is what else belongs in the check — it deliberately
   avoids anything needing the network, so a provider outage cannot trigger a rollback.

4. ~~**What does a staging site do when it finds the fault?**~~ **Answered (2026-09-23): patch
   forward, and block promotion.** Now D9's *"a fault found in staging"* rule.

5. **Retire the satellite's `--os nixos` path, or fund it?** D7 proposes deletion (#712). It is
   retained by ADR-010 §5.1, so retiring it amends that ADR — and the stated reason for keeping
   it was **OS diversity for the vault**: a nixpkgs or `nixos-anywhere` supply-chain compromise
   would hit the NixOS cluster but not a Debian vault (ADR-010 §7.3). That argument survives
   deletion intact, because the default *is* Debian; what dies is only the ability to choose
   NixOS for a satellite, which nothing tests and the vault role already refuses.

6. **Whether 26.05 is the branch to move to**, or whether to wait for 26.11 given how late in the
   cycle we are. #709 needs 26.05 for Nextcloud 34/35; that is an argument for moving now and
   again in a few months, which makes the first performance of D2's version move unusually close
   to the second.
