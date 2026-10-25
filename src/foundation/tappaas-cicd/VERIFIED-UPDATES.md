# Verified updates

What a TAPPaaS site checks before it runs new code, how to see the result, and what to do when an
update is refused. How releases are signed, and how to sign a repository of your own, is in
[SIGNING.md](SIGNING.md).

## What the site checks

| What | When | What is checked |
|---|---|---|
| **Each repository the site tracks** (`site-manager repository list`) on a `staging` or `stable` branch | every update, after the fetch and before the checkout moves | the new tip is a release tag signed by a key the **last release this site verified** lists — or a key a later release enrolled, signed in turn by a trusted key — the files match the hash in the tag, and it is not older than what the site runs |
| **The TAPPaaS install** | when the mothership is installed | the release cloned is signed by one of the published release keys ([INSTALL.md](../../../INSTALL.md#compare-the-release-signer)) |
| **VM images** (NixOS template, OPNsense) | before a downloaded image is imported | its SHA-256 matches the one in the release, which the release signers signed |
| **Proxmox install media** | when the install USB is made | the ISO against Proxmox's published SHA-256 list |
| **NixOS guest systems** | every guest update | the system is signed by the mothership's own Nix key, or comes from cache.nixos.org |
| **Debian, Proxmox and OPNsense packages** | every update | the distributions' own signed repositories, as before |

A repository on `main`, or on any branch its `channels.json` does not list for staging or
production, is not checked: it is the development line.

When a check fails, **that repository is not updated**: the site stays on the last release it
verified, the update reports the repository as not synced, and says why. Nothing from the refused
release has run.

## Reading the result

After every repository update the site records what each repository runs:

```bash
health-manager validate          # the signature-status line, with a row for anything to look at
site-manager site show           # each repository with its status, e.g. TAPPaaS@stable [verified v2.4]
cat ~/config/sbom/signatures.json
```

| Status | Meaning | `validate` |
|---|---|---|
| `verified` | runs exactly a signed release (named, with its signer) | pass |
| `unsigned-unstable` | on `main` or another development branch | not counted |
| `unsigned-declared` | the repository signs no releases | WARN — FAIL with `requireSigned` |
| `ahead-of-release` | runs commits past its last verified release, or has uncommitted changes | WARN |
| `failed` | on `staging`/`stable`, but what it runs is not a verified release | FAIL |
| key expiring | a signing key the repository lists expires within 60 days | WARN |

The site owner is mailed when a repository's status **changes** — not on every update.
`~/config/sbom/signatures.json` is the record to show an auditor: for each repository its branch,
the release it runs, who signed it, and when it was checked. The last verified release of each
repository is kept in `~/config/.trust/<repository>.json`.

## Requiring signed releases

By default a repository that signs nothing still updates, and is shown as unsigned. A site that
must show that everything it runs comes from signed releases turns that into a refusal:

```bash
site-manager site modify --requireSigned true
```

A repository that does list signing keys is always checked, whatever this says. Development
branches are never affected.

## Adding a repository

On a `staging` or `stable` branch, `site-manager repository add` needs the fingerprints of the keys
the repository's owners sign with — from them, by mail, their website or in person, never from the
repository itself. Give each one with `--signer`:

```bash
site-manager repository add <url> --branch stable --signer SHA256:<fingerprint> --signer SHA256:<fingerprint>
```

The branch's current release must be signed by one of them; no version number is needed. It shows
the fingerprints, checks the clone, refuses on a mismatch, and records them in `site.json`. A
repository that signs nothing is added with `--unsigned`:

```bash
site-manager repository add <url> --branch stable --unsigned
```

On `main` neither is needed; fingerprints given there must be among the keys the repository lists.

## When an update is refused

The update log names the repository and the reason, for example:

```
TAPPaaS: REFUSED — 3f2a91c on 'stable' (production) is not a verified release
  v2.5: Signature verification failed: ... No principal matched
```

| Reason | What it means | What to do |
|---|---|---|
| `is not a release tag` | the branch tip is not exactly a release | wait for the release; the branch was moved without one |
| `No principal matched` / `no valid signature` | signed by a key the last release does not list, lists as expired today, or has revoked | do not override; ask the repository's owners — this is the case the check exists for |
| `tree-sha256 mismatch` | the files do not match what was signed | do not override; report it |
| `does not descend from the last verified release` | the branch was moved back to an older release | ask the repository's owners; an update never goes back on its own — going back is a deliberate operator act, not a fetch result |
| `the site requires signed releases` | `requireSigned` is on and the repository signs nothing | ask its owner to sign, or accept it knowingly with `--requireSigned false` |

The site keeps running the last verified release meanwhile.

## Confirming or renewing a repository's signers

To check that the keys a site trusts for a repository are its owners' keys — or, after the owners
have replaced their keys, to start from the new ones — give the fingerprints the owners publish:

```bash
site-manager repository introduce <name> --signer SHA256:<fingerprint> --signer SHA256:<fingerprint>
```

The current release must be signed by one of them. They are then written to `site.json`, and the
release is recorded as the one the next update starts from. Without `--signer` the command checks
the checkout against the fingerprints already in `site.json`.

## Sites that predate signing

A site already on `staging` or `stable` before a repository starts signing keeps updating with
nothing to do. The release that adds the repository's first keys arrives like any unsigned update;
from the release after it, every update must be signed by a key it lists. Those keys arrived the
way every update did before signing, so run `repository introduce` with the published fingerprints
once to confirm them.

## Checking a download by hand

```bash
ssh-keygen -Y verify -f .tappaas/allowed_signers -I lars@tappaas.org -n tappaas-image \
  -s SHA256SUMS.sig < SHA256SUMS && sha256sum -c SHA256SUMS
```

`.tappaas/allowed_signers` comes from a TAPPaaS checkout; compare its fingerprints with
[INSTALL.md](../../../INSTALL.md#compare-the-release-signer) and tappaas.org.
