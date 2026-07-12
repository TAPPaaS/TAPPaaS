# vllm-amd

Primary audience: developers and services needing a local, OpenAI-compatible LLM endpoint.

Local LLM inference on the AMD Ryzen AI MAX+ 395 integrated GPU (Radeon 8060S, Strix Halo) —
an OpenAI-compatible API for LiteLLM or direct clients, with no data leaving your network.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| OpenAI-compatible inference API | Internal network / consumers of `vllm-amd:inference` | `http://vllm-amd.<zone>.internal:8000` (TCP 8000 pinhole for cross-zone consumers) |
| Large model support | API | Up to 120B parameters on 128 GB unified memory |
| Fast inference | API | ~50 tok/s (7B FP16), ~20 tok/s (30B GPTQ-4bit) |

Tested models (reference):

| Model | Size | Quantization | Notes |
|-------|------|--------------|-------|
| Qwen2.5-7B-Instruct | 7B | FP16 | Default — fast, good quality |
| Qwen3-14B-AWQ | 14B | AWQ | Good balance speed/quality |
| Qwen3-30B-A3B-GPTQ-Int4 | 30B | GPTQ-4bit | Mixture-of-experts, low active params |
| Qwen3-Coder-30B-GPTQ-Int4 | 30B | GPTQ-4bit | Code generation |
| openai/gpt-oss-120b | 120B | AWQ | Largest tested |

FP8 is not supported on gfx1151. Use AWQ or GPTQ for large models.

## What is not included

- **No model is bundled** — downloading a model and pointing vLLM at it is a manual
  post-install step (see INSTALL.md).
- **No public/internet exposure** — the API is internal-only; cross-zone consumers get a
  firewall pinhole on port 8000 via `dependsOn ["vllm-amd:inference"]`.
- **No official AMD support** — ROCm on gfx1151 uses nightly "TheRock" builds. Known issues:
  instability under sustained heavy load
  ([ROCm#5499](https://github.com/ROCm/ROCm/issues/5499)) and memory access faults on specific
  workloads ([ROCm#5824](https://github.com/ROCm/ROCm/issues/5824)).

## Requirements

- AMD Ryzen AI MAX+ 395 (Strix Halo, gfx1151) node — default `tappaas2`
- 128 GB LPDDR5x unified memory (≥ 32 GB GPU-addressable VRAM+GTT enforced by `discover.sh`)
- 64 GB+ storage for OS + ROCm + models
- `srvWork` zone; LXC sizing (defaults from `vllm-amd.json`): 24 cores, 46 GB RAM, 32 GB disk

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:lxc` | LXC container provisioning |
| `backup:vm` | Container snapshots |

For installation steps see [INSTALL.md](./INSTALL.md).

## External references

- [Framework Community: vLLM on Strix Halo](https://community.frame.work/t/how-to-compiling-vllm-from-source-on-strix-halo/77241)
- [kyuz0/amd-strix-halo-vllm-toolboxes](https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes)
- [LLM Tracker: Strix Halo Performance](https://llm-tracker.info/AMD-Strix-Halo-(Ryzen-AI-Max+-395)-GPU-Performance)
