# forgejo:repo service

A Forgejo repository a module's content lives in, readable from the module's VM.

## What a consumer gets

- **Its repository**, `websites/<vmname>`, private. Install creates it the first time,
  with a starter `index.md`, and never writes into it again. The organisation `websites`
  and its repositories belong to a local Forgejo user, `tappaas-sites`, which has no admin
  rights; its API token stays on tappaas-cicd (`/home/tappaas/secrets/forgejo-sites.token`).
- **A read-only deploy key.** The key pair is made on the consumer's VM
  (`/etc/secrets/forgejo-repo.key`); only its public half is given to Forgejo.
- **What it needs to pull**, on the consumer's VM: `/etc/secrets/forgejo-repo.env`
  (`REPO_SSH_URL`, `REPO_WEB_URL`, `REPO_BRANCH`) and `/etc/secrets/forgejo-repo.known_hosts`
  (Forgejo's host key, so the first pull is verified).
- **Editors**: the people in the consumer's `repoEditors` field get write access.
- **Network access**: `pinhole.json` opens TCP 22 from the consumer to Forgejo.
- **Delete** takes the deploy key off and removes the files from the consumer. The
  repository is kept: it is the owner's content.

## How to use it

```json
"dependsOn": ["network:rules", "forgejo:repo"],
"config": { "forgejo:repo": { "repoEditors": ["lars"] } }
```

The consumer pulls with its own key, for example:

```bash
GIT_SSH_COMMAND="ssh -i /etc/secrets/forgejo-repo.key -o IdentitiesOnly=yes \
  -o UserKnownHostsFile=/etc/secrets/forgejo-repo.known_hosts" git clone "$REPO_SSH_URL"
```

Forgejo cannot call the consumer (a module in the DMZ is not reachable from the service
zone), so the consumer checks for new commits itself; `git ls-remote` against a local
Forgejo is cheap.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`forgejo:repo` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `repoEditors`

Forgejo usernames given write access to the consumer's repository. A person signs in to Forgejo once (with Authentik) before they can be added; until then the service warns and adds them on a later update.

| Attribute | Value |
|---|---|
| Type | `array` |
| Default | *(none)* |
| Example | `lars` |
| Required by | *(none)* |
| Used by | `forgejo:repo` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Forgejo admins (Authentik group forgejo-admins) reach every repository already. Removing a name from the list does not take access away; do that in Forgejo.

**Why this change class.** Adds collaborators to the repository; the consumer's VM is not touched.

<!-- END GENERATED FIELDS -->
