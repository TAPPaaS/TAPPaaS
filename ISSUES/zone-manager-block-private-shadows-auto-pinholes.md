# zone-manager "block private ranges" shadows per-module pinholes

**Discovered**: 2026-05-16, while validating issue #177 (auto-pinhole tests for #173).

## Symptom

The Deep 9b live-connectivity test for an auto-pinhole (#173) fails: traffic
from a consumer zone to a provider zone over a per-module pinhole rule is
silently dropped, even though:

- the auto-pinhole rule is correctly created in OPNsense (Deep 6b passes),
- the FQDN alias tables are correctly populated with the right IPs,
- the SYN packet from the consumer arrives at OPNsense on the right interface,
- both pfctl-table lookups return `1/1 addresses match`.

`pfctl -sr -vv` shows the auto-pinhole rule's hit counter at **0 packets**
despite many evaluations.

## Diagnosis

The actual blocker is a higher-priority rule that pf evaluates first.
`tcpdump -i pflog0 -nve` for one of the dropped SYNs:

```text
rule 187/0(match): block in on vlan0.810:
  10.80.10.148.56486 > 10.80.30.187.9091: Flags [S]
```

Rule @187 is one of three zone-manager-emitted "block private" rules on the
consumer's interface:

```
@187 block drop in log quick on vlan0.810 inet from 10.80.10.0/24 to 10.0.0.0/8
@188 block drop in log quick on vlan0.810 inet from 10.80.10.0/24 to 172.16.0.0/12
@189 block drop in log quick on vlan0.810 inet from 10.80.10.0/24 to 192.168.0.0/16
```

These rules are `quick`, so pf stops evaluating as soon as one matches. Any
test1 → 10.x.y.z traffic that doesn't first match a band-2 zone-level allow
gets dropped here, never reaching the per-module pinhole rules in band 3.

The load order on `vlan0.810` (test1) is:

```
... DHCP/IPv6/anti-lockout ...
@185 pass  test1 → test1 gateway              ← OK
@186 pass  test1 → test2.cidr                 ← test1.access-to includes test2
      pass  test1 → dmz.cidr                  ← test1.access-to includes dmz
@187 block test1 → 10.0.0.0/8                 ← THE OFFENDER: catches everything else
@188 block test1 → 172.16.0.0/12
@189 block test1 → 192.168.0.0/16
@190 pass  test1 → any                        ← would allow internet
... (band 3 per-module pinholes load here) ...
@203 pass  test-fw-a → test-fw-b on 9090      ← manual rule, 0 hits
@207 pass  test-fw-a → test-fw-c on 9091      ← auto-pinhole, 0 hits
```

For `test-fw-a (test1) → test-fw-b (test2):9090` the **band-2 zone-level
allow @186 catches it before @187 fires**, so it works — but it's the
zone-level rule that did the work, not the per-module pinhole. The
per-module pinhole rule sits idle, never hit.

For `test-fw-a (test1) → test-fw-c (test3):9091` there is no band-2 zone-level
allow (test1.access-to deliberately excludes test3 — that's the whole point
of auto-pinholes), so traffic falls through to @187 block and is dropped.
The auto-pinhole pass at @207 never gets a chance.

## Why this only surfaces now

Before issue #173, per-module rules effectively *duplicated* zone-level
access-to in a more granular form (e.g. "test1 → test-fw-b:9090 specifically,
within the already-permitted test1→test2 zone path"). They never *granted
new* connectivity beyond what zone-level rules already permitted, so they
were always shadowed by the zone-level allow — but harmlessly so, since the
zone-level allow carried the traffic.

Issue #173 introduced per-module rules that **do** grant new connectivity
(zone X is in zone Y's `pinhole-allowed-from` but not `access-to`). These
rules need to be evaluated *before* the "block private ranges" cluster, but
the current sequence band layout puts them after it:

| Band | Range | Source | Order |
|------|-------|--------|-------|
| 1    | 100–999 | zone-manager (infra) | first |
| 2    | 1000–9999 | zone-manager (deny defaults — incl. block private) | early |
| 3    | 10000–19999 | rules-manager ingress (manual + auto-pinholes) | late |
| 5    | 30000–39999 | zone-manager (zone-level allows) | last |

For auto-pinholes to actually grant traffic, **band 3 (per-module pinholes)
must load before any quick blocks in band 2**. Either:

- promote auto-pinholes to a band lower than the block-private rules, or
- make zone-manager's block-private rules non-quick and let the per-module
  pass rules in band 3 override them, or
- omit the block-private rule entirely for source-destination pairs where
  the destination zone's `pinhole-allowed-from` already authorises the
  source — in which case the auto-pinhole becomes the single source of
  truth for that path.

The third option is the cleanest: zone-manager knows the full pinhole
authorisation graph from `zones.json`, and the "block private" rules are
meant to deny *unauthorised* traffic — by definition that should not
include pinhole-allowed source zones.

## Reproduction

```bash
cd /home/tappaas/TAPPaaS/src/foundation/firewall
./test.sh --deep
```

`Deep 9b: Auto-pinhole permits real traffic` will fail with:

```
✗ test-fw-a → test-fw-c:9091 (expected auto-pinhole to allow, gave up after 6×15s)
```

Inspect with (firewall.mgmt.internal):

```sh
pfctl -sr -vv | awk '/vlan0.810.*9091/{print; getline; print}'
tcpdump -i pflog0 -nve 'tcp port 9091'
```

## Workaround for the test suite

Treat Deep 9b's failure as **expected** until zone-manager is fixed. The
companion check `test-fw-a → test-fw-c:22 BLOCKED` already passes — that
half of AC-2 proves the firewall *is* filtering. Auto-pinhole rule
correctness is fully proven by:

- Standard 9 (check-mode): AC-1 (form), AC-3 (warn), AC-4 (same-zone) — all green
- Deep 6b: rule appears in OPNsense with the right shape, src/dst aliases, port

The only thing this issue blocks is the live-traffic half of AC-2 — and that
gap is structural to the zone-manager rule pipeline, not the auto-pinhole.

## Scope note

Out of scope for #177. Filing as a separate ticket so the test suite can be
adjusted (Deep 9b → "skip with diagnostic" until this is resolved) without
hiding the underlying bug.
