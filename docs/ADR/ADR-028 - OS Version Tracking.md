# ADR-028 — OS Version Tracking

| | |
|---|---|
| **Status** | **Proposed** (2026-09-22) |
| **Version** | 0.1 |
| **Date** | 2026-09-22 |
| **Author** | Lars Rossen |
| **Related** | **#680** (the baseline lock decides every site's nixpkgs; its code half landed, its cadence half is this ADR) · **#709** (Nextcloud cannot advance past 33 on a frozen branch — the first concrete demand for a branch move) · **#324** (modules copy the baseline instead of importing it) · **#675** (no extension point for a site's own NixOS modules) · **#166** (the earlier single-path clock fix) · [ADR-017](<ADR-017 - Update scheduling and mothership self-update.md>) D3 (the mothership rebuilds itself from the checkout, before the sweep) · [ADR-020](<ADR-020 - Declared-Field Change Model (validate, drift, modify).md>) D8 (`rebootOk` — whether a kernel change may land) · [ADR-025](<ADR-025 - Config migrations and the upgrade path.md>) (how a release brings `config/` forward; this ADR is its counterpart for the OS) · [ADR-026](<ADR-026 - Managed Machines as Modules.md>) (`debianhost` and the machine OS lifecycle) |
| **Changelog** | v0.1 (2026-09-22) — first draft, from the operator's questions of 2026-09-22 and a read of the shipped code. |

How a TAPPaaS system decides which operating-system bits it runs, when security patches arrive, and when a major version moves.

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
| `satellite/flake.nix` | `nixos-25.05` | **no lock file at all** | nothing by default — the optional `--os nixos` path only (see D7) |

Three observations, each of which a decision below answers:

1. The first two are byte-identical today. Nothing keeps them so — they are two files, refreshed
   by hand, and #709 proposes moving one of them.
2. `nixos-25.11` went end-of-life around the end of June 2026 (its last commit is
   2026-06-30). We are running an unsupported branch, and have been for roughly three months.
   **A frozen branch cannot deliver a security backport, so the NixOS half of the estate has had
   no security patches since May.**
3. The satellite is **Debian**, not NixOS (ADR-010 §5.1, reversed during implementation as
   impl-doc D19/Q8; `satellite.json` declares `"os": "debian"` and `satellite-lib.sh` defaults to
   it). It therefore patches itself like any Debian machine and is *not* affected by the frozen
   pin. The NixOS files in that module back the retained-but-unused `--os nixos` option, which
   D7 addresses.

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

The mothership **keeps its own build path** — `nixos-rebuild switch --flake .#tappaas-cicd`,
used by both `bootstrap.sh` and `tappaas-self-rebuild.sh`. That path needs only git and nix: not
`update-os.sh`, not `module-manager`, not a working control plane. The mothership is the one
machine that must be able to repair itself when the machinery it normally runs is broken, and a
circular dependency there is not worth removing a file for.

So: **separate build path, shared pin.** Divergence becomes structurally impossible rather than
something a check has to notice afterwards.

The satellite joins the same pin (see D7).

### D2 — Two rhythms, and they are different rhythms

| Rhythm | What moves | Cadence | Why that cadence |
|---|---|---|---|
| **Patch** | `flake.lock` — a newer revision of the same branch | **monthly**, plus out-of-band for a high-severity CVE in an exposed component (kernel, openssl, nginx, sshd) | A lock bump is all-or-nothing across the estate: one cannot patch a single guest. Batching costs twelve reviewed upgrades a year instead of fifty-two, and every one of them should be read by a person. Quarterly would leave a 90-day window on internet-facing services, which is not defensible. |
| **Branch** | `flake.nix` — the release branch itself | **within one month of each NixOS release**, i.e. roughly every six months, before the old branch goes EOL | NixOS ships twice a year and supports a release until about a month after its successor. Missing that window is what put us three months past EOL with no patch path at all. |

A patch refresh is `nix flake update`, which rewrites the **lock** and never `flake.nix`. A
branch move edits `flake.nix` and then updates the lock. Both are ordinary code changes: tested
on the test site, committed, pushed, and picked up by each site's sweep through its normal pull.

**Severity overrides cadence.** The monthly beat covers the baseline; a serious CVE in an
exposed component is bumped when it lands, not at month end.

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

**The satellite's `--os nixos` path is the one place a second base still exists, and it should
go.** ADR-010 §5.1 retained it when the implementation reversed to Debian (impl-doc D19/Q8), and
what is left of it has quietly rotted: `satellite/flake.nix` tracks `nixos-25.05` — a branch
EOL since around the end of 2025 — with **no lock file**, so each deployment would resolve
whatever that dead branch last held; the module's own test suite does not mention NixOS once;
and the vault role refuses it outright (`satellite-lib.sh:294` — "the vault is the Debian
satellite's"). A retained option that is untested, unpinned and unsupported by the role most
people want is not an option, it is a trap for whoever tries it.

The decision this ADR asks for: **retire `--os nixos`** — delete `flake.nix`, `disk-config.nix`,
`satellite.nix`, `satellite-settings.nix` and the `nixos-anywhere` branch of
`satellite-lib.sh`, and amend ADR-010 §5.1 accordingly — unless someone intends to test and pin
it, in which case it joins the estate pin under D1 like everything else. It cannot stay as it is.

Should a per-module base ever be introduced — a module declaring that it owns its own base — it
comes with three obligations: the module owns its own security currency, the health output
reports which guests are off the estate pin, and the divergence is visible in the site's own
reporting rather than buried in a `.nix`. This is the same missing-extension-point family as
#675 and should be decided with it, not separately.

### D8 — A kernel change is not applied until the reboot

`nixos-rebuild switch` activates userspace immediately and restarts changed services; a new
kernel takes effect only at the next boot. A patch refresh that carries a kernel fix is therefore
not complete until the sweep's reboot pass has run, governed by `rebootOk` (ADR-020 D8).

When an out-of-band bump is made *for* a kernel CVE, the reboot is part of the remediation and
must be planned with it — not left to whenever a module next happens to restart.

---

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

1. **Cadence numbers.** Monthly patch / six-monthly branch is a recommendation, not a
   measurement. If the hrossen sweep plus deep test proves reliable enough to run unattended,
   fortnightly patching is affordable.
2. **Who holds the calendar.** D2 only works if someone is answerable for it. The 45-day
   tripwire reports the slip; it does not assign it.
3. **Retire the satellite's `--os nixos` path, or fund it?** D7 proposes deletion. It is
   retained by ADR-010 §5.1, so retiring it amends that ADR — and the stated reason for keeping
   it was **OS diversity for the vault**: a nixpkgs or `nixos-anywhere` supply-chain compromise
   would hit the NixOS cluster but not a Debian vault (ADR-010 §7.3). That argument survives
   deletion intact, because the default *is* Debian; what dies is only the ability to choose
   NixOS for a satellite, which nothing tests and the vault role already refuses.
4. **Whether 26.05 is the branch to move to**, or whether to wait for 26.11 given how late in the
   cycle we are. #709 needs 26.05 for Nextcloud 34/35; that is an argument for moving now and
   again in a few months, which makes the first performance of D2's branch rhythm unusually
   close to the second.
