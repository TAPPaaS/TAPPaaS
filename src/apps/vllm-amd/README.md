# UniFi Network Controller - TAPPaaS

**Version:** 0.5.0  
**Author:** @ErikDaniel007
**Release Date:** 2026-02-22 
**Status:** Development - ALPHA 

# vllm-amd — LLM Inference on AMD iGPU (Strix Halo)

TAPPaaS module for running vLLM with AMD integrated GPU acceleration.
Designed for Minisforum S1 Max with Ryzen AI Max+ 395 (Radeon 8060S, 40 RDNA 3.5 CUs).

## Architecture

```
Proxmox Host (S1 Max)
├── Kernel: amdgpu driver loaded
├── /dev/kfd + /dev/dri/renderD128
│
└── LXC Container (Ubuntu 24.04, unprivileged)
    ├── GPU passthrough via bind-mount (no IOMMU needed)
    ├── ROCm 6.4.1 userspace (--no-dkms)
    ├── Docker
    │   └── vllm-therock-gfx1151 container
    │       └── vLLM serving OpenAI-compatible API on :8000
    └── /opt/vllm/.env — model configuration
```

## Hardware Requirements

- **CPU:** AMD Ryzen AI Max+ 395 (Strix Halo, gfx1151)
- **RAM:** 128GB LPDDR5x (shared with GPU)
- **GPU:** Radeon 8060S (40 CUs, RDNA 3.5, ~59 TFLOPS FP16)
- **Storage:** 64GB+ for OS/ROCm, plus model storage

## Host Configuration



## Installation

```bash
./install.sh vllm-amd
```

## Tested Models (128GB Strix Halo)

| Model | Size | Quantization | Max Context | Notes |
|-------|------|-------------|-------------|-------|
| Qwen/Qwen2.5-7B-Instruct | 7B | FP16 | 128k | Default. Fast, good quality |
| Qwen/Qwen3-14B-AWQ | 14B | AWQ | 40k | Good balance |
| Qwen3-Coder-30B-GPTQ-Int4 | 30B | GPTQ-4bit | 256k | Great for code |
| openai/gpt-oss-120b | 120B | AWQ | 128k | Largest tested |
| Meta-Llama-3.1-8B-Instruct | 8B | FP16 | 128k | Meta's flagship small |

**Note:** FP8 not supported on gfx1151. Use AWQ or GPTQ quantization for large models.

## Performance

- **7B FP16:** ~50 tok/s generation
- **30B GPTQ-4bit:** ~20-30 tok/s generation
- **80B AWQ-4bit:** ~15-16 tok/s generation
- **Prompt processing:** 100-880 tok/s depending on model and backend

## LXC vs VM

This module uses **LXC** instead of a VM because:
1. **No IOMMU overhead** — bind-mount is simpler and faster than PCI passthrough
2. **Near-native GPU performance** — no hypervisor translation layer
3. **Less memory overhead** — no separate kernel for the guest
4. **iGPU sharing possible** — multiple LXC containers can share the GPU

## Known Limitations

- ROCm on gfx1151 uses nightly "TheRock" builds — not officially supported by AMD
- Instability reported under sustained heavy load ([ROCm#5499](https://github.com/ROCm/ROCm/issues/5499))
- Some memory access faults on specific workloads ([ROCm#5824](https://github.com/ROCm/ROCm/issues/5824))
- Performance may degrade with containerization overhead vs bare-metal

## Sources

- [Framework Community: Compiling vLLM on Strix Halo](https://community.frame.work/t/how-to-compiling-vllm-from-source-on-strix-halo/77241)
- [kyuz0/amd-strix-halo-vllm-toolboxes](https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes)
- [Proxmox Forum: AMD GPU ROCm in LXC](https://forum.proxmox.com/threads/tutorial-run-llms-using-amd-gpu-and-rocm-in-unprivileged-lxc-container.157920/)
- [LLM Tracker: Strix Halo Performance](https://llm-tracker.info/AMD-Strix-Halo-(Ryzen-AI-Max+-395)-GPU-Performance)
- [ROCm 7.2 on Strix Halo](https://tinycomputers.io/posts/upgrading-rocm-7.0-to-7.2-on-amd-strix-halo-gfx1151.html)

For installation details see [install.sh](./install.sh).
