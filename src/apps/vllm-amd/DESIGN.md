# vllm-amd — Design notes

Implementation and tuning detail moved out of README/INSTALL (Diataxis: explanation).

## Stack

- Debian 12 LXC (privileged, `nesting=1`, swap 0 — see `vllm-amd.meta.json` `lxcOptions`)
  created by `cluster:lxc`; this module only does post-create work (issue #203).
- Docker inside the LXC runs the vLLM OpenAI API server from the community image
  `kyuz0/vllm-therock-gfx1151:latest` (ROCm nightly "TheRock" build for gfx1151).
- GPU passthrough: `/dev/kfd` and `/dev/dri/renderD128` are passed into the container;
  the compose service joins the `render` group and sets `HSA_OVERRIDE_GFX_VERSION=11.5.1`
  (and `PYTORCH_ROCM_ARCH=gfx1151` in the spec-dec variant).
- Models live on the host and are bind-mounted into the LXC (see `bindMounts` in
  `vllm-amd.meta.json`); the compose file mounts them into the vLLM container.

## Unified memory on Strix Halo

Strix Halo is a unified-memory APU: a small dedicated VRAM carveout (BIOS UMA) plus a large GTT
pool that ROCm/vLLM actually use. `discover.sh` therefore validates total GPU-addressable
memory (VRAM + GTT ≥ 32 GB), not dedicated VRAM alone. Current discovery on tappaas2: 2 GB VRAM
carveout + ~62 GB GTT, 126 GB host RAM.

## Discovery and the meta file

`discover.sh` runs from tappaas-cicd, inspects the node over SSH and MERGES results into
`vllm-amd.meta.json` (GPU device majors/minors, render node, VRAM/GTT/RAM), preserving the
curated structure (`bindMounts`, `lxcOptions`, `vllm_image`, ...). It never touches
`vllm-amd.json`. `/dev/kfd`'s major is boot-dynamic, so discovery must be re-run before each
install. It also prints an LXC sizing reference: cores = host cores − 8 (when > 16), memory =
75% of host RAM — actual sizing is set in `vllm-amd.json`.

`patch-host-gpu.sh` (run on the Proxmox host by `install.sh`) reads the meta file and prepares
GPU devices, render group and permissions plus the models directory.

## Update flow

`update.sh` bootstraps Docker and `/opt/vllm/docker-compose.yml` if missing (idempotent), then
applies OS updates in the LXC, pulls the latest vLLM image and recreates the container only if
the image changed, and prunes old images.

## Speculative decoding (EAGLE-3)

`docker-compose-specdec.yaml` is a reference setup for EAGLE-3 speculative decoding:
Qwen2.5-14B with the `qwen2.5-14b-eagle3` draft model
(`--speculative-config '{"num_speculative_tokens": 3, "method": "eagle3"}'`), plus tuning flags
`--gpu-memory-utilization 0.85 --max-model-len 8192 --max-num-seqs 8`.
`download-model.sh eagle` fetches both models. `docker-compose-smoketest.yml` is the minimal
smoke-test variant.

## References

- [Framework Community: vLLM on Strix Halo](https://community.frame.work/t/how-to-compiling-vllm-from-source-on-strix-halo/77241)
- [kyuz0/amd-strix-halo-vllm-toolboxes](https://github.com/kyuz0/amd-strix-halo-vllm-toolboxes)
- [LLM Tracker: Strix Halo Performance](https://llm-tracker.info/AMD-Strix-Halo-(Ryzen-AI-Max+-395)-GPU-Performance)
- Known ROCm issues: [ROCm#5499](https://github.com/ROCm/ROCm/issues/5499),
  [ROCm#5824](https://github.com/ROCm/ROCm/issues/5824)
