# deconz:hue-bridge service

A Philips Hue–compatible bridge API, served by diyHue beside deCONZ — for consumers that
only speak Hue (for example an ABB free@home System Access Point).

## What a consumer gets

- **Network access, nothing else.** The service is declarative: `pinhole.json` opens
  TCP 80 and 443 (the Hue API) and UDP 1900 (SSDP discovery) from the consumer to the
  bridge. The consumer's `network:rules` install compiles the pinhole (auto-pinhole,
  #173). Discovery across zones additionally needs the `network:discovery` relay for
  UDP 1900.
- There is no provider-side work: install, update and delete do nothing on the bridge,
  and say so. `register-group-lights.sh` is a helper for grouping lights on the bridge,
  run by hand.

## How to use it

```json
"dependsOn": ["network:rules", "deconz:hue-bridge"]
```

Pairing the consumer with the bridge (the link-button press) is done on the consumer.

## Fields

`deconz:hue-bridge` declares no fields.
