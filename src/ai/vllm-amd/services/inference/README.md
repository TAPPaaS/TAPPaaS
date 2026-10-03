# vllm-amd:inference service

The OpenAI-compatible inference endpoint of the vLLM server on the AMD GPU host — what
LiteLLM routes to.

## What a consumer gets

- **Where vLLM is and what it serves.** Install and update write
  `/etc/secrets/vllm-inference.env` on the consumer: `VLLM_BASE_URL` (the endpoint),
  `VLLM_MODEL_ID` (the model vLLM actually serves, read live) and `VLLM_API_KEY`.
  vLLM runs without an API key — it is protected by zone policy and the pinhole — so the
  key is the literal `none` unless `vllm.apiKey` is set in the provider's module JSON.
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
