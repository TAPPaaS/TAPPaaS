# ollama-nvidia — Install

## Prerequisites

1. An NVIDIA GPU (compute capability ≥5.0, ≥8GB VRAM) in the target node, set as `node`
   in `ollama-nvidia.json`.
2. `cluster:lxc` and `backup:vm` already installed on the target node.

**The host NVIDIA driver is installed automatically.** If `install.sh` finds an NVIDIA
GPU on PCI with no working driver, it installs the version pinned as `host_driver_pin`
in `ollama-nvidia.meta.json` (dkms build, `nouveau` blacklisted and unloaded live — no
reboot needed unless `nouveau` is actively in use, e.g. driving the console). The pin
defaults to the newest datacenter branch that still supports Pascal/Volta; users with a
newer card can bump it. Caveats where the automatic path can't help:

- **Secure Boot**: the out-of-tree kernel module must be MOK-signed (or Secure Boot
  disabled) — check `mokutil --sb-state`. Legacy-boot hosts are unaffected.
- **vGPU**: if `pve-nvidia-vgpu-helper` has a vGPU profile actively claiming the card,
  release it first — this module uses whole-GPU passthrough.

## Install

```bash
install-module.sh ollama-nvidia
```

That's the whole flow. `install-module.sh` runs `cluster:lxc`'s provisioning, then this
module's `install.sh`, which: (1) prepares the host GPU — auto-installing the driver if
needed — (2) runs `discover.sh` to validate the GPU against the module's floors (≥8GB
VRAM, driver ≥570, both configurable in the meta) and record the hardware into
`ollama-nvidia.meta.json`, and (3) bootstraps Docker + `nvidia-container-toolkit` +
Ollama inside the container. No manual model-path editing step is needed (unlike
`vllm-amd`) — Ollama manages models dynamically.

`./discover.sh ollama-nvidia` can also be run standalone at any time as a read-mostly
hardware check (it only writes the meta file).

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
