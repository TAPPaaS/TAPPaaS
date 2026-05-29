# vllm-amd — LLM Inference on AMD iGPU

Local LLM inference using the AMD Ryzen AI MAX+ 395 integrated GPU (Radeon 8060S, Strix Halo). Runs an OpenAI-compatible API endpoint for use with LiteLLM or direct clients.

## What you get

| Capability | Access from | How |
|---|---|---|
| OpenAI-compatible inference API | Internal network | `http://vllm-amd.<zone>.internal:8000` |
| Large model support | API | Up to 120B parameters on 128GB unified memory |
| Fast inference | API | ~50 tok/s (7B FP16), ~20 tok/s (30B GPTQ-4bit) |

## Hardware requirements

- AMD Ryzen AI MAX+ 395 (Strix Halo, gfx1151) on `tappaas2`
- 128 GB LPDDR5x unified memory
- 64 GB+ storage for OS + ROCm + models

## Tested models

| Model | Size | Quantization | Notes |
|---|---|---|---|
| Qwen2.5-7B-Instruct | 7B | FP16 | Default — fast, good quality |
| Qwen3-14B-AWQ | 14B | AWQ | Good balance speed/quality |
| Qwen3-Coder-30B-GPTQ-Int4 | 30B | GPTQ-4bit | Code generation |
| openai/gpt-oss-120b | 120B | AWQ | Largest tested |

FP8 is not supported on gfx1151. Use AWQ or GPTQ for large models.

## Known limitations

- ROCm on gfx1151 uses nightly "TheRock" builds — not officially AMD-supported
- Instability under sustained heavy load ([ROCm#5499](https://github.com/ROCm/ROCm/issues/5499))
- Some memory access faults on specific workloads ([ROCm#5824](https://github.com/ROCm/ROCm/issues/5824))

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:lxc` | LXC container provisioning |
| `backup:vm` | Container snapshots |

For installation steps see [install.sh](./install.sh).

## References

- [Framework Community: vLLM on Strix Halo](https://community.frame.work/t/how-to-compiling-vllm-from-source-on-strix-halo/77241)
- [kyuz0/amd-strix-halo-vllm-toolboxes](https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes)
- [LLM Tracker: Strix Halo Performance](https://llm-tracker.info/AMD-Strix-Halo-(Ryzen-AI-Max+-395)-GPU-Performance)
