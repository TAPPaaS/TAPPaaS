# ollama-nvidia — Install

## Prerequisites

1. **Host NVIDIA driver, installed and working, BEFORE running discover.sh/install.sh.**
   This module does not install the host-level driver for you — that's a one-time,
   host-specific step:
   - Blacklist `nouveau` (`/etc/modprobe.d/blacklist-nouveau.conf`, then
     `update-initramfs -u`, then reboot).
   - Install the NVIDIA datacenter/production-branch driver, **version ≥570**
     (required by Ollama for compute capability 5.0–6.2 GPUs like the P100). If the
     distro-packaged `nvidia-driver` (Debian's `non-free` component) isn't new enough,
     use NVIDIA's official `.run` installer instead. No Secure Boot concerns on this
     host (legacy boot).
   - Verify with `nvidia-smi` on the Proxmox host before proceeding.
   - Note: this host already has `pve-nvidia-vgpu-helper` installed (unrelated — that's
     for vGPU mediated-device splitting, not the whole-GPU LXC passthrough this module
     uses). Confirm it doesn't conflict before installing the datacenter driver.
2. `cluster:lxc` and `backup:vm` already installed on the target node.

## Install

```bash
./discover.sh ollama-nvidia
install-module.sh ollama-nvidia
```

`discover.sh` validates the GPU (≥8GB VRAM, driver ≥570, required character devices
present) and merges the findings into `ollama-nvidia.meta.json`. Like `vllm-amd`, the
device majors are boot-dynamic — **re-run `discover.sh` before every (re)install.**

`install-module.sh` runs `cluster:lxc`'s provisioning, then this module's `install.sh`,
which patches the host GPU devices and bootstraps Docker + `nvidia-container-toolkit` +
Ollama inside the container. No manual model-path editing step is needed (unlike
`vllm-amd`) — Ollama manages models dynamically.

To deviate from the defaults in `./ollama-nvidia.json` (e.g. a different node once the
GPU is upgraded), copy the json to `/home/tappaas/config` and edit it before installing.

## Post-install: pull a model

```bash
./pull-model.sh smoke      # qwen2.5:3b — quick validation
./pull-model.sh prod       # qwen2.5:14b — fully GPU-resident
./pull-model.sh large      # llama3.1:70b — hybrid GPU+CPU offload demo
./pull-model.sh <tag>      # any tag from https://ollama.com/library
```

Each pull also runs a smoke-test chat completion against the model.

## Verification

```bash
test-module.sh ollama-nvidia
./scripts/inspect.sh        # read-only status, no mutation
```

## Troubleshooting

- **`/dev/nvidia*` cgroup allow mismatch after a host reboot**: device majors can shift
  across a host reboot or driver reload. Re-run `discover.sh ollama-nvidia` then
  `patch-host-gpu.sh` (via `install.sh`, or manually on the host) to re-sync — same
  failure mode `vllm-amd` documents for `/dev/kfd`.
- **`nvidia-smi` fails inside the `ollama` container**: the most common cause is a
  version mismatch between the host's NVIDIA driver and the userspace libraries
  installed inside the LXC. `update.sh`'s bootstrap step installs a matching userspace-
  only driver (`--no-kernel-module`) automatically on first install, keyed off the
  version `discover.sh` recorded — if that step's download URL 404'd (patch-version
  drift), install it manually inside the LXC:
  `pct exec <vmid> -- bash` then fetch
  `https://us.download.nvidia.com/tesla/<version>/NVIDIA-Linux-x86_64-<version>.run`
  and run it with `--no-kernel-module`.
- **NVIDIA-in-LXC-via-Docker is inherently less polished than AMD's `/dev/kfd`
  approach** — community consensus flags it as more fragile than PCI passthrough to a
  VM. This module accepts that tradeoff for architectural consistency with `vllm-amd`;
  if it proves too unreliable in practice, a VM+PCI-passthrough redesign is the fallback,
  not a small module (see DESIGN.md).
