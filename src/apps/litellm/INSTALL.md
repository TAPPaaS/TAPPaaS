# LiteLLM — Installation Guide

See `litellm.json` for current version and VM defaults.

## 1. Check configuration

Open `litellm.json` and verify node, storage, and zone match your environment.
To override defaults, copy to `/home/tappaas/config/litellm.json` and edit.

## 2. Deploy

On the tappaas-cicd VM:

```bash
install-module.sh litellm
```

Duration: ~5-10 minutes on first run.

## 3. Get the master key

```bash
ssh tappaas@<vmname>.<zone0>.internal "sudo cat /etc/secrets/litellm.env"
```

Save this key in your password manager.

## 4. Open the UI and configure

`http://<vmname>.<zone0>.internal:4000/ui` — log in with the master key.

1. Add provider credentials (Settings → Credentials)
2. Add models (AI Hub)
3. Create virtual keys for users

## 5. Verify

```bash
cd TAPPaaS/src/apps/litellm
./test.sh
```

All tests should pass.

## Checklist

- [ ] `litellm.json` matches your environment
- [ ] `install-module.sh litellm` completed without errors
- [ ] Master key retrieved and saved
- [ ] Provider credentials added via UI
- [ ] At least one model available
- [ ] `./test.sh` passes
