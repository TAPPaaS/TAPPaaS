# Update policy — `network:discovery`

**Manifest:** [`fields.json`](fields.json) · **Vocabulary:** [the seven change classes and five apply modes](../../../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all services](../../../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

2 fields — all `in-place`, all `apply: "reconcile"`.

| Field | Why this class |
|---|---|
| `discoveryMdns` | Cross-zone mDNS relays; a firewall/avahi reload. |
| `discoveryUdpRelay` | Broadcast relays for protocols predating mDNS. |

Both are lists of zone pairs, reconciled by rewriting the relay configuration and
reloading. Removing a relay is as ordinary as adding one, which is what puts them
on `reconcile`.
