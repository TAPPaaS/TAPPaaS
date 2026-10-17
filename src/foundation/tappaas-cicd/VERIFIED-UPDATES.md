# Verified updates

What a TAPPaaS site checks before it runs new code, how to see the result, and what to do when an
update is refused. How releases are signed, and how to sign a repository of your own, is in
[SIGNING.md](SIGNING.md).

## What the site checks

| What | When | What is checked |
|---|---|---|
| **Each repository the site tracks** (`site-manager repository list`) on a `staging` or `stable` branch | every update, after the fetch and before the checkout moves | the new tip is a release tag signed by a key the **last release this site verified** lists, the files match the hash in the tag, and it is not older than what the site runs |
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

On a `staging` or `stable` branch, `site-manager repository add` needs the first release to
trust and the fingerprint of the key that signed it — both from the repository's owner, by mail,
their website or in person, never from the repository itself:

```bash
site-manager repository add <url> --branch stable \
  --introduction v1.3 --signer SHA256:<fingerprint>
site-manager repository add <url> --branch stable --unsigned     # a repository that signs nothing
```

It shows both, checks the clone against them, and refuses on a mismatch. On `main` neither is
needed.

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

## Re-anchoring a repository

If a repository's owners lose every signing key, they publish new fingerprints outside the
repository and announce it. After checking the fingerprint with them, give the repository its new
starting point:

```bash
site-manager repository introduce <name> --introduction <tag> --signer SHA256:<fingerprint>
```

The same command checks an existing checkout against the starting point it already has.

## Checking a download by hand

```bash
ssh-keygen -Y verify -f .tappaas/allowed_signers -I lars@tappaas.org -n tappaas-image \
  -s SHA256SUMS.sig < SHA256SUMS && sha256sum -c SHA256SUMS
```

`.tappaas/allowed_signers` comes from a TAPPaaS checkout; compare its fingerprints with
[INSTALL.md](../../../INSTALL.md#compare-the-release-signer) and tappaas.org.
