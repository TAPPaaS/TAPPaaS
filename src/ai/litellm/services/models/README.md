# litellm:models service

An OpenAI-compatible model endpoint through LiteLLM, with a key of the consumer's own.

## What a consumer gets

- **Its own LiteLLM virtual key.** Install creates one for the consumer (named after it)
  or reuses the one it already has, and writes `/etc/secrets/litellm-svckey.env` on the
  consumer's VM with the key and LiteLLM's base URL. The plaintext key is kept on the
  LiteLLM VM as well (`/etc/secrets/litellm-svc-<consumer>.key`), because LiteLLM shows
  it only once.
- **Network access**: `pinhole.json` opens TCP 4000 from the consumer to LiteLLM
  (auto-pinhole, #173).
- **Delete** revokes the key and removes the env file from the consumer.

## How to use it

```json
"dependsOn": ["network:rules", "litellm:models"]
```

The consumer reads its endpoint and key from `/etc/secrets/litellm-svckey.env`. Which
models the key may use is LiteLLM's configuration, not this service's.

## Fields

`litellm:models` declares no fields.
