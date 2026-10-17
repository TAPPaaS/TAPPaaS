# Release signers

Who may sign TAPPaaS release tags and images ([ADR-033](../docs/ADR/ADR-033%20-%20Signed%20Releases%20and%20Verified%20Updates.md)).
The keys themselves are in [`allowed_signers`](allowed_signers); this page says whose they are.

| Signer | Role | Key (fingerprint) | Token | Added | Contact |
|---|---|---|---|---|---|
| Lars Rossen | TAPPaaS owner, release manager | *not enrolled yet* | FIDO2 (`sk-ssh-ed25519`) | — | @LarsRossen |
| Erik Daniel | TAPPaaS owner, release manager | *not enrolled yet* | FIDO2 (`sk-ssh-ed25519`) | — | @ErikDaniel007 |

Two signers, so one lost token or one absence does not stop a release.

## Changing this list

A change to `allowed_signers` is an ordinary commit, reviewed like code, and takes effect for the
release **after** the one that carries it: sites read the signers from the last release they
verified, never from the release being checked. To retire a key, give its line
`valid-before="YYYYMMDD"`; do not delete it.

How to enrol a key and sign a boundary: [`RELEASE-TRAIN.md`](../src/foundation/tappaas-cicd/RELEASE-TRAIN.md#signing-releases-adr-033).
