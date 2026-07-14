# ollama-nvidia — Install

## Prerequisites

1. **Host NVIDIA driver, installed and working, BEFORE running discover.sh/install.sh.**
   This module does not install the host-level driver for you — that's a one-time,
   host-specific step:
   - Blacklist `nouveau` (`/etc/modprobe.d/blacklist-nouveau.conf`, then
     `update-initramfs -u`, then reboot).
   - Install the NVIDIA production-branch driver, **version ≥570**. The 570 floor is
     what Ollama requires for older compute capability 5.0–6.2 GPUs (e.g. Tesla P100);
     newer cards satisfy it with any current production driver. If the distro-packaged
     `nvidia-driver` (Debian's `non-free` component) isn't new enough, use NVIDIA's
     official `.run` installer instead.
   - If the host uses Secure Boot, the out-of-tree kernel module must be MOK-signed (or
     Secure Boot disabled) — check with `mokutil --sb-state`. Legacy-boot hosts are
     unaffected.
   - Verify with `nvidia-smi` on the Proxmox host before proceeding.
   - If `pve-nvidia-vgpu-helper` is present on the host (Proxmox ships it for vGPU
     mediated-device setups), it's unrelated to the whole-GPU LXC passthrough this
     module uses — confirm no vGPU profile is actively claiming the card before
     installing the driver.
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

To deviate from the defaults in `./ollama-nvidia.json` (target node, vmid, LXC sizing —
the shipped values reflect one reference host), copy the json to `/home/tappaas/config`
and edit it before installing. Size cores/memory with the reference formula `discover.sh`
prints for your host.

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

- **GPU works, then silently disappears after a host reboot** (Ollama falls back to CPU
  without erroring): two known causes, both handled by re-running `patch-host-gpu.sh`
  (via `install.sh`, or manually on the host) after a fresh `discover.sh`:
  1. `/dev/nvidia-uvm` is created lazily and may not exist at boot —
     `patch-host-gpu.sh` persists `nvidia`/`nvidia_uvm` via
     `/etc/modules-load.d/ollama-nvidia.conf` on first run, so this should only bite
     hosts prepared before that.
  2. `nvidia_uvm`'s device major is dynamically allocated and can shift across reboots
     (nvidia0/nvidiactl's major 195 is stable) — the sentinel-managed passthrough block
     in `/etc/pve/lxc/<vmid>.conf` is re-synced to live majors on every
     `patch-host-gpu.sh` run. Same failure mode `vllm-amd` documents for `/dev/kfd`.
- **`nvidia-smi` fails inside the `ollama` container**: the most common cause is a
  version mismatch between the host's NVIDIA driver and the userspace libraries
  installed inside the LXC. `update.sh`'s bootstrap step installs a matching userspace-
  only driver (`--no-kernel-module`) automatically on first install, keyed off the
  version `discover.sh` recorded — it tries both NVIDIA download paths (datacenter
  `/tesla/<version>/` and consumer `/XFree86/Linux-x86_64/<version>/`). If both 404'd
  (patch-version drift), install manually inside the LXC: `pct exec <vmid> -- bash`,
  fetch `NVIDIA-Linux-x86_64-<version>.run` for your exact host driver version, and run
  it with `--no-kernel-module`.
- **NVIDIA-in-LXC-via-Docker is inherently less polished than AMD's `/dev/kfd`
  approach** — community consensus flags it as more fragile than PCI passthrough to a
  VM. This module accepts that tradeoff for architectural consistency with `vllm-amd`;
  if it proves too unreliable in practice, a VM+PCI-passthrough redesign is the fallback,
  not a small module (see DESIGN.md).
