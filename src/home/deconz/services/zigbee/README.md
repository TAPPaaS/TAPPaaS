# deconz:zigbee service

The deCONZ REST API and its websocket — what Home Assistant's `deconz` integration talks to.
A consumer declares it to reach the Zigbee gateway across zones.

## What a consumer gets

- **Network access, nothing else.** The service is declarative: `pinhole.json` opens
  TCP 8080 (REST, setup and polling) and TCP 8443 (websocket, live events) from the
  consumer to deCONZ. The consumer's `network:rules` install compiles the pinhole
  (auto-pinhole, #173) — allowed only when the consumer's zone is on the provider's
  pinhole-allowed-from list.
- There is no provider-side work: install, update and delete do nothing on deCONZ, and
  say so.

## How to use it

```json
"dependsOn": ["network:rules", "deconz:zigbee"]
```

Pairing Home Assistant with the gateway (the API key deCONZ hands out) is done in
Home Assistant's UI; this service only makes the gateway reachable.

## Fields

`deconz:zigbee` declares no fields.
