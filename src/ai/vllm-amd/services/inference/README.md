# vllm-amd:inference service

The OpenAI-compatible inference endpoint of the vLLM server on the AMD GPU host — what
LiteLLM routes to.

## What a consumer gets

- **Where vLLM is and what it serves.** Install and update write
  `/etc/secrets/vllm-inference.env` on the consumer: `VLLM_BASE_URL` (the endpoint),
  `VLLM_MODEL_ID` (the model vLLM actually serves, read live) and `VLLM_API_KEY`.
  vLLM requires that key on every API call. It is generated in the LXC on the provider's
  first update and read from there; `vllm.apiKey` in the provider's module JSON sets it
  instead. Anything without the key gets HTTP 401, so reaching port 8000 in the zone is
  not enough to use the model.
- **Network access**: `pinhole.json` opens TCP 8000 from the consumer (auto-pinhole,
  #173).
- Install and update are one converge (#495), so a change of model reaches consumers on
  their next update.

## How to use it

```json
"dependsOn": ["network:rules", "vllm-amd:inference"]
```

## Fields

`vllm-amd:inference` declares no fields.
