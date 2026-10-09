# vLLM-AMD — Upgrade Guide

## Upgrading to vLLM 0.29.0 on ROCm 10 (module v0.8.1)

### What is new

- The image moves from a vLLM 0.16 pre-release on ROCm 7 to vLLM 0.29.0 on
  ROCm 10.0. AMD lists vLLM 0.29.0 for ROCm 10 on this GPU (gfx1151).
- A new container gets an 80G disk (was 32G).

### Before the update

1. **Check the disk.** The update pulls the new image while the old one is
   still there. The old image alone is 28G, so a 32G disk fills up, the pull
   fails and the running container breaks. Grow the disk first; on a container
   this field is not applied by the update:

   ```bash
   pct resize <vmid> rootfs 80G        # on the node
   ```

2. **Check the served model.** A GPTQ build of a mixture-of-experts model
   (for example a Qwen3 A3B model) does not load on vLLM 0.29: the engine stops
   with `zp shape mismatch` and the container restarts in a loop. An AWQ build
   of the same model loads on both the old and the new image. So change the
   model first, on the old image, and update after that:

   ```bash
   ./download-model.sh <hf-repo-of-the-AWQ-build>
   ```

   Then point `--model` in `/opt/vllm/docker-compose.yml` at the new directory
   and run `docker compose up -d` in `/opt/vllm`.

### Measured on one site

Same model (Qwen3 30B A3B Instruct), 300 generated tokens per request:

| Image and model build | 1 request | 4 at once, total |
|---|---|---|
| old image, GPTQ | 37 tokens/s | 56 tokens/s |
| old image, AWQ | 24 tokens/s | 45 tokens/s |
| new image, AWQ | 52 tokens/s | 58 tokens/s |

### Way back

Put the old digest (in the comment next to `PINNED_IMAGE` in `update.sh`) back
in `/opt/vllm/docker-compose.yml` and run `docker compose up -d`. The container
holds no data; the models are on the bind mount.

### Verify after upgrade

```bash
module-manager test <instance>
```

The model takes a minute or two to load after the container starts; a test
that runs before that reports the API as not responding.
