# Release signers

Who may sign TAPPaaS release tags and images ([ADR-033](../docs/ADR/ADR-033%20-%20Signed%20Releases%20and%20Verified%20Updates.md)).
The keys themselves are in [`allowed_signers`](allowed_signers); this page says whose they are.

| Signer | Role | Key (fingerprint) | Kept in | Valid until | Contact |
|---|---|---|---|---|---|
| Lars Rossen | TAPPaaS owner, release manager | SHA256:Vv5LV6e07/r+PLMFlzcfZ9dtCXAbqdydrnIiBVBWzJk | his own vault (Bitwarden SSH agent) | — | @LarsRossen |
| Erik Daniel | TAPPaaS owner, release manager | *not enrolled yet* | his own vault (Bitwarden SSH agent) | — | @ErikDaniel007 |
| Lars Rossen — emergency (`recovery@tappaas.org`) | recovery only — may sign a release that changes nothing outside `.tappaas/` | SHA256:vcROgNHX0Z4wxU40fp2/46YeMqeg8TKbjLAttW0Q3y4 | offline: his offsite Keys-to-the-Mothership stick, `kingdom/`, passphrase-protected | no expiry | @LarsRossen |
| Erik Daniel — emergency (`recovery@tappaas.org`) | recovery only — may sign a release that changes nothing outside `.tappaas/` | *not made yet* | offline: his offsite Keys-to-the-Mothership stick, `kingdom/`, passphrase-protected | no expiry | @ErikDaniel007 |

Two signers, so one lost key or one absence does not stop a release; an emergency key each, so
losing both release keys does not stop it for good. Release keys are replaced every year.

## Changing this list

A change to `allowed_signers` is an ordinary commit, reviewed like code, and takes effect for the
release **after** the one that carries it: sites read the signers from the last release they
verified, never from the release being checked. To retire a key, give its line
`valid-before="YYYYMMDD"`; do not delete it. A stolen key is revoked instead, in
[`revoked_signers`](revoked_signers).

How to enrol a key, sign a release, and recover from a lost or stolen key: [`SIGNING.md`](../src/foundation/tappaas-cicd/SIGNING.md).
