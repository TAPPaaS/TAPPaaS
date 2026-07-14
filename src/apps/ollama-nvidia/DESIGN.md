# ollama-nvidia — Design notes

Implementation and tuning detail moved out of README/INSTALL (Diataxis: explanation).

## Why Ollama, not vLLM, on this hardware

vLLM hard-requires CUDA compute capability ≥7.0
([vLLM#1284](https://github.com/vllm-project/vllm/issues/1284),
[vLLM#1431](https://github.com/vllm-project/vllm/issues/1431)). The Tesla P100 in this box
is Pascal, compute capability 6.0 — vLLM will not initialize on it at any model size, full
stop. This isn't a `vllm-amd` clone with a different vendor string; it's a different
serving engine because vLLM is categorically unusable here.

Ollama (llama.cpp) supports compute capability ≥5.0 (driver ≥570 required for the
5.0–6.2 range) and has been benchmarked on exactly this card. More importantly for this
host's profile — old GPU, huge system RAM — Ollama does **hybrid GPU+CPU layer offload**:
when a model doesn't fully fit in VRAM, remaining layers run on the CPU instead of the
engine refusing to start. `vllm-amd`'s single-shot "whole model must fit in accelerator
memory" model has no equivalent capability. `pull-model.sh large` (llama3.1:70b, ~40GB Q4
on a 12GB card) exists specifically to exercise and prove this.

Footnote: GP100 (unlike consumer Pascal cards such as the GTX 10-series) has full-rate
FP16 throughput, so llama.cpp's FP16 KV-cache/GEMM paths aren't crippled here the way
they'd be on a desktop Pascal card — a small but real point in this GPU's favor for this
workload.

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

Checked `tappaas1`'s actual disk layout during design: 376GB RAM (334GB free at the time),
`tanka1` (ZFS mirror, 2×1.2TB 10K SAS, 1.06TB free), `tankb1` (3.26TB free), and a 120GB
enterprise SATA SSD (`rpool`, 99GB free, OS-only). Model files are small relative to free
RAM and access is sequential (model load), not random — the case bcache/L2ARC solves
(working set exceeds RAM) doesn't apply; the Linux page cache alone keeps every
realistically-sized model resident after the first load. Models are bind-mounted from
`/mnt/tanka1/ollama-models` — same pool, same convention as `vllm-amd`, no new storage
component introduced. (Same caveat as `vllm-amd`: a container with `bindMounts` can't use
`pct snapshot` — no rollback for this module; backups come from `backup:vm`'s PBS job
instead.)

## Discovery and the meta file

`discover.sh` runs from tappaas-cicd, inspects the node over SSH, and MERGES results into
`ollama-nvidia.meta.json` (preserving the curated `bindMounts`/`lxcOptions`/`ollama_image`
structure), same discipline as `vllm-amd` — it never touches `ollama-nvidia.json`.

Unlike `vllm-amd`'s discovery (hardcoded to one exact AMD APU model string), this validates
a **minimum VRAM floor** (`min_vram_mb`, default 8192) and **minimum driver version**
(`min_driver_version`, default 570) rather than an exact GPU model — this host's GPU is
explicitly expected to be upgraded later, and the module should keep working after that
swap without a code change, just a re-run of `discover.sh`.

Device majors (`/dev/nvidia0` etc.) are boot-dynamic exactly like `/dev/kfd` is for
`vllm-amd` — `discover.sh` must be re-run before every (re)install, and
`patch-host-gpu.sh` re-syncs the LXC's cgroup allow list to the live majors on every run,
restarting the container only when something actually changed.

One structural difference from `vllm-amd`: `Create-TAPPaaS-LXC.sh` (the foundation
`cluster:lxc` provisioner) auto-writes the *initial* cgroup/mount lines from a module's
`.meta.json` `gpu` block at container-create time — but that logic is keyed to AMD's
`kfd_major`/`render_node` field names and doesn't recognize this module's NVIDIA-shaped
`gpu` block. `patch-host-gpu.sh` here is therefore fully self-sufficient: it appends the
cgroup/mount lines on first sight and replaces them (matching by minor, which is stable
across reboots — only the major shifts) on every subsequent run, rather than assuming
`Create-TAPPaaS-LXC.sh` already seeded them. If a future refactor teaches the foundation
provisioner to recognize both device-block shapes, this fallback stays correct either way
(the "append if missing" branch simply stops firing).

## NVIDIA driver installed in two places, deliberately

- **Host (Proxmox, `tappaas1`)**: the full driver (kernel module + userspace), installed
  once, out of band, before this module is ever installed (see INSTALL.md prerequisites).
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
