# Signing releases

How TAPPaaS releases are signed, who signs them, and how a module repository of your own can be
signed the same way. For what a site checks and how an operator reads the result, see
[VERIFIED-UPDATES.md](VERIFIED-UPDATES.md).

## What is signed

| What | Signed how | Checked by |
|---|---|---|
| **Release tags** — `v<major>.<minor>` at each boundary, `v<major>.<minor>.<n>` for an urgent fix | an SSH signature on the annotated tag (`git tag -s`, `gpg.format=ssh`) | every staging and production site, before its checkout moves |
| **Image releases** — the NixOS template and the OPNsense image | an SSH signature over the release's `SHA256SUMS` (namespace `tappaas-image`) | `release/bump-version.sh`, which writes each image's SHA-256 into the image pointers; the install then refuses a download that does not match |
| **Guest systems** built on the mothership | the mothership's own Nix key, created on the mothership | every NixOS guest, which accepts only that key and cache.nixos.org |

Commits on `main` are not signed, and a site on `main` checks nothing. Signing happens where
releases happen: one signature per boundary.

Every release tag also carries two lines the train writes:

```
tree-sha256: sha256:<hex>     a SHA-256 over the content of every file in the release
signers-at:  <commit>         the commit whose allowed_signers authorizes the signature
```

The tree hash means a signature does not rest on git's SHA-1 object ids alone.

## Who may sign: `.tappaas/allowed_signers`

The keys are listed in [`.tappaas/allowed_signers`](../../../.tappaas/allowed_signers) at the
repository root — **public keys only**, in git's format — and whose they are is in
[`.tappaas/SIGNERS.md`](../../../.tappaas/SIGNERS.md):

```
lars@tappaas.org     namespaces="git,tappaas-image",valid-before="20271101" ssh-ed25519 AAAA... lars-2026
erik@tappaas.org     namespaces="git,tappaas-image",valid-before="20271101" ssh-ed25519 AAAA... erik-2026
recovery@tappaas.org namespaces="git" ssh-ed25519 AAAA... lars-emergency
recovery@tappaas.org namespaces="git" ssh-ed25519 AAAA... erik-emergency
```

**The rule that keeps the repository from vouching for itself:** a release counts only if its
signer is listed in `allowed_signers` *as of the release the site last verified*. A key added in a
release signs the release **after** it. Somebody who can push to the repository cannot add their
own key and sign with it in the same release.

While the file lists no key, the repository signs nothing and every site reports it as unsigned.
The release that adds the first keys is the last unsigned one.

## Signer keys

The TAPPaaS signers are its two owners. Each keeps an `ed25519` key in **their own Bitwarden or
Vaultwarden vault** and signs through the Bitwarden desktop app's SSH agent, which asks for
approval on every signature. The private key is never written to disk outside the vault.

- Two-factor login on the vault.
- The vault is not hosted on a TAPPaaS site that these releases update — a broken update must not
  lock its signer out of the key that signs the fix.
- Each key is valid for one year (`valid-before`) and is replaced before then.
  `health-manager validate` warns 60 days ahead. Once its year is over a key can no longer sign a
  new release: sites check a key against **today's** date when they move to a release, not
  against the date written in the tag (which the signer chooses). A release already running stays
  verified after its key expires.
- A hardware key (FIDO2, `sk-ssh-ed25519`) works the same way, for a signer who prefers one.

### Four keys: two each

Each owner holds two keys — their *Keys to the Kingdom*:

| Key | Where | Signs | Life |
|---|---|---|---|
| **Release key** | their own Bitwarden/Vaultwarden vault, used through its SSH agent | releases and images (`<name>@tappaas.org`) | one year |
| **Emergency key** | offline, on their offsite *Keys to the Mothership* USB stick, in `kingdom/`, passphrase-protected | only releases that change nothing outside `.tappaas/` (`recovery@tappaas.org`) | no expiry |

The *Keys to the Mothership* sticks are the ones `backup-manager key export --usb` writes with a
site's backup keys — one kept onsite, one offsite. The emergency key goes on the offsite one.
Rewriting that stick later replaces only the backup keys; `kingdom/` stays (`--format` would erase
it).

**Making the emergency key** (once per owner, on a laptop, Wi-Fi off if you can):

```bash
ssh-keygen -t ed25519 -C <you>-emergency -f tappaas-emergency-<you>     # a strong passphrase
```

Write the passphrase on paper and keep it apart from the stick — and not only in your vault: this
key is for the day the vault is gone. Copy `tappaas-emergency-<you>` and its `.pub` into `kingdom/`
on the offsite stick, check they are there, and delete the private key from the laptop. Its
public key goes into `allowed_signers` as `recovery@tappaas.org namespaces="git" … <you>-emergency`.

### Enrolling a key (once a year)

1. In the Bitwarden desktop app: *New → SSH key*, type ed25519, name it `tappaas-release-<year>`.
   In *Settings*, turn on the SSH agent and set it to ask for approval on every use.
2. Copy the public key into `.tappaas/allowed_signers` as a new line with your principal and
   `valid-before` one year out, add or update your row in `.tappaas/SIGNERS.md` (fingerprint:
   `ssh-keygen -lf <file with the public key>`), and land it on `main` like any other change.
3. It counts from the release after the one that carries it. Enrol the next year's key while the
   current one still works, then give the old line a `valid-before` — never delete it, or the
   releases it signed stop verifying.

### Signing a boundary or an urgent fix

The train runs on the mothership; the key stays in your vault. Forward your agent and tell git
which key to ask it for:

```bash
ssh -A tappaas@<mothership>                                   # Bitwarden agent running on your laptop
git -C ~/TAPPaaS config user.signingkey "key::<your public key>"   # once
tappaas-train.sh boundary                                     # approve the signature when asked
```

`tappaas-train.sh boundary` and `patch` check for a signing key **before** any branch moves, and
check the new signature against `allowed_signers` before the tag is published. The steps of a
boundary are in [RELEASE-TRAIN.md](RELEASE-TRAIN.md).

### Signing an image release

The image workflows publish `SHA256SUMS` with each release. CI cannot sign it, so after the
build, with the agent running:

```bash
release/sign-image-release.sh nixos-template-v1.5   # checks SHA256SUMS, signs, uploads SHA256SUMS.sig
release/bump-version.sh --nixos 1.5                 # checks the signature, writes URL and SHA-256
```

`sign-image-release.sh` refuses a `SHA256SUMS` that does not list every artefact with the digest
the release page recorded, and checks the signature against `allowed_signers` (namespace
`tappaas-image`) before uploading. `--dry-run` signs without uploading. Once `allowed_signers`
lists a key, `bump-version.sh` refuses an unsigned `SHA256SUMS`. Anyone can check a download by
hand:

```bash
ssh-keygen -Y verify -f .tappaas/allowed_signers -I lars@tappaas.org -n tappaas-image \
  -s SHA256SUMS.sig < SHA256SUMS && sha256sum -c SHA256SUMS
```

## When a key is lost or stolen

**One key lost.** The other signer carries on; enrol a new key as above.

**A key stolen.** Expiry does not stop a thief, so the key is **revoked**: the other signer adds
its public key to [`.tappaas/revoked_signers`](../../../.tappaas/revoked_signers) — one key per
line, with a comment saying when and why — and releases that as an urgent fix:

```bash
tappaas-train.sh patch staging <commit> --why "security: signing key stolen"
tappaas-train.sh patch production <commit> --why "security: signing key stolen"
```

A revoked key is refused whatever date its tag claims, for releases and for images. Like any
change to the signer list it counts from the release after the one that carries it, so get the
revoking release out fast: a site that has moved to it refuses the thief, one still on an older
release does not. Releases the thief signed before still verify, so also announce which versions
not to trust.

**Both keys lost: the emergency keys.** Each owner has a second key, their **emergency key**,
kept offline on their offsite *Keys to the Mothership* stick (below). Both are listed under the
principal `recovery@tappaas.org`, which may sign **only a release that changes nothing outside
`.tappaas/`** — enough to enrol new keys or revoke lost ones, never enough to ship code. Sites
refuse an emergency signature on anything else. Either owner's emergency key alone is enough.

To use one: a branch off the channel's tip that only edits `.tappaas/` (new keys in, lost ones
retired or revoked), merged to `main`; then, with the offsite stick in your laptop:

```bash
git -C ~/TAPPaaS config user.signingkey /path/to/stick/kingdom/tappaas-emergency-<you>
tappaas-train.sh patch staging <commit> --why "security: signer recovery"
tappaas-train.sh patch production <commit> --why "security: signer recovery"
git -C ~/TAPPaaS config --unset user.signingkey      # and put the stick back offsite
```

(The train runs on the mothership: copy the key there for the two commands and delete it after,
or run them from a TAPPaaS checkout on your laptop.) The next boundary is signed with the new
keys; sites follow on their own.

**Every key lost, both emergency keys too.** No release can be verified again. Publish the new
signers' fingerprints on tappaas.org and tell operators; each re-anchors their site by hand
(see [VERIFIED-UPDATES.md](VERIFIED-UPDATES.md#re-anchoring-a-repository)).

## Signing your own module repository

A repository of modules a site adds is checked the same way once it signs:

1. Declare its channels in `channels.json` at its root, e.g.
   `{"production": ["stable"], "staging": ["staging"], "unstable": ["main"]}`. Only branches listed
   for staging or production are checked.
2. List your keys in `.tappaas/allowed_signers` (same format as above).
3. Tag each release on the branch with a signed, annotated tag that carries the tree hash. From a
   TAPPaaS checkout:

   ```bash
   lines="$(bash -c '. ~/TAPPaaS/src/foundation/tappaas-cicd/lib/verify-repo.sh; verify_tag_lines . HEAD')"
   git -c gpg.format=ssh tag -s v1.3 -m "my-modules 1.3" -m "${lines}" HEAD
   git push origin v1.3 && git push origin HEAD:stable
   ```

   The tag must point exactly at the tip of the branch the sites track.
4. Give the operators who add your repository the first release to trust and your key's
   fingerprint, by a channel other than the repository itself.

A repository without `allowed_signers` keeps working on every site and is shown as unsigned —
unless the site sets `requireSigned`.
