# ollama-nvidia — Design notes

Implementation and tuning detail moved out of README/INSTALL (Diataxis: explanation).

## Why Ollama, not vLLM

vLLM hard-requires CUDA compute capability ≥7.0 (Volta or newer)
([vLLM#1284](https://github.com/vllm-project/vllm/issues/1284),
[vLLM#1431](https://github.com/vllm-project/vllm/issues/1431)) — Pascal-era cards
(Tesla P100/P40, GTX 10-series, compute capability 6.x) cannot run it at any model size,
full stop. This isn't a `vllm-amd` clone with a different vendor string; it's a different
serving engine because vLLM is categorically unusable on the hardware class this module
was built to support.

Ollama (llama.cpp) supports compute capability ≥5.0 (driver ≥570 required for the
5.0–6.2 range) and has been benchmarked on Pascal datacenter cards. More importantly for
the hardware profile this module targets — an older/smaller GPU paired with abundant
system RAM — Ollama does **hybrid GPU+CPU layer offload**: when a model doesn't fully
fit in VRAM, remaining layers run on the CPU instead of the engine refusing to start.
`vllm-amd`'s single-shot "whole model must fit in accelerator memory" model has no
equivalent capability. `pull-model.sh large` (llama3.1:70b, ~40GB Q4) exists specifically
to exercise and prove this on a card whose VRAM the model far exceeds.

The module is not Pascal-only: `discover.sh` validates configurable floors
(`min_vram_mb`, `min_driver_version` in the meta), not a GPU model, so it runs unchanged
on any newer NVIDIA card. On compute capability ≥7.0 hardware a vLLM-based module is a
reasonable alternative for high-throughput batched serving; Ollama's edge is flexibility
and modest hardware.

Footnote for GP100-class cards specifically (e.g. Tesla P100): unlike consumer Pascal,
GP100 has full-rate FP16 throughput, so llama.cpp's FP16 KV-cache/GEMM paths aren't
crippled the way they'd be on a GTX 10-series part — a small but real point in that
card's favor for this workload.

## Performance tuning

Defaults set in the compose file (both the repo reference copy and the scaffold
`update.sh` writes — keep them in sync):

- `OLLAMA_KEEP_ALIVE=24h`, `OLLAMA_MAX_LOADED_MODELS=4` — sized for the RAM-rich host
  profile this module targets (LXC memory = 75% of host RAM per the discover.sh
  formula): re-loading a tens-of-GB model from disk costs minutes, keeping it resident
  costs nothing that's scarce. On a RAM-constrained host, lower both.
- `OLLAMA_LOAD_TIMEOUT=15m` — first load of a large hybrid-offload model streams tens of
  GB from disk; on spinning-disk pools Ollama's default 5m load timeout can abort it
  mid-load. Subsequent loads come from page cache and are fast.

Opt-in knobs documented in the compose file but deliberately left unset until measured on
the actual card (support and benefit vary by GPU generation — on Pascal in particular,
flash-attention kernels run but aren't the fast path): `OLLAMA_FLASH_ATTENTION=1` (lower
VRAM for context), `OLLAMA_KV_CACHE_TYPE=q8_0` (quantized KV cache frees VRAM for more
GPU-resident layers; requires FA), `OLLAMA_NUM_PARALLEL=4` (throughput for multi-user
LiteLLM traffic at the cost of context headroom).

Evaluated and rejected for the target profile: SSD/L2ARC caching for the model store
(when host RAM comfortably exceeds the model working set, the page cache holds every
realistically-sized model after first read — see Storage below) and NUMA pinning (on
dual-socket hosts llama.cpp has NUMA options but Ollama doesn't expose them — revisit
only if CPU-offload throughput disappoints in practice).

## Stack

- Debian 12 LXC (privileged, `nesting=1`, swap 0 — see `ollama-nvidia.meta.json`
  `lxcOptions`), created by `cluster:lxc`; this module only does post-create work, same
  convention as `vllm-amd` (issue #203).
- Docker inside the LXC runs the **official** `ollama/ollama` image (not a community
  nightly build like `vllm-amd`'s ROCm image — a real reliability upgrade on that front).
- GPU passthrough: NVIDIA character devices (`/dev/nvidia0`, `/dev/nvidiactl`,
  `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools`) are bind-mounted into the LXC with matching
  cgroup2 allow entries, then `nvidia-container-toolkit` (installed inside the LXC) hands
  the GPU to the `ollama` Docker container via Compose's `deploy.resources.reservations`
  stanza. Unlike AMD's `render` group convention, NVIDIA device nodes are simply made
  world-rw (666) — there's no equivalent group-based convention on the NVIDIA side; access
  control for the actual workload is delegated to `nvidia-container-toolkit`.
- Models live on the host (`tanka1`, ZFS mirror — see Storage below) and are bind-mounted
  into the LXC, same convention as `vllm-amd`'s `bindMounts`.

## No cache layer for model storage

On the host profile this module targets (RAM comfortably exceeding the model working
set), an SSD/bcache/L2ARC layer in front of a spinning-disk pool buys nothing: model
files are small relative to free RAM and access is sequential (model load), not random —
the case cache layers solve (working set exceeds RAM) doesn't apply, and the Linux page
cache alone keeps every realistically-sized model resident after the first load. Models
are bind-mounted from a directory on a standard TAPPaaS storage pool (default
`/mnt/tanka1/ollama-models`, configurable via `bindMounts` in the meta) — same convention
as `vllm-amd`, no new storage component introduced. (Same caveat as `vllm-amd`: a
container with `bindMounts` can't use `pct snapshot` — no rollback for this module;
backups come from `backup:vm`'s PBS job instead.)

## Discovery and the meta file

`discover.sh` runs from tappaas-cicd, inspects the node over SSH, and MERGES results into
`ollama-nvidia.meta.json` (preserving the curated `bindMounts`/`lxcOptions`/`ollama_image`
structure), same discipline as `vllm-amd` — it never touches `ollama-nvidia.json`.

Unlike `vllm-amd`'s discovery (hardcoded to one exact AMD APU model string), this validates
a **minimum VRAM floor** (`min_vram_mb`, default 8192) and **minimum driver version**
(`min_driver_version`, default 570) rather than an exact GPU model — the module works on
any NVIDIA card meeting the floors, and a GPU upgrade needs no code change, just a
re-run of `discover.sh`.

Device majors (`/dev/nvidia0` etc.) are boot-dynamic exactly like `/dev/kfd` is for
`vllm-amd` — `discover.sh` must be re-run before every (re)install, and
`patch-host-gpu.sh` re-syncs the LXC's cgroup allow list to the live majors on every run,
restarting the container only when something actually changed.

One structural difference from `vllm-amd`, and it's sharper than "not recognized":
`Create-TAPPaaS-LXC.sh` (the foundation `cluster:lxc` provisioner) fires its GPU
passthrough block on **any non-empty `.gpu` key** in the meta — without checking the
shape. Its handler then reads AMD's `kfd_major`/`render_node` fields, which resolve to
empty strings for an NVIDIA-shaped block (`get_meta` returns `""` for missing keys), and
writes malformed conf lines (`lxc.cgroup2.devices.allow: c :  rwm`, a bind of `/dev/dri/`)
that break `pct start` at first install. This module's meta therefore deliberately names
its device block **`nvidia_gpu`**, not `gpu`, so the provisioner's AMD handler never
fires — the meta.json schema is explicitly unvalidated, so a differently-named block is
legal. `patch-host-gpu.sh` is consequently the *sole owner* of the passthrough conf: it
manages a sentinel-delimited block (`# BEGIN/END ollama-nvidia GPU passthrough`) in
`/etc/pve/lxc/<vmid>.conf`, rebuilt from live device state on every run and rewritten
only when the content changed. A managed block, rather than per-line patching, is
required here because match-by-minor replacement is ambiguous on NVIDIA: `/dev/nvidia0`
(major 195, minor 0) and `/dev/nvidia-uvm` (dynamic major, minor 0) share a minor. Only
`nvidia_uvm`'s major is dynamic (195 is a registered, stable major), so in practice the
re-sync matters after host reboots for the uvm pair specifically.

Related boot-time gotcha handled by `patch-host-gpu.sh` (step 1b/1c): `/dev/nvidia-uvm`
is created *lazily* — on first CUDA context or `nvidia_uvm` module load — so after a host
reboot it's often absent even with a healthy driver, and the LXC would silently lose GPU
compute (Ollama falls back to CPU without erroring). The patch script loads `nvidia_uvm`
immediately, persists it via `/etc/modules-load.d/ollama-nvidia.conf`, and enables
`nvidia-persistenced` when available (keeps the GPU initialized between contexts,
avoiding multi-second driver re-init on the first request after idle). `discover.sh`
performs the same modprobe before its device checks so a fresh host doesn't fail
discovery spuriously.

## NVIDIA driver installed in two places, deliberately

- **Host (the target Proxmox node)**: the full driver (kernel module + userspace),
  auto-installed by `patch-host-gpu.sh` when it finds an NVIDIA GPU on PCI with no
  working driver: build prerequisites via apt (gcc/make/dkms/kernel headers), `nouveau`
  blacklisted and unloaded live (no reboot needed when nothing holds it — on headless
  Proxmox hosts the console is usually on the BMC's graphics chip, not the GPU), then
  the `.run` installer for the `host_driver_pin` version from the meta, registered with
  dkms so kernel updates rebuild it. Idempotent: a working driver skips the whole step.
- **Inside the LXC**: userspace libraries only, installed via the same `.run` installer
  with `--no-kernel-module` — the LXC shares the host kernel (which already has the real
  module loaded), it only needs matching userspace libs so `nvidia-container-toolkit` has
  something compatible to hand to the `ollama` Docker container.

These two must be the **exact same driver version** — this is the single most commonly
reported failure mode for NVIDIA-in-LXC-via-Docker setups (driver-version drift between
host and container). `update.sh`'s bootstrap step automates this by reading the version
`discover.sh` recorded and installing the matching `.run` package inside the LXC on first
install; it's a best-effort step (warns and continues on a 404 rather than aborting the
whole update) since the exact `.run` URL can drift from what the host reports — see
INSTALL.md's troubleshooting section.

## Accepted risk: NVIDIA-in-LXC-via-Docker vs VM+PCI-passthrough

Community consensus (as of this module's design) is that whole-GPU passthrough to a
privileged LXC + `nvidia-container-toolkit` is comparatively more fragile and less
documented than the AMD `/dev/kfd` equivalent, and that a VM with full PCI passthrough is
more reliable for NVIDIA specifically. This module accepts that tradeoff deliberately, to
stay consistent with the LXC+Docker architecture `vllm-amd` already established in this
repo, rather than introducing a second, VM-based module architecture for one GPU vendor.
If this proves unworkable in practice, the fallback is a VM+PCI-passthrough redesign — a
different module, not a patch to this one.

## Update flow

`update.sh` bootstraps Docker, `nvidia-container-toolkit`, and
`/opt/ollama/docker-compose.yml` if missing (idempotent); installs the matching in-LXC
NVIDIA userspace driver on first run only (while the meta file is still present — see
above); applies OS updates in the LXC; pulls the latest `ollama/ollama` image and recreates
the container only if the image changed; prunes old images.

## Model management

No HuggingFace download step and no compose-file `--model` flag to patch (unlike
`vllm-amd`'s `download-model.sh` + `scripts/install-model.sh`) — `ollama pull <tag>` is
self-sufficient. `pull-model.sh` folds both vLLM-side scripts' concerns (parameterized
fetch + smoke test) into one, dispatching `smoke`/`prod`/`large`/`<raw-tag>` the same way
`vllm-amd`'s `download-model.sh` dispatches `smoke`/`prod`/`eagle`/`<hf-repo>`. There is no
`eagle` (EAGLE-3 speculative decoding) equivalent — that's a vLLM-only feature.

## References

- [vLLM #1284 — Why not support Tesla P100](https://github.com/vllm-project/vllm/issues/1284)
- [vLLM #1431 — compute capability below 7.0 not supported](https://github.com/vllm-project/vllm/issues/1431)
- [Ollama hardware support docs](https://docs.ollama.com/gpu)
- [DatabaseMart: Ollama benchmark on Tesla P100](https://www.databasemart.com/blog/ollama-gpu-benchmark-p100)
