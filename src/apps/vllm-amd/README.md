---
name: vllm-amd — LLM Inference on AMD iGPU
description: OpenAI-compatible LLM inference on the AMD Ryzen AI MAX+ 395 integrated GPU.
kind: Guide
version: 1.0.0
language: gridtefy-B2
copyright: © 2026 TAPPaaS org
last-updated: 2026-07-03
status: approved
---

# vllm-amd — LLM Inference on AMD iGPU

Local LLM inference using the AMD Ryzen AI MAX+ 395 integrated GPU (Radeon 8060S, Strix Halo). Runs an OpenAI-compatible API endpoint for use with LiteLLM or direct clients.

## What you get

| Capability | Access from | How |
|---|---|---|
| OpenAI-compatible inference API | Internal network | `http://vllm-amd.<zone>.internal:8000` |
| Large model support | API | Up to 120B parameters on 128 GB unified memory |
| Fast inference | API | ~50 tok/s (7B FP16), ~20 tok/s (30B GPTQ-4bit) |

## What this module installs

An LXC container with Docker, ROCm (via [kyuz0/vllm-therock-gfx1151](https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes)), and a vLLM server. The container starts automatically and serves whichever model is configured in `/opt/vllm/docker-compose.yml`.

**Tested models:**

| Model | Size | Quantization | Notes |
|---|---|---|---|
| Qwen2.5-7B-Instruct | 7B | FP16 | Fast, good general quality |
| Qwen3-14B-AWQ | 14B | AWQ | Balance of speed and quality |
| Qwen3-30B-A3B-GPTQ-Int4 | 30B | GPTQ-4bit | Mixture-of-experts, low active params |
| Qwen3-Coder-30B-GPTQ-Int4 | 30B | GPTQ-4bit | Code generation variant |
| openai/gpt-oss-120b | 120B | AWQ | Largest tested |

FP8 is not supported on gfx1151. Use AWQ or GPTQ for models larger than 7B.

**Not included:** model files (downloaded separately via `scripts/install-model.sh`), SSL termination, or external load balancing.

## Requirements

- AMD Ryzen AI MAX+ 395 (Strix Halo, gfx1151) — required for the ROCm build used by this module
- 128 GB LPDDR5x unified memory on the host
- 64 GB+ available storage for OS, ROCm container image, and models
- A Proxmox node configured for LXC GPU passthrough (`/dev/kfd`, `/dev/dri/renderD128`)
- TAPPaaS `cluster:lxc` and `backup:vm` services operational on the target node

## Key decisions

**Which model to run.** Select based on RAM budget and use case. The current default is `Qwen/Qwen3-30B-A3B-GPTQ-Int4` (~24 GB); a 7B FP16 model uses ~14 GB and loads in under a minute. Change the model by editing `--model` in `/opt/vllm/docker-compose.yml` after installation, or re-run `scripts/install-model.sh` to add a model first.

**Quantization format.** AWQ and GPTQ-4bit are supported. FP8 is not. For models above 14B, quantization is required to fit within available memory.

For step-by-step installation, see [INSTALL.md](./INSTALL.md).

## Known limitations

- ROCm on gfx1151 uses nightly "TheRock" builds — not officially AMD-supported
- Instability under sustained heavy load ([ROCm#5499](https://github.com/ROCm/ROCm/issues/5499))
- Some memory access faults on specific workloads ([ROCm#5824](https://github.com/ROCm/ROCm/issues/5824))

## External references

- [Framework Community: vLLM on Strix Halo](https://community.frame.work/t/how-to-compiling-vllm-from-source-on-strix-halo/77241)
- [kyuz0/amd-strix-halo-vllm-toolboxes](https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes)
- [LLM Tracker: Strix Halo Performance](https://llm-tracker.info/AMD-Strix-Halo-(Ryzen-AI-Max+-395)-GPU-Performance)
