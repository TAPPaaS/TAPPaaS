# ollama-nvidia

Primary audience: developers and services needing a local, OpenAI-compatible LLM endpoint
on NVIDIA hardware — including cards too old for vLLM.

Local LLM inference on any NVIDIA GPU (compute capability ≥5.0) via Ollama — an
OpenAI-compatible API for LiteLLM or direct clients, with no data leaving your network.

## Why Ollama, not vLLM

vLLM hard-requires CUDA compute capability ≥7.0 (Volta or newer), which rules out
Pascal-era cards (Tesla P100/P40, GTX 10-series) entirely — not slow, unusable. Ollama
(llama.cpp) supports compute capability ≥5.0 and additionally does **hybrid GPU+CPU
layer offload**: when a model doesn't fully fit in VRAM, the remaining layers run on the
CPU/system RAM instead of failing outright. On a host with plentiful system RAM, that
turns a small or old VRAM budget into "VRAM fast + RAM slow" — models far beyond the
card's VRAM remain usable.

Users with a newer card (compute capability ≥7.0) can use this module as-is — it works
on any NVIDIA GPU — but for high-throughput multi-user serving on modern hardware, a
vLLM-based module (analogous to `vllm-amd`, using the official CUDA vLLM image) is worth
considering as an alternative; Ollama's strength is flexibility and modest hardware, not
batched throughput.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| OpenAI-compatible inference API | Internal network / consumers of `ollama-nvidia:inference` | `http://ollama-nvidia.<zone>.internal:11434` (TCP 11434 pinhole for cross-zone consumers) |
| Hybrid GPU+CPU model support | API | Models beyond the card's VRAM run (slower) via CPU offload |
| Dynamic multi-model serving | API | Multiple models pulled and swapped on demand — no single baked-in `--model` like vLLM |

Sizing tiers (examples assume a 12GB-class card — scale by your VRAM):

| Tier | Example | Where it runs | Speed |
|------|---------|----------------|-------|
| Fully GPU-resident | 7–8B Q4/Q5 GGUF | Entirely in VRAM | Fast (tens of tok/s) |
| Hybrid offload | ~30B Q4 GGUF | Mix of VRAM + system RAM | Medium, usable interactively |
| CPU-heavy | 70B+ Q4 GGUF | Mostly system RAM, few GPU layers | Slow, but *possible* |

Reference models (via `./pull-model.sh`):

| Command | Model | Tier |
|---------|-------|------|
| `smoke` | qwen2.5:3b | Quick validation |
| `prod`  | qwen2.5:14b | Fully GPU-resident on 12GB+ cards |
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

- Any NVIDIA GPU with ≥8GB VRAM and a host driver ≥570. Both floors are configurable in
  `ollama-nvidia.meta.json` (`min_vram_mb`, `min_driver_version`) — `discover.sh`
  validates floors, not an exact GPU model, so a GPU upgrade needs no code change, just
  a re-run of discovery. (The 570 floor is what Ollama requires for older compute
  capability 5.0–6.2 cards; newer cards satisfy it with any current production driver.)
- 32GB+ storage for OS + Docker + models.
- LXC sizing: use the reference formula `discover.sh` prints (cores = host cores − 8
  when >16, memory = 75% of host RAM). The defaults in `ollama-nvidia.json` reflect one
  reference host — adjust `node`, `vmid`, and sizing for your environment by copying the
  json to `/home/tappaas/config` before installing.

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
