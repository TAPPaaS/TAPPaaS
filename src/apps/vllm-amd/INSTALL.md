# vllm-amd — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. The target node (default `tappaas2`) has an AMD Ryzen AI MAX+ 395 APU with the `amdgpu`
   kernel module loaded and `/dev/kfd` + `/dev/dri/renderD*` present.
2. Run hardware discovery from the module directory to validate the host and (re)generate
   `vllm-amd.meta.json`:

       ./discover.sh vllm-amd

   `/dev/kfd`'s device major is assigned dynamically at boot and changes across host reboots,
   so re-run `discover.sh` before every (re)install. The install aborts if the meta file is
   missing.

> To deviate from the defaults in `./vllm-amd.json` (target node, storage,
> zone/VLAN, sizing), copy the json to `/home/tappaas/config` and edit it
> before installing.

## Install

    install-module.sh vllm-amd

`cluster:lxc` creates the container; the module installer then patches the host GPU
(devices, render group, permissions, models directory) and installs Docker plus the vLLM
compose setup (`/opt/vllm/docker-compose.yml`) inside the container.

## Post-install

vLLM ships without a model — one manual step is required:

1. Download a model into the models directory (run inside the LXC, or anywhere with
   `huggingface-cli`):

       ./download-model.sh smoke      # Qwen2.5-3B  (~2 GB, quick validation)
       ./download-model.sh prod       # Qwen2.5-14B (~28 GB, production)
       ./download-model.sh eagle      # 14B + EAGLE-3 draft (~31 GB, speculative decoding)
       ./download-model.sh <hf-repo>  # any HuggingFace model

2. Set the model path in `/opt/vllm/docker-compose.yml` inside the LXC (replace the
   `--model` placeholder).

3. Start vLLM:

       pct exec <vmid> -- bash -c 'cd /opt/vllm && docker compose up -d'

Alternatively, `./test-model.sh vllm-amd` (from tappaas-cicd) downloads Qwen2.5-3B, wires it
into the compose file and runs a smoke prompt in one go.

## Verification

    test-module.sh vllm-amd

| Check | Expected |
|-------|----------|
| LXC container | running, exec works |
| GPU devices in container | `/dev/kfd` and `/dev/dri/renderD128` accessible |
| Docker daemon | running |
| vLLM container | `Up` |
| `http://127.0.0.1:8000/v1/models` (in container) | HTTP 200, lists the loaded model |
| Chat completion request | returns a response from the loaded model |

## Troubleshooting

**vLLM container is Up but the API does not respond**
The model may still be loading (large models take minutes). Watch the logs:

    pct exec <vmid> -- docker logs -f vllm

**GPU devices missing inside the container**
`/dev/kfd`'s major number changed after a host reboot, so the container's device cgroup no
longer matches. Re-run `./discover.sh vllm-amd` and reinstall (or re-run
`patch-host-gpu.sh` on the host) to refresh device permissions.

**No model loaded / inference test skipped**
Complete the post-install model step: download a model, set `--model` in
`/opt/vllm/docker-compose.yml`, then `docker compose up -d`.

**Crashes or memory faults under sustained heavy load**
Known ROCm gfx1151 nightly-build issues — see
[ROCm#5499](https://github.com/ROCm/ROCm/issues/5499) and
[ROCm#5824](https://github.com/ROCm/ROCm/issues/5824).
