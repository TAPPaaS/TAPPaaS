# ollama-nvidia

Primary audience: developers and services needing a local, OpenAI-compatible LLM endpoint
on hardware too old for `vllm-amd`.

Local LLM inference on an NVIDIA GPU (currently a Tesla P100 12GB, Pascal) via Ollama — an
OpenAI-compatible API for LiteLLM or direct clients, with no data leaving your network.

## Why this exists, not just "vLLM but NVIDIA"

`vllm-amd` requires the whole model to fit in accelerator memory in one shot, and vLLM
itself hard-requires CUDA compute capability ≥7.0 — the Tesla P100 in this box is compute
capability 6.0 and simply cannot run vLLM at all, at any size. Ollama (llama.cpp) instead
does **hybrid GPU+CPU layer offload**: when a model doesn't fully fit in the GPU's VRAM,
the remaining layers run on the CPU/system RAM instead of failing outright. Combined with
this host's large RAM, that turns "12GB of old VRAM" into "12GB fast + a few hundred GB
slow" — a capability tier `vllm-amd` cannot offer on comparable hardware.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| OpenAI-compatible inference API | Internal network / consumers of `ollama-nvidia:inference` | `http://ollama-nvidia.<zone>.internal:11434` (TCP 11434 pinhole for cross-zone consumers) |
| Hybrid GPU+CPU model support | API | Models well beyond 12GB VRAM run (slower) via CPU offload |
| Dynamic multi-model serving | API | Multiple models can be pulled and swapped on demand — no single baked-in `--model` like vLLM |

Sizing tiers (reference — GPU/VRAM will change once this host's card is upgraded):

| Tier | Example | Where it runs | Speed |
|------|---------|----------------|-------|
| Fully GPU-resident | 7–8B Q4/Q5 GGUF | Entirely in VRAM | Fast (tens of tok/s) |
| Hybrid offload | ~30B Q4 GGUF | Mix of VRAM + system RAM | Medium, usable interactively |
| CPU-heavy | 70B+ Q4 GGUF | Mostly system RAM, few GPU layers | Slow, but *possible* |

Reference models (via `./pull-model.sh`):

| Command | Model | Tier |
|---------|-------|------|
| `smoke` | qwen2.5:3b | Quick validation |
| `prod`  | qwen2.5:14b | Fully GPU-resident |
| `large` | llama3.1:70b | Hybrid CPU+GPU offload demo |

## What is not included

- **No model is bundled** — pull one with `./pull-model.sh` (see [INSTALL.md](./INSTALL.md)).
- **No public/internet exposure** — internal-only; cross-zone consumers get a firewall
  pinhole on port 11434 via `dependsOn ["ollama-nvidia:inference"]`.
- **No official NVIDIA/Proxmox-blessed LXC GPU passthrough path** — this uses the
  community-established pattern (device-node bind-mount + `nvidia-container-toolkit`
  inside a privileged LXC), which is less polished than AMD's `/dev/kfd` equivalent —
  driver-version drift between host and in-container userspace libs is the most common
  failure mode (see DESIGN.md).

## Requirements

- An NVIDIA GPU, ≥8GB VRAM, driver ≥570 — currently a Tesla P100 12GB on `tappaas1`.
  `discover.sh` validates a floor, not an exact model, since this card is expected to be
  upgraded later.
- 32GB+ storage for OS + Docker + models.
- `srvWork` zone; LXC sizing (defaults from `ollama-nvidia.json`): 24 cores, ~282GB RAM,
  32GB disk.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:lxc` | LXC container provisioning |
| `backup:vm` | Container snapshots |

For installation steps see [INSTALL.md](./INSTALL.md). For design rationale and the
hybrid-offload/storage decisions, see [DESIGN.md](./DESIGN.md).

## External references

- [vLLM #1284 — Why not support Tesla P100](https://github.com/vllm-project/vllm/issues/1284)
- [vLLM #1431 — compute capability below 7.0 not supported](https://github.com/vllm-project/vllm/issues/1431)
- [Ollama hardware support docs](https://docs.ollama.com/gpu)
