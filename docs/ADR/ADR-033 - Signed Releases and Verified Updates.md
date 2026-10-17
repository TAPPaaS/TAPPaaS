# ADR-033 — Signed Releases and Verified Updates

| | |
|---|---|
| **Status** | **Draft** |
| **Version** | 0.1 |
| **Date** | 2026-10-17 |
| **Author** | Lars Rossen (drafted with Claude) |
| **Deciders** | @LarsRossen, @ErikDaniel007, @AndreasJe |
| **Closes / addresses** | Implementation: **#848**. Builds on [ADR-028](<ADR-028 - Release Cadence and Patching.md>) (D11 `channels.json`, D13 release tags, D15 urgent fixes), [ADR-011](<ADR-011 - SBOM Governance.md>) (supply-chain inventory), [ADR-007e](<ADR-007e - Health.md>) (the Health lens), [ADR-007d](<ADR-007d - Site.md>) (`site.json` repositories), [ADR-017](<ADR-017 - Update scheduling and mothership self-update.md>) (the sweep and the self-update). |
| **Changelog** | v0.1 — first draft, from the operator's NIS2 brief of 2026-10-17: every repository needs a signature, signer ownership is recorded, binaries are signed, the update verifies before it moves, NixOS fits the same chain, only staging and production are signed, and every repository's signing status is part of the health check. |

How a TAPPaaS site knows that the code and images it is about to run are the ones the
repository's owners released — and refuses them when it cannot tell.

## Context

### The requirement

NIS2 (Directive (EU) 2022/2555, Art. 21(2)(d) supply-chain security and (e) security in the
acquisition, development and maintenance of systems) and its Implementing Regulation (EU)
2024/2690 expect an operator to show that software in operation came from where it claims and
was not changed on the way. In practice that is read as: **software is obtained from a source
that signs what it publishes, and the signature is checked before the software is installed.**
The Cyber Resilience Act asks the same of the updates a product distributes. An operator who
runs TAPPaaS under NIS2 must be able to point at that check. Today there is none to point at.

### How a site gets its software today

TAPPaaS is not one download. A site is assembled from several sources, and each has a different
answer to *who vouches for this*:

| Source | What it delivers | Integrity today | Authenticity today |
|---|---|---|---|
| TAPPaaS git repository (Codeberg) | managers, module scripts, flakes, `templates/flake.lock` | git object hashes over TLS | **none** — whoever can push to the branch is believed |
| Community and a site's own module repositories | further modules | same | **none** |
| VM images on GitHub Releases: the NixOS template (`tappaas-nixos.qcow2.zst`), the OPNsense image | the first boot of guests and of the firewall | **none** — `curl -fSLo`, no checksum published or checked | **none** |
| Proxmox install media (`make-install-media.sh`) | the nodes | **none** — the operator's ISO and the assistant `.deb` are used as found | **none** |
| nixpkgs / cache.nixos.org | every NixOS package | `narHash` (SHA-256) in `flake.lock` | Hydra's ed25519 signature on each store path (`trusted-public-keys`) |
| Debian, Proxmox, PBS apt archives | host packages | signed `Release` files | archive keys — **already compliant** |
| OPNsense firmware | the firewall | signed package repository | OPNsense fingerprints — **already compliant** |
| Container images | apps in `oci-containers` | digests in `src/image-pins.json` (ADR-028 D14) | the registry — integrity only, not publisher |

Measured in the code on 2026-10-17: nothing in the tree verifies a signature or a hash on what
it fetches, apart from the Proxmox apt keyrings and one NIC driver download. Every repository
update goes through one function, `reconcile_repo_checkout` (`tappaas-cicd/lib/repo-sync.sh`),
plus the clone/fetch paths of `site-manager repository add|modify|sync` and `bootstrap.sh`;
it trusts the branch tip it is served over HTTPS. The train's release tags are annotated but
unsigned (`make_release_tag` in `tappaas-train.sh`). Guest closures built on the mothership are
copied with `nix copy --no-check-sigs`.

The OS layers below TAPPaaS already sign. The gap is TAPPaaS's own layer — and that layer is
the one that *chooses* everything below it: the `flake.lock` that pins nixpkgs, the image
digests, the module code. An unsigned top of the chain makes the signed bottom worth little.

### How to "hash" a repository

A tarball is hashed as bytes. A git repository already is a hash: a **commit id is a hash over
its tree, every file in it, and its whole history** (a Merkle tree). Signing a commit, or an
annotated tag that names one, therefore signs the exact content of the repository at that
point. Nothing new has to be computed. Two caveats shape the decisions below:

1. **The default object format is SHA-1.** Git hardens it (collision detection), and the
   SHA-256 object format exists but is not yet supported everywhere a site may fetch from.
   A release tag can carry a second, SHA-256 content hash of the tree — the `narHash` Nix
   already computes (`nix hash path`) — so the signature does not rest on SHA-1 alone (D3).
2. **A signature proves who, not which.** A validly signed *old* release is still validly
   signed. Verification must also refuse going backwards (D6).

### Prior art

| Project | What is signed | Where signer keys live | How the first key is trusted |
|---|---|---|---|
| **GNU Guix** (`guix git authenticate`) | every commit | `.guix-authorizations` in the repository; a commit is valid only if signed by a key authorized **in its parent** | a *channel introduction*: one commit + one key fingerprint, shipped outside the repository |
| **sequoia-git** (`sq-git`) | commits and tags | `openpgp-policy.toml` in the repository, checked against the parent's policy; roles per signer | a *trust root* commit, explicitly *not* stored in the repository |
| **git (SSH signing)** | commits and tags (`ssh-keygen -Y`) | an `allowed_signers` file (`gpg.ssh.allowedSignersFile`) with per-key principals and validity dates | out of band |
| **Sigstore gitsign** | commits, keyless (OIDC identity + short-lived cert) | Fulcio/Rekor transparency log | the OIDC issuer and the public Sigstore instance |
| **Linux kernel, Arch, Debian dgit** | release tags | maintainers' OpenPGP keys, published keyrings | keyring package / web of trust |
| **Nix** | binary cache paths; experimentally, git fetches (`verified-fetches`: `fetchGit` with `publicKey(s)`, SSH keys) | `trusted-public-keys` in `nix.conf`; the flake input | the NixOS configuration |
| **Forgejo / Codeberg** | shows *Verified* on SSH/GPG-signed commits and tags; can require signed commits on a protected branch | the user's account keys | the forge account |

Guix and sequoia-git solve exactly the two problems this ADR has: **record signer ownership in
the repository**, and **do not let the repository vouch for itself**. TAPPaaS takes that model
and expresses it with git's own SSH signing, which needs no keyring and no new tool on any
machine.

## Requirements

- **R1** — Every repository a site tracks is verifiable, and the site checks it **before** its
  checkout moves, not after.
- **R2** — Signer ownership is recorded per repository, readable by anyone, and changed only
  by someone already trusted.
- **R3** — The first trust in a repository comes from outside that repository.
- **R4** — The images we build and publish are signed, and a site checks them before use.
- **R5** — The NixOS chain (nixpkgs, cache) is covered without TAPPaaS re-signing nixpkgs.
- **R6** — Signing costs the developer nothing on `main`; it happens where releases happen.
- **R7** — The signing status of every repository in an installation is visible in the
  health check, and a regression in it is noticed.
- **R8** — A repository that cannot be verified does not break a site silently or loudly
  without warning: the operator sees it, and decides.

## Decision

### D1 — The signed object is the release tag; production and staging must be signed, unstable need not

ADR-028 D13 already cuts an annotated tag at every boundary (`vMAJOR.MINOR`) and every urgent
fix (`vMAJOR.MINOR.N`). **That tag becomes a signed tag**, and it is the only thing signed.

| Channel | Branch | Rule |
|---|---|---|
| **production** | `stable` | the tip **must** be exactly a signed release tag |
| **staging** | `staging` | the tip **must** be exactly a signed release tag |
| **unstable** | `main` | not required. Reported as *unsigned (unstable)*, never as a failure |

Why tags, not every commit: `main` moves many times a day, by several people and several
sessions; requiring every commit signed puts a key on every developer and every automation
and buys nothing a site uses, because no production site runs an arbitrary `main` commit.
The train already produces one object per release; signing it costs one signature per
fortnight (R6). Why not merely the branch tip: a branch is a mutable pointer the forge
controls; a tag signature is the release manager's statement about one commit.

Contributors **may** sign commits on `main` and the forge shows it; it is encouraged, not
required.

### D2 — SSH signatures, keys on hardware

Signatures are **git SSH signatures** (`gpg.format = ssh`, `ssh-keygen -Y sign/verify`).

- Every machine that verifies already has `ssh-keygen` and `git`; nothing new is installed.
- `allowed_signers` is git's native format: principal, key, optional `valid-after` /
  `valid-before` and namespace restriction. It is reviewable in a diff.
- Codeberg shows SSH-signed tags as verified.
- The same key and the same tool sign the images (D7), so there is one mechanism, not two.

Release keys are **hardware-backed** (`sk-ssh-ed25519`, a FIDO2 token with touch), so a key
cannot be copied off a laptop and a signature needs a person present. The train is already run
by a person at each boundary; the touch is the operator's consent to release.

OpenPGP (Guix, sequoia-git) was considered: richer key lifecycle, but a keyring to manage on
every site, and tooling most operators do not have. Sigstore gitsign was considered: no long-lived
keys, but every verification then depends on a public transparency log and an OIDC issuer outside
the operator's control — a sovereignty cost TAPPaaS does not accept for v1 (see Alternatives).

### D3 — What a release tag says

The tag is cut by `tappaas-train` as today, and signed. Its message keeps what D13 puts there
(date, forced or not, estate pin, blueprint result, previous version) and gains:

```
tree-sha256: <nix hash path --type sha256 of the tagged tree>
images:      <sha256 of each published image, as in the image pointer files>
signers-at:  <commit of .tappaas/allowed_signers that authorized this signature>
```

The `tree-sha256` line gives the signature a SHA-256 anchor that does not depend on git's
SHA-1 (Context §How to hash). The image hashes make the tag the single signed statement of a
release: verifying the tag verifies the image hashes, and the images are then checked by hash
(D7).

### D4 — Each repository records its signers, and the record is governed by itself

Each repository carries **`.tappaas/allowed_signers`** at its root (git's format), listing every
key allowed to sign its release tags:

```
# principal                   namespace     key
lars@tappaas.org  namespaces="git,tappaas-image" sk-ssh-ed25519@openssh.com AAAA... lars-yubikey-1
erik@tappaas.org  namespaces="git,tappaas-image" sk-ssh-ed25519@openssh.com AAAA... erik-yubikey-1
```

and a short **`.tappaas/SIGNERS.md`** naming, for each key: its owner, their role (release
manager, module maintainer), the date it was added, and how to reach them. `CODEOWNERS`
(ADR-015) names `.tappaas/` as owned by the release managers.

**Who owns the key for a repository:**

| Repository | Signers |
|---|---|
| TAPPaaS (this repository) | the release managers — at least two, so one lost token does not stop releases |
| Community | its maintainers |
| A site's own module repository | the site operator |
| A third party's repository | whoever releases it; their file, their keys |

**Changes to the record follow the Guix / sequoia-git rule: a release tag is valid only if its
signer is listed in `allowed_signers` *as of the previously verified release*.** Adding or
removing a signer is an ordinary commit that lands in the next release, and takes effect for the
release **after** that. So a pusher who adds their own key to the file cannot sign the very
release that adds it; an attacker needs a key that was already trusted. A key is retired with
`valid-before`, not by deleting its line, so old releases still verify.

### D5 — First trust comes from outside the repository: the introduction

A repository cannot vouch for its own first key (R3). Each repository entry in `site.json`
(ADR-007d) gains a **trust anchor**:

```json
{
  "name": "tappaas",
  "url": "https://codeberg.org/TAPPaaS/TAPPaaS.git",
  "branch": "stable",
  "updateChannel": "stable",
  "trust": {
    "introduction": "v2.4",
    "introductionCommit": "<commit id>",
    "signer": "SHA256:<fingerprint>",
    "lastVerified": "v2.6"
  }
}
```

- **The TAPPaaS repository's anchor is written by the installer**, which came from a signed
  image (D7) whose key fingerprint is published on tappaas.org, in `INSTALL.md`, and in the
  release notes. That fingerprint is the one thing an installing operator compares by hand.
- **A repository added later** (`site-manager repository add`) is introduced explicitly: the
  operator gives the tag and the expected fingerprint, obtained from the repository's owner out
  of band; the command shows both and refuses without them unless `--unsigned` is given (D9).
- `lastVerified` moves forward on every successful update and is the base for D4's rule and
  D6's rollback check.

### D6 — Update verifies before git moves

Before any checkout moves, the site does the following per repository. The check sits in
`reconcile_repo_checkout`, the one function the self-update (`tappaas-self-prepare.sh` →
`refresh-control-plane.sh`, ADR-017 D3) and `site-manager repository sync|modify` already share,
and in the clone paths (`repository add`, `bootstrap.sh`, the site-manager client) — so there is
one verifier, not one per caller. The plain `git pull` fallback in `refresh-control-plane.sh`
goes.

1. `git fetch` (objects and tags only; the working tree does not move).
2. Resolve the target: the tip of the branch the repository declares for the site's channel
   (ADR-028 D11).
3. On **staging/production**: require a release tag that points **exactly** at that commit.
4. Verify its signature: `git verify-tag` against the `allowed_signers` **from the commit of
   `lastVerified`** (D4), not from the fetched tree.
5. Check `tree-sha256` from the tag message against the fetched tree.
6. Refuse going backwards: the new tag must descend from `lastVerified` (`git merge-base
   --is-ancestor`). A deliberate rollback is an operator command, never a fetch result.
7. Only then fast-forward the checkout, and record the new `lastVerified`.

A failure stops the update of **that repository** before anything changes, leaves the site on
its last verified release, is logged, and is mailed through the site notification target
(ADR-007e, #651) like a failed sweep. The sweep does not continue onto modules from a
repository that failed verification.

On **unstable** steps 3–6 are skipped and the result is recorded as *unsigned (unstable)*.

### D7 — Built images are signed and checked by hash

The images TAPPaaS builds or repackages — the **NixOS template image**, the **OPNsense image**,
and any **Proxmox install media** TAPPaaS publishes, plus any image added later — are published
with:

- `SHA256SUMS` listing every artefact of the release, and
- `SHA256SUMS.sig`, an SSH signature over it (`ssh-keygen -Y sign -n tappaas-image`), by a key
  in `allowed_signers` with the `tappaas-image` namespace.

Inside the platform an image is **checked by hash**, never trusted by URL: the image pointer
files in the repository (written by `release/bump-version.sh`) carry the SHA-256, the release
tag that covers them is signed (D3), and the download is compared against it before the image is
imported. The detached signature is for the one download that happens **before** any TAPPaaS
code runs — an operator fetching the installer — and for anyone verifying by hand:

```
ssh-keygen -Y verify -f allowed_signers -I lars@tappaas.org -n tappaas-image \
  -s SHA256SUMS.sig < SHA256SUMS && sha256sum -c SHA256SUMS
```

What TAPPaaS takes **from upstream** to build these is checked against upstream's own statement
first: the Proxmox ISO against Proxmox's published SHA-256 list, the OPNsense source image
against its published checksum, the Proxmox assistant package by hash. A build that cannot check
its input does not publish.

Images stay where ADR-028 and the Codeberg migration put them; where they are hosted does not
matter once they are checked by hash against a signed statement.

### D8 — NixOS: the signed tag covers the pin, Hydra covers the packages

TAPPaaS does not re-sign nixpkgs. The chain is:

1. The signed release tag (D1) covers `templates/flake.lock` (ADR-028 D1).
2. `flake.lock` records each input's revision **and** its `narHash` — a SHA-256 over the
   input's content. Nix refuses an input whose content does not match.
3. Every binary substituted from `cache.nixos.org` carries Hydra's ed25519 signature, checked
   against `trusted-public-keys`; `require-sigs = true` is the default and is **asserted** in the
   estate baseline so no module can turn it off.

So a site that verified the tag has verified, transitively, every NixOS package it will build or
download. The same holds for container images: their digests in `src/image-pins.json` are
covered by the tag (integrity); verifying the *publisher* of an image (cosign) is out of scope
for v1.

Three further Nix points:

- **Closures the mothership pushes to guests** are copied with `--no-check-sigs` today: a guest
  takes whatever the mothership sends. The mothership gets a **site signing key** (`nix
  key generate-secret`), signs what it builds, and guests trust only that key plus
  `cache.nixos.org`. This is site-local and has nothing to do with release keys.
- The fallback that builds against a **GitHub tarball URL** of nixpkgs (`update-os.sh`) must
  carry the lock's `narHash`, or go.

- Flake inputs that point at **TAPPaaS repositories** (module flakes) must be pinned by
  `rev` + `narHash` in a lock that a signed tag covers — never by branch.
- Nix has experimental **verified fetches** (`fetchGit` with `publicKeys`, SSH keys — the same
  key type as D2). Not used in v1; worth revisiting if a module ever fetches a TAPPaaS repository
  from inside a Nix evaluation.

### D9 — An unsigned repository is allowed, but declared and visible

Some repositories will not sign — Community before its maintainers have keys, a site's own
scratch repository. Refusing them would break sites (R8). So:

- A repository with **no `.tappaas/allowed_signers`**, or added with `--unsigned`, is
  **unsigned by declaration**: it updates as today, and is reported as such everywhere (D10).
- A repository that **has** signers and fails verification is **never** treated as unsigned:
  that is a failure (D6). Once a site has verified a repository it keeps expecting signatures:
  a later release that drops `allowed_signers` is accepted only if a previously trusted key
  signed it, and the site then reports the downgrade rather than silently relaxing.
- A site may set **`site.json` `requireSigned: true`** (the NIS2 setting): then an unsigned
  repository on staging/production is refused, not just reported. Default `false` in 2.x; the
  default is reviewed once the core repositories sign.

### D10 — Signing status is part of the health check

`health-manager` (ADR-007e) gains a **signature check** over every repository registered in
`site.json`, run with the post-sweep security scan (ADR-011 §9) and on demand:

| Status | Meaning | Severity |
|---|---|---|
| `verified` | checkout is exactly a signed release tag, signer authorized, tree hash matches | OK |
| `unsigned (unstable)` | repository is on `main` / an unstable branch | INFO |
| `unsigned (declared)` | repository has no signers, or was added `--unsigned` | WARN (FAIL if `requireSigned`) |
| `ahead of release` | checkout has local or unreleased commits on a signed channel (the ADR-028 D12 drift) | WARN |
| `verification failed` | bad signature, unknown signer, hash mismatch, rollback | FAIL |
| `signer expiring` | a signing key's `valid-before` is within 60 days | WARN |

The result is:

- a **`signature-status` gate in `validate`**, beside `cve-status` — WARN by default, FAIL
  under `requireSigned`;
- a line per repository in `site-manager site show` and `health-manager report`;
- mailed to the site owner **when a status changes**, not every night;
- an exportable **evidence record** (`config/sbom/signatures.json`: repository, channel, tag,
  commit, signer, time verified) — the artefact an operator hands an auditor for NIS2.

## Consequences

- A production site can state, with evidence, that every TAPPaaS-layer component it runs was
  released by a named person and checked before use; the OS layers below were already signed.
- A boundary needs a release manager with a hardware token. A boundary or urgent fix cannot be
  cut by automation alone — intended, and a cost: two signers so one absence does not stop the
  train.
- The installer's fingerprint becomes a published, long-lived value; rotating it is a
  documented, two-release procedure (D4).
- Repositories that do not sign keep working but are visibly not NIS2-ready.
- `main` is unchanged for developers.

## Alternatives considered

- **Sign every commit (Guix model) everywhere.** Strongest, and lets `unstable` be verified too.
  Rejected for v1: every contributor and every automation needs a key, and no production site
  runs arbitrary commits. Can be added per repository later — D4's rule already works per commit.
- **OpenPGP signatures.** Mature key lifecycle (expiry, revocation, subkeys); sequoia-git gives a
  ready policy engine. Rejected for v1: a keyring on every site and a tool most operators lack;
  SSH covers what D4 needs. Revisit if sequoia-git's policy roles become wanted.
- **Sigstore (gitsign, cosign keyless).** No long-lived keys, transparency log. Rejected for v1:
  verification depends on a public log and identity provider outside the operator's
  administrative domain (ADR-022a). A self-hosted Sigstore is possible later.
- **Only checksums, no signatures.** Proves integrity of a download, not who released it — does
  not meet the requirement.
- **Trust the forge (Codeberg protected branches).** The forge is a third party and an account
  compromise is the attack; a signature taken on the release manager's token is not.
- **Sign with a key on the mothership.** Automatable, but a key on the machine that is updated
  by what it signs; a compromise of one mothership would sign releases for all sites.

## Implementation plan

Tracked in **#848**.

1. Signer record: `.tappaas/allowed_signers` + `SIGNERS.md` in TAPPaaS (and offered to
   Community); release managers enrol hardware keys; fingerprint published on tappaas.org.
2. `tappaas-train`: signed boundary and patch tags carrying D3's lines; refuse to cut without a
   signing key.
3. Image release (the `build-*-image` workflows): verify upstream inputs, publish `SHA256SUMS`
   + `.sig`; SHA-256 in the image pointer files (`templates/tappaas-nixos.json`,
   `network/network.json`, via `bump-version.sh`); hash check in `Create-TAPPaaS-VM.sh` and
   `templates/update.sh` before import; `make-install-media.sh` checks the Proxmox ISO.
4. Verification library (`tappaas-verify-repo`): D4–D6, used by the self-update, the sweep and
   `site-manager`.
5. `site.json` `trust` anchors and `requireSigned`, with an ADR-025 migration writing the anchor
   for existing sites from the release they are on (operator confirms the fingerprint).
6. `health-manager` signature check and `validate` gate (D10), evidence file.
7. Nix: baseline asserts `require-sigs`; mothership site key signs guest closures and
   `--no-check-sigs` goes; the tarball fallback carries `narHash`; module flake inputs pinned by
   `rev` + `narHash`.
8. Docs: an operator page on verifying an install, `INSTALL.md` fingerprint step, a
   release-manager runbook for key enrolment and rotation.

## Testing

- Unit: `verify-repo` against fixture repositories — good tag, unknown signer, signer added in the
  same release (refused), expired key, retired key on an old tag (accepted), tree hash mismatch,
  rollback, tip not at a tag, missing `allowed_signers`.
- Live (hrossen, rehearsal refs per ADR-028 D13): a rehearsal boundary signs; the sweep verifies
  and moves; a tampered tag stops the self-update before the rebuild and mails; teardown restores
  the real anchors.

## Open questions

1. **The exact NIS2 / 2024/2690 clause** an operator should cite — confirm the wording before
   the operator-facing page claims compliance.
2. **Who the TAPPaaS release managers are** (the signer list) and the second token's owner.
3. **SHA-256 object format**: does Codeberg/Forgejo support it well enough to move the
   repositories, making D3's `tree-sha256` redundant?
4. **Community**: sign now with its maintainers' keys, or stay `unsigned (declared)` until it
   cuts releases (ADR-028 D11 already warns that it declares no production branch)?
5. **`requireSigned` default**: when does it become `true` for new installs — 3.0?
6. **Signed commits on `main`**: require them on the forge for the core repository anyway, as
   cheap provenance for unstable?

## Documentation impact (ADR-013)

- `INSTALL.md` / tappaas.org: verify the installer image and record the fingerprint.
- Operator reference: `health-manager` signature check, `requireSigned`, adding a repository
  with an introduction.
- Release runbook (`release/README.md`): key enrolment, signing a boundary, rotating a signer.
- `docs/ADR/README.md`: index row.
