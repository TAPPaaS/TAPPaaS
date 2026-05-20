# LiteLLM — Upgrade Guide

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
cd TAPPaaS/src/apps/litellm
./test.sh
```
