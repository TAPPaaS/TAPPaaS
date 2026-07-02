---
name: vllm-amd — Installation Runbook
description: Step-by-step installation of the vllm-amd inference module on a Proxmox LXC.
kind: Runbook
version: 1.0.0
language: gridtefy-B2
copyright: © 2026 TAPPaaS org
last-updated: 2026-07-03
status: approved
---

# vllm-amd — Installation Runbook

Only manual steps are listed here. Scripts handle everything else automatically.

## GPU passthrough — must be done once on the Proxmox host

Before creating the LXC, verify GPU passthrough is configured on the host node:

```bash
ls /dev/kfd /dev/dri/renderD128
```

Both devices must be present. If either is missing, the ROCm container will not
start. Configure udev rules and `/etc/pve/lxc/<vmid>.conf` GPU entries before
proceeding. See `patch-host-gpu.sh` for the exact configuration applied.

## Prerequisites

1. **Cluster services:** `cluster:lxc` and `backup:vm` must be operational on the target node (`tappaas2` by default).
2. **Hardware profile:** Run `discover.sh` to generate `vllm-amd.meta.json` for the target host before first install. This file must exist before `install-module.sh` can configure GPU devices correctly.
   ```bash
   cd src/apps/vllm-amd
   bash discover.sh
   ```
3. **Model files:** Download at least one model after installation (see Verify §Download a model).

## Install

```bash
cd /home/tappaas/TAPPaaS/src/apps/vllm-amd
install-module.sh vllm-amd
```

The installer creates the LXC, installs Docker and ROCm, and starts the vLLM container. First boot takes 5–10 minutes while the container image is pulled (~20 GB).

## Verify

**API health (no CLI required):**

```
http://vllm-amd.<zone>.internal:8000/v1/models
```

Returns a JSON list of loaded models. An empty `data: []` means vLLM is running but no model is configured yet.

**Automated module check:**

```bash
test-module.sh vllm-amd
```

Checks GPU device access, Docker daemon, container status, and API responsiveness.

**Download a model and start serving:**

```bash
scripts/install-model.sh Qwen/Qwen2.5-7B-Instruct
```

After download, restart the container to load the model:

```bash
update-module.sh vllm-amd
```

**Inspect what is currently serving:**

```bash
scripts/inspect.sh
```

## Troubleshooting

**Container starts but API returns HTTP 000.**
The model is still loading. Qwen3-30B takes 3–5 minutes on first start. Check load progress:
```bash
# From tappaas-cicd:
ssh root@tappaas2.mgmt.internal "pct exec 312 -- docker logs --tail 30 vllm"
```

**`/dev/kfd` not found inside container.**
GPU passthrough is not configured. Run `patch-host-gpu.sh` on the host node, then recreate the LXC.

**`bash: -c: option requires an argument` in update.sh.**
The `pct()` SSH wrapper uses `printf %q` quoting. If this error appears, verify the wrapper is present in `update.sh` (added in v0.8.0).

**ROCm HIP error on model load.**
Check `HSA_OVERRIDE_GFX_VERSION=11.5.1` is set in `docker-compose.yml`. Without this, ROCm cannot detect gfx1151 correctly.
