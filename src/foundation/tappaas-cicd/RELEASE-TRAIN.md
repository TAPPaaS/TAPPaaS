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

## Signing releases (ADR-033)

Every release tag carries `tree-sha256:` — a SHA-256 over the content of every file in the
revision — and `signers-at:`, the commit whose `.tappaas/allowed_signers` authorizes it. Once
that file lists a key, every tag the train cuts **must be signed**: `boundary` and `patch` check
for a signing key before any channel moves, refuse without one, and check the signature against
the listed keys before publishing the tag.

A site on staging or production then moves only to a tag that verifies: signed by a key listed
in the **last release it verified**, tree hash matching, and not older than what it runs. Sites
on `main` are not verified. `health-manager validate` reports each repository's status
(`signature-status`), and `~/config/sbom/signatures.json` is the record.

**Enrolling a key** (once a year per signer). Each signer's key lives in their own Bitwarden or
Vaultwarden vault, and signs through the Bitwarden desktop app's SSH agent, which asks you to
approve every signature:

1. In the Bitwarden desktop app: *New → SSH key*, type ed25519, name it `tappaas-release-<year>`.
   Turn on the SSH agent in its settings, set to ask for approval on every use.
2. Copy its public key into [`.tappaas/allowed_signers`](../../../.tappaas/allowed_signers) with a
   `valid-before` one year out (the format is in that file), add a row to
   [`.tappaas/SIGNERS.md`](../../../.tappaas/SIGNERS.md), and land it on `main`.
3. It counts from the release **after** the one that carries it. The release that adds the first
   keys is the last unsigned one; a yearly replacement goes in while the old key still works.

Keep the vault behind two-factor login, and not on a TAPPaaS site that these releases update.
`health-manager validate` warns 60 days before a key expires.

**Signing a boundary.** The train runs on the mothership; the key stays in your vault. Forward
your agent and tell git which key to ask it for:

```bash
ssh -A tappaas@<mothership>                    # with the Bitwarden agent running on your laptop
git -C ~/TAPPaaS config user.signingkey "key::<your public key>"   # once, on the mothership
tappaas-train.sh boundary                      # approve the signature when the agent asks
```

**Retiring a key**: give its line `valid-before="YYYYMMDD"`. Do not delete it — the releases it
signed would stop verifying. A stolen key gets `valid-before` of today, in an urgent fix
(`tappaas-train.sh patch … --why "security: signing key stolen"`) signed by the other signer.

**The recovery key** — for when both signers have lost their keys. It is listed as
`recovery@tappaas.org` and may sign **only** a release that changes nothing outside `.tappaas/`;
on anything else its signature fails verification. Made once, offline:

```bash
ssh-keygen -t ed25519 -C recovery-offline -f tappaas-recovery     # on a machine with no network; set a passphrase
```

Its public key goes into `allowed_signers` (no `valid-before`). The private key is kept offline in
two places you both control — an encrypted USB stick in a safe and a paper copy — and **not** in
either everyday vault. To use it: a branch off the channel's tip that only edits
`allowed_signers` (new keys in, lost ones retired), merged to `main`, then

```bash
git -C ~/TAPPaaS config user.signingkey /path/to/tappaas-recovery
tappaas-train.sh patch staging <commit> --why "security: signer recovery"
tappaas-train.sh patch production <commit> --why "security: signer recovery"
git -C ~/TAPPaaS config --unset user.signingkey                  # and take the key offline again
```

The next boundary is signed with the new keys. If the recovery key is lost too, no release can
be verified again: publish the new fingerprints out of band, and every operator re-anchors their
site by hand (ADR-033 D4b).

### Signing image releases

The VM images (`nixos-template-v*`, `opnsense-firewall-v*`) are checked by hash: the image
pointers (`templates/tappaas-nixos.json`, `network/network.json`) carry `imageSha256` next to
`imageLocation`, and the install refuses a download that does not match before importing it. The
build checks its own inputs first — the OPNsense base image against the digest its publisher
states, the NixOS build against the hashes in `flake.lock` — and publishes `SHA256SUMS` with the
release. CI cannot sign it (the key stays in your vault), so after the build, with the Bitwarden
agent running:

```bash
release/sign-image-release.sh nixos-template-v1.5   # checks SHA256SUMS; approve the signature in your SSH agent
release/bump-version.sh --nixos 1.5                 # checks the signature, writes the URL and the SHA-256
```

`sign-image-release.sh` uses `git config user.signingkey` unless given `--key`, refuses a
`SHA256SUMS` that does not list every artefact with the digest GitHub recorded, and checks the
signature against `.tappaas/allowed_signers` (namespace `tappaas-image`) before uploading
`SHA256SUMS.sig`. The recovery key is listed for `git` only, so it cannot sign images.
`--dry-run` signs without uploading; `--generate` backfills a release built before `SHA256SUMS`
was published. Once `allowed_signers` lists a key, `bump-version.sh` refuses an unsigned
`SHA256SUMS`. Anyone can check a download by hand:

```bash
ssh-keygen -Y verify -f .tappaas/allowed_signers -I lars@tappaas.org -n tappaas-image \
  -s SHA256SUMS.sig < SHA256SUMS && sha256sum -c SHA256SUMS
```

To move the OPNsense base image, change `OPNSENSE_BASE_URL` and `OPNSENSE_BASE_SHA256` together in
`.github/workflows/build-opnsense-image.yml`; the build stops when the pin differs from the
upstream release's digest. `cluster/make-install-media.sh` checks the Proxmox ISO against
Proxmox's `SHA256SUMS` (or `--iso-sha256`) and the install assistant through Proxmox's signed
repository index.

## One pin for the estate

Every TAPPaaS-managed NixOS system — the mothership and all its guests — is built from the single
nixpkgs revision in `src/foundation/templates/flake.lock`. The mothership cannot choose a
different one; it follows that lock through a relative path input. Phase 1 re-locks both flakes
and refuses if the two resolve differently, because a control plane on a different revision from
its guests is a split nobody would notice until something broke.

Debian guests are not part of this: they patch themselves between releases (`apt-get upgrade` on
the daily sweep, `unattended-upgrades` where a guest is locked down).

## Before a boundary: the release CVE preview and ack (#788)

A boundary proves a release by running it — a guest first, then the sweep, then the deep test —
which takes hours. What the release *changes* is known in minutes: `preview` compares the **last
release** with **"if released now"** — this tree, the pin the next boundary takes and its image
pins — module by module, with today's CVE database on both sides, so the difference is what the
release changes and not what was published meanwhile. Nothing is built and nothing moves.

```bash
tappaas-train.sh preview                        # last release vs now, next patch pin
tappaas-train.sh preview --to nixos-26.11       # … with a release move
tappaas-train.sh preview --since v2.0           # against an older release
tappaas-train.sh preview --module openwebui     # one module, CVE by CVE (from the last preview)
tappaas-train.sh ack --module nextcloud --note "read the Nextcloud 35 notes"
tappaas-train.sh ack --note "everything else: reviewed in the preview"
```

| Option | Meaning |
|--------|---------|
| `preview` | The last release (the newest `v*` tag) against "if released now". Prints the table, writes `config/train-preview.json`. |
| `preview --to <nixos-XX.YY>` | "Now" moves to that release branch: a version move. |
| `preview --since <vX.Y>` | Compare with that release instead of the newest. |
| `preview --no-pin-move` | "Now" keeps the pin already in the tree: what this tree ships today. For every module that runs here it then says whether NOW agrees with the nightly scan's count (same matcher, same VEX, counted by CVE id) and names any CVE only one of them has. |
| `preview --details-file <f>` | Write the per-module details there instead of `config/train-preview-details.json`. |
| `preview --module <name>` | Show one module from the last preview's details, without recomputing: the image (both sides), the packages that change, and its critical/high CVEs in three lists — **NEW** (in now, not in the release), **FIXED** (in the release, gone now) and **SAME** — each with package, version, severity and whether it comes from the NixOS system or the image. |
| `ack` | Accept what the last `preview` gates: majors, critical/high CVEs new against the release, a failed match. |
| `ack --note "<why>"` | The same, with the reason recorded beside it. |
| `ack --module <name> --note "<why>"` | Accept one module's items only: its new CVEs and the majors it ships (`baseline` for the shared row). Acks add up, each with its note; the preview's ACK column shows them. |

**The table** — critical/high **CVEs** per module (a CVE that hits two packages counts once,
as in the nightly `health-manager scan security`), "if released now" first:

```
  MODULE                OPEN  RISK  ACK   NOW │   V2.1  FIXED  DECIDED   NEW │  VEX  NOTE
  NixOS baseline          26     0    0    26 │     31      5        0     0 │   29  the package versions every NixOS module ships
  openwebui              142     0    0   142 │    231     89        0     0 │    0
  immich                   0     9    0     9 │      —      0        0     9 │   33  risk medium; new since v2.1
  identity                 0     5    0     5 │    204    179       21     1 │   26  risk low
  coturn                   0     0    0     0 │      0      0        0     0 │    0
  …
  — the platform: patched by its own channel, not by a release — now, from the last scan —
  pvehost ×3             131     0    —   131 │                              │    4  tappaas1 130 · tappaas3 130 · tappaas2 130
  Debian LXC              89     0    —    89 │                              │    0  used by vllm-amd
  network (firewall)      29     0    —    29 │                              │    0
  backup (on tappaas3)                      — │                              │       installed as packages; Proxmox's have no CVE feed…
```

- **The row adds up: NOW = V2.1 − FIXED − DECIDED + NEW.** FIXED: in the release, gone from what
  ships now. DECIDED: in the release, still shipped, but settled since by a VEX statement — not
  fixed, so not FIXED, and not in NOW (identity: 204 − 179 − 21 + 1 = 5). SAME (in both, still
  counted) is not a column — it is NOW minus NEW; `preview --module` lists it.
- **OPEN · RISK · ACK = NOW.** OPEN: nobody has analysed it. RISK: analysed and still counted —
  an `exploitable` statement in `<module>-vex.json` (or `templates-vex.json`), whose
  `ratings[]` entry with source `TAPPaaS` gives the risk in this deployment (the NOTE shows the
  worst). ACK: accepted for this release with `ack`. VEX (decided not affected) is not in NOW.
- **The NixOS baseline** is one row (`baseline` to `ack --module` and `cve-triage.sh`): the package versions of `templates/tappaas-common.nix` (evaluated
  as an empty module) that every NixOS module ships — glibc, vim. A module's row is what it
  adds; a module on another version of a baseline package carries that version's CVEs itself.
  The MODULES total counts the baseline once.
- **The mothership** is a module like the others: its system is evaluated in place on both
  sides (it reads this machine's `/etc/nixos`).
- **The gate** names its module: `cve <module> <CVE>` (`cve baseline <CVE>` for the shared row)
  and `major <pkg> a->b`; the last line says what is left to acknowledge, by module.
- **VEX**: the same triage statements the nightly scan applies (`<module>-vex.json` next to each
  module, deciding for that module only; the shared NixOS baseline's in `templates-vex.json`, for
  every module) apply here too, to both sides. A
  CVE a statement decided is not in NOW: the `VEX` column counts it apart, `preview --module`
  lists it, and it needs no ack.
- **Every module counts the same**, whatever it is built from: a NixOS guest's packages and a
  container image's (from `src/image-pins.json`, read at the release's tag and in this tree) are
  matched alike. Every module TAPPaaS ships counts — every NixOS system in the tree except the
  template, the mothership, `00-Template` and test fixtures, and every pinned image.
- **≈ approximate**: a module that runs nowhere here has no inventory to say which of its
  packages run. The train then builds its system (mostly fetched; its config files built) and
  counts its runtime closure — exact, no mark. Only when that build fails or takes longer than
  15 minutes (`PREVIEW_BUILD_TIMEOUT`) is it counted from its `.drv` closure by the package names
  that run elsewhere, marked ≈ — which can include build inputs (deconz's showed ffmpeg through
  qemu's full build, where a guest runs only qemu's guest-agent output).
- **The platform**: the nodes, Debian guests and the firewall patch by their own channel and are
  not part of a release. Their row has only "now", from the
  last `health-manager scan security`, and they are in the TOTAL. One row per module, however many
  instances run it: the site's nodes (whichever are deployed) are one `pvehost ×N` row counting
  each CVE once, every node's own count beside it. The Debian LXC a module runs its image in
  (vllm-amd) is a "Debian LXC" row saying which module uses it; the module's own row is its
  image. A module installed on a node as packages (backup) has its own row, marked as covered by
  no feed. OPEN, RISK and VEX come from the scan (an `exploitable` statement in, say,
  `pvehost-vex.json` is RISK); ACK is "—": the platform is not released, so nothing to accept.
- **The details** (`config/train-preview-details.json`) hold, per module, every critical/high CVE
  of both sides with its package and version, the image references and the changed package
  versions: the input for working out what to fix (`preview --module`, or `jq`).
- A past release is evaluated **as it was built** (`--as-is`: before #324 its modules carried
  their own baseline), against its own pin.

**Majors.** A package whose first version number changes since the release — except where that
number is a date or a sequence (100 or more: `20260107`, less `692`, systemd `260`), and the
packages `release/pin-watch-ignore.json` lists with their reason. Those are reported as "not
counted as major", never hidden; a major that goes *down* is labelled a downgrade.

**What a boundary does with it.** Right after phase 1 moves the pin — before the deep test — the
boundary computes the same comparison for the pin it actually took:

- nothing to acknowledge: it goes on, **no ack needed**;
- everything gated is covered by the last `ack`: it goes on;
- anything not covered: it **stops** before the deep test, names the new items, and leaves the
  checkout clean. Run `preview`, read the upstream notes, `ack`, run the boundary again.

The accepted items are recorded on the release (`accepted` in `release/releases.json`, shown by
`tappaas-train releases`); the boundary uses the ack up. `boundary --dry-run` says what the gate
would do with the last preview. When the comparison cannot be made — no release tag, no security
scan, a pin that cannot be fetched — it says so and lets the deep test decide.

### Working through OPEN: `cve-triage.sh`

Before anyone looks, two kinds of finding are settled by the data itself:

- **Fixed by a nixpkgs patch.** A package whose `patches` name a CVE (libssh2's
  `CVE-2026-55199.patch`), or a patch file whose commit messages name a CVE (glibc's
  `2.42-master.patch`, its release branch: "memalign: reinstate alignment overflow check
  (CVE-2026-0861)"), has that fix applied. The scan and the preview count it as resolved
  — in the VEX column — for the version nixpkgs builds; another version is looked at as it is.
- **A record with no version range** (grype: `none (unknown)`) names the product but no
  affected versions — ImageMagick's 2014 bugs "match" 7.1.2. Flagged `?range` in
  `preview --module` and listed first by `cve-triage.sh open`: usually a false positive, quick
  to confirm.

The rest is a person's (or an agent's) call, recorded as VEX:

```bash
cve-triage.sh open immich --json /tmp/immich.json   # OPEN CVEs, descriptions, ?range first
cve-triage.sh add immich CVE-2026-1234 --pkg ffmpeg-headless --state exploitable --risk medium \
    --detail "MOV demuxer; reachable by any uploaded video. Fixed in 8.1.3: the next pin."
cve-triage.sh add immich CVE-2014-9826 --pkg imagemagick --state false_positive \
    --detail "SUN coder bug fixed in 6.8.9 (2014); the record has no version range."
```

`add` pins `not_affected` to the versions the release ships and the module runs today, so a
version change asks again; `false_positive` covers the package; `exploitable` keeps the CVE
counted, as RISK, with the risk here. `baseline` writes to `templates-vex.json`. Commit the
file; the next scan and preview apply it.

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
Staging also takes a **disruption** (`--why "disruption: …"`): a fault that disrupts or regresses
the platform's operation and that the next boundary would carry into production.
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
- a release image a module downloads (`imageType: img` with an `http` `imageLocation` — the
  NixOS template, the OPNsense firewall) is not published. A `nixos-template-v*` or
  `opnsense-firewall-v*` tag builds it only when pushed to the GitHub repo; 2.2 named
  `nixos-template-v1.4`, whose tag never got there, and makerfloss's templates update failed
  with a 404;
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
