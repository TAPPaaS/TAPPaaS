# LiteLLM — Upgrade Guide

## Upgrading to v1.103.3 (module v0.7.3)

### What changes

- LiteLLM moves from 1.85.0 to 1.103.3. PostgreSQL stays on 17 and Redis follows
  the nixpkgs pin; neither is part of this step.
- The database schema is migrated when the container starts (`prisma migrate
  deploy`). The migrations only go forward: an older image does not run on the
  migrated schema, so the way back is a restore, not a tag.
- From 1.103.3 a failed migration stops the container instead of letting it
  serve on a stale schema. A failed upgrade is therefore visible at once.
- `test.sh` now fails when a table that held rows is empty.

### Why not the newest

1.104 refuses to start when the master key is unset or still the default, and
was days old when this pin moved. 1.103.3 is a backport line and carries the
migration fix.

### Before

Take a backup that does not live on the guest:

```bash
backup-manager backup litellm
```

### Update

```bash
module-manager update litellm --allow-disruption
```

The update takes a snapshot first and rolls back to it when a test fails
fatally.

### After

- `module-manager test litellm --deep` passes, the row check included.
- Virtual keys, teams and their model limits, models and credentials are all
  still listed.
- One request through a local model and one through a cloud model succeed.

### Way back

Restore the pre-update snapshot (`module-manager snapshot-vm litellm --restore
<n>`) or the backup (`backup-manager restore restore litellm`). Do not point an
older image at the migrated database.

## v0.7.0 — credential management tooling (module version, no app upgrade)

Not a LiteLLM app version change (still 1.85.0) — module tooling only.

- Consolidated all provider-key wiring onto LiteLLM's native named-credential
  registry (`litellm_credential_name`), replacing implicit env-var fallback
  and one legacy row that resisted the standard update API. Rotating a key
  now updates one credential object; every model referencing it picks up the
  new value automatically — no per-model action needed.
- New `scripts/litellm-credentials.sh` (`inspect`/`add`/`rotate`/`assign-model`)
  — see README.md `## Operations`.
- Fixed `services/models/test-service.sh`: Test 1's VK-keystore existence
  check ran as an unprivileged user against a root-600 file, always
  false-negative (upstream: TAPPaaS/TAPPaaS#394). Test 4's DB-model
  `api_key` check now also recognizes `litellm_credential_name` references,
  not just literal `api_key`.
- `scripts/rotate-provider-key.sh`: removed the obsolete Step 3
  (delete+recreate every model with a literal key) — structurally
  unnecessary now that models reference credentials by name; Step 2 now
  delegates to `litellm-credentials.sh rotate`.

## Upgrading to v1.85.0

### What is new

- LiteLLM updated from 1.81.14 to 1.85.0
- Container image moved from GHCR to Docker Hub
- PostgreSQL updated from version 15 to 17
- Usage logs now saved to database (was broken before)
- Redis now saves data to disk (was lost on restart before)

---

### Important: data loss in older installs

If you ran v1.81.14 with the default settings, **usage logs were never saved to the database**. They lived only in memory and were lost every time the container or VM restarted.

This is fixed in v1.85.0. After upgrading, all usage data is saved.

**Old usage data cannot be recovered.**

---

### What you keep after the upgrade

| Data | Kept? | What to do |
|---|---|---|
| Usage logs | No | Cannot be recovered |
| Virtual user keys | Yes | Make a backup first (see below) |
| Users and teams | Yes | Make a backup first (see below) |
| Model settings | Only if you had turned on `STORE_MODEL_IN_DB=True` manually | Most installs: No |
| Provider API keys | No | Add them again via the UI after upgrade |
| Master key | Yes | Stays on the VM |

---

### Before you upgrade

**Step 1 — Save your master key**

```bash
ssh tappaas@<vmname>.<zone>.internal "sudo cat /etc/secrets/litellm.env"
```

Keep this key safe. You need it to log in after the upgrade.

**Step 2 — Back up your users and virtual keys**

```bash
ssh tappaas@<vmname>.<zone>.internal \
  "sudo -u postgres pg_dump litellm | gzip" > litellm-backup-$(date +%F).sql.gz
```

**Step 3 — Save your model settings (optional)**

If you want to keep your model settings, turn on saving first, re-add your models in the UI, wait one minute, then upgrade.

```bash
ssh tappaas@<vmname>.<zone>.internal
sudo sed -i 's/STORE_MODEL_IN_DB=False/STORE_MODEL_IN_DB=True/' /etc/secrets/litellm.env
sudo systemctl restart podman-litellm
# Re-add models in the UI, then wait 60 seconds
```

---

### Run the upgrade

```bash
update-module.sh litellm
```

This will update NixOS, install PostgreSQL 17, pull the new container, and restart all services.

---

### After the upgrade

**Restore users and virtual keys**

```bash
cat litellm-backup-<date>.sql.gz | ssh tappaas@<vmname>.<zone>.internal \
  "gunzip | sudo -u postgres psql litellm"
```

**Add provider API keys**

Open the UI and go to Settings → Credentials. Add your API keys for OpenRouter, Anthropic, Perplexity, or other providers.

`http://<vmname>.<zone>.internal:4000/ui`

**Check that everything works**

```bash
cd TAPPaaS/src/ai/litellm
./test.sh
```
