# coturn:turn service

A STUN/TURN relay for real-time media — what Nextcloud Talk and its high-performance
backend use when two parties cannot reach each other directly.

## What a consumer gets

- **A reachable relay.** Install checks coturn answers on UDP/TCP 3478 before the
  consumer is installed.
- **The shared TURN secret**, published to the management plane
  (`/home/tappaas/secrets/coturn.env`). coturn owns it; the consumer reads it and aligns
  its own — coturn never writes into the consumer's VM.
- **The TURN host to advertise**, stamped into the consumer's config (`turnHost`, below),
  so the consumer's NixOS configuration can hand it to its clients.
- **Relay access for its address**: coturn's allow-list admits the consumer as a peer.
  Delete takes it off again, so a reused address is not left reachable through TURN.

## How to use it

```json
"dependsOn": ["coturn:turn"]
```

`test-service.sh` checks the relay answers and the secret is published.

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`coturn:turn` owns **2** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `turnHost`

host:port of the TURN relay EXTERNAL clients use: coturn's publicDomain, which public DNS resolves to the WAN IP. A site's wildcard split-horizon answers that same name with the reverse proxy internally, which runs no TURN, so consumers advertise this alongside turnHostInternal and let ICE choose.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `<derived: coturn publicDomain or internal FQDN, port 3478>` |
| Example | `turn.example.com:3478` |
| Required by | *(none)* |
| Used by | `coturn:turn` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Stamped, never authored. Re-derived on every update of the consumer, so a coturn publicDomain change propagates on the next sweep.

**Why this change class.** A fact about the provider, refreshed on every converge; changing it re-points TURN in Talk and the HPB without touching any guest disk.

### `turnHostInternal`

host:port of the TURN relay for INTERNAL clients and server-side consumers (a Janus SFU): coturn's <vmname>.<zone0>.internal. Reachable from any zone with a pinhole into the DMZ.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | `<derived: coturn <vmname>.<zone0>.internal, port 3478>` |
| Example | `coturn.dmz.internal:3478` |
| Required by | *(none)* |
| Used by | `coturn:turn` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**About the field.** Stamped, never authored.

**Why this change class.** A fact about the provider, refreshed on every converge.

<!-- END GENERATED FIELDS -->
