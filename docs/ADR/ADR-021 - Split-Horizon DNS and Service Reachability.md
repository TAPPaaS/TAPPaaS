# ADR-021 — Split-Horizon DNS and Service Reachability

| | |
|---|---|
| **Status** | Accepted — **implemented** and verified end-to-end (commits `1a90f27`, `73343e7`). #618 proved closed live: from a service-zone VM the DMZ gateway answers on tcp/443 while tcp/8443 (firewall GUI) and tcp/22 (SSH) are refused — all three were open before. One resolver (`network-manager split-horizon-target`) now answers for all three #577 writers, guarded by `scripts/test/test-split-horizon-single-writer.sh`; `network/test.sh --deep` Deep 11d/11e assert the `/32` and the R3 exit codes. §Open questions lists what remains. |
| **Version** | 0.7 |
| **Date** | 2026-09-11 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-005 Variant/Domain Architecture](<ADR-005-variant-domain-architecture.md>) §6 (the split-horizon idea), [ADR-014 Zone and Environment Lifecycle](<ADR-014 - Zone and Environment Lifecycle.md>) (what a zone and an environment *are*) |
| **Refines** | ADR-005 §6 — which stated the goal but never named the resolution rule, leaving three implementations to infer it differently. |
| **Closes / addresses** | **#577** (wildcard split-horizon has two writers with different zone rules — three, in fact) and **#594** (duplicate `*` rows read as converged — closed by the cardinality-aware D5 writer, see Appendix A). Supersedes the interim reading of **#504** recorded in `acme-setup.sh` and `clients.ts`. Related: **#474** (a `redirect` zone permits local-data only at the apex), **#505** (wildcard supersedes per-service). **Also closes #618** (re-scoped to its DMZ instance — see D3b). **Depends on #589** (closed 2026-09-07) — the tooling must be able to establish that Caddy is running before the DMZ gateway carries internal traffic too. |
| **Changelog** | v0.1 first stab: reachability invariant, one resolver, three cases. v0.2 (operator decision): the target is **the DMZ gateway, always** (D2), backed by a **zone invariant** (D3) — this replaces v0.1's client-zone-gateway rule, dissolves the one-apex-target problem, and answers three of v0.1's five open questions. Also: a wildcard **certificate** does not imply a wildcard **record** (D4), and R3's unpublished-service case is worked through as Case 4. v0.3 (operator simplification): D3's entitlement-set derivation is replaced by the invariant **`internet` implies `dmz`** — reaching published services is the same privilege as reaching the internet, which grants nothing new because an internet-capable zone can already reach the same Caddy via the WAN hairpin. Removes the `proxyAllowedZones`-derived entitlement set entirely and makes the rule authored (like the existing `mgmt.access-to` invariant) rather than validated. v0.4 (operator review): **D1 no longer claims reachability** — the invariant is only that the answer is Caddy; whether a caller can reach it is a per-zone question answered by D2/D3, and a zone without `internet`/`dmz` uses `.internal` + pinholes instead. **Case 3 is re-cast around identity**, not zone lists: both populations resolve and connect identically, and Authentik group membership decides entitlement — `proxyAllowedZones` is demoted to the coarse public/internal split it is good for. R3 gains the `access-to` row (published → `dmz`; unpublished → the service's own zone). v0.5 (review response, #577): **D3 is withdrawn, not amended.** The reachability it asked for already ships as the **#366 caddy-reach rule** — a pass to the DMZ gateway `/32` on tcp/80+443, emitted per internet-capable zone by `zone_manager._configure_caddy_reachability` and live on the reference site. So no `access-to` grant is needed, no zone-wide widening happens, and the review's objection — that `access-to` grants a whole subnet, and the DMZ holds workloads — is answered by not using `access-to` at all. D3 now *states* the existing rule instead of inventing a second, wider one. **Overlay zones are the gap that remains**: `admin` has no `internet`, so it gets no rule and would lose the three records that sit on the mgmt gateway today — extending the rule to non-isolated Overlay zones (**D3a**) is a prerequisite of the cutover, not an open question. Also: #589 closed, so the blast-radius risk keeps its cost entry but no longer blocks; diagnosability joins D4's table. v0.6 (#618): **D3b** picks up the two loose ends at the DMZ gateway that D2 is what makes matter, and **closes the re-scoped #618 as part of this ADR's implementation** rather than alongside it. The DMZ zone is excluded from the caddy-reach rule and leans on an unrestricted gateway rule that #399 exists to remove; and the Service archetype still seeds `access-to: ["internet","dmz"]`, the last `access-to` edge into the DMZ, which compiles to whole-subnet/all-ports and was probe-confirmed to reach the firewall GUI and SSH from a tier-1 service VM. Both are fixed here. Consequence for v0.5's "no `zones.json` edit at all": there is now exactly one, and it is a **removal**. v0.7 (implemented): built, deployed and verified on the reference site. Two things the implementation changed in the design's own account of itself — (a) **the record write had to be reaped, not just stopped**: zone rules were only ever *added*, so dropping `dmz` from a Service zone left `Zone <srv> -> dmz` live and closed nothing; a stale-rule reaper was required for D3b to have any effect; (b) **an Overlay zone's firewall interface comes from its `bridge` field** (`admin` → `wireguard`), which D3a did not name. Documentation impact reconciled against what actually landed, including a supersession note on ADR-005 §6, which still prescribed the retired client-zone rule. |

## Context

A TAPPaaS service is published at **one URL** — `openwebui.example.org` — and must resolve
correctly whether the client is on the public internet, in a client zone, in the management
zone, or in the service zone next to it. That is *split-horizon DNS*: the same name, a
different answer inside than outside.

The mechanism has three moving parts:

| Part | Where it runs | Role |
|---|---|---|
| **Caddy** (`os-caddy`) | **on the OPNsense firewall** | terminates TLS for every published name, applies the identity gate, and proxies to the service VM. It listens on **every** interface the firewall owns — i.e. at **each zone's gateway IP**, `10.x.y.1`. |
| **Unbound** | on the firewall, `10.0.0.1:53` | the internal resolver. Holds the *inside* answer as a host override. Dnsmasq cannot do this — it does not serve public domains and cannot express a wildcard. |
| **Zone policy** | `zones.json` → `zone_manager` | `access-to` and `pinhole-allowed-from` decide which zone may reach which target *subnet*. Separately — and this is the part all three writers below missed — the **#366 caddy-reach rule** opens the DMZ gateway `/32` on tcp/80+443 to every internet-capable zone, with no `access-to` entry involved. |

**Caddy living on the firewall, answering on every `10.x.y.1`, is the fact that makes this
tractable** — and the fact all three current implementations lost sight of. The inside answer
does not have to be the address of the service, or of the service's zone. It only has to be
*some* Caddy listener the client may reach.

### The problem this ADR exists to fix

Three code paths write the internal answer, and they resolve it from different zones:

| Writer | Record it owns | Zone it resolves | Cites |
|---|---|---|---|
| `network/services/proxy/update-service.sh` → `proxy_split_horizon_gateway()` | per-service `host.domain` | the authorized **client** zone (`home`→`work`→`mgmt`) | #504, ADR-005 §6 |
| `tappaas-cicd/scripts/acme-setup.sh` (wildcard mode) | the wildcard `*` | the environment's **service** zone, fallback **dmz** | #504, ADR-005 §6 |
| `manager/environment-manager/src/clients.ts` → `wildcardDnsState()` | the wildcard `*` | the environment's **service** zone, fallback **dmz** | #504, ADR-005 §6 |

All three cite the same authority and disagree. #577 read this as 1-vs-1; it is 2-vs-1. The live
record set showed the drift plainly on 2026-09-05 — 5 records on the dmz gateway, 3 on mgmt, 1 on
a client-zone gateway — with no rule that explains all three. It is 5 / 3 / 0 as of 2026-09-10;
the client-zone record has since been rewritten by one of the other two writers, which is the
drift continuing rather than resolving.

### Why the obvious fixes both fail

*Point the answer at the service zone* (what two of the three do): a `home` client is not
authorized into a Service zone, so the answer is unreachable. This is what #504 was reacting
against, and it did not fix it — it swapped one denied address for another.

*Point the answer at the client's own zone gateway* (what the proxy does, and what v0.1 of this
ADR proposed): always reachable, but it needs **one answer per client zone**. Unbound's wildcard
installs `local-zone: "<domain>" redirect`, which has a **single apex target** — so a site with
two client zones cannot express it, and service-to-service lookups have no defined answer at
all.

Both failures come from trying to encode *authorization* in the *address*. The decision below
stops doing that.

---

## Requirements

These come before the decision because they constrain it, and because two of the three current
implementations satisfy only the first.

### R1. Caddy is always in the path — the identity gate is not optional

The internal answer MUST resolve to a **Caddy listener**, never to the service VM's own address.
Caddy is where TLS terminates *and* where the per-service identity gate lives — the
`forward_auth` handler to Authentik's embedded outpost, plus the `proxyAllowedZones` access
list. A DNS answer that points straight at the VM (`10.2.0.x:8080`) is not merely a different
route to the same place: it **bypasses authentication entirely**.

*Split-horizon exists so that internal clients get the same gated path as external ones, not so
that they get a shortcut around it.* Any future optimisation that answers with a service address
must be rejected on this ground alone.

### R2. Both certificate models must work, and neither may change the address

| Certificate strategy | Issued by | Covers |
|---|---|---|
| per-service (default) | Caddy, HTTP-01 | one **cert** per published host |
| wildcard | OPNsense ACME (`acme-setup.sh`), DNS-01 | one **cert** for `*.<domain>` |

The certificate strategy decides **who issues the cert and what it covers**. It MUST NOT decide
the **address**, and — see D4 — it does not decide the **record shape** either.

### R3. A service with no external DNS entry degrades — it must not fail

A module may have no public DNS record at all — deliberately (internal-only), or transitionally
(the record is not created yet, or the site has no public domain). ACME cannot issue for a name
that does not resolve publicly, so there is no certificate and nothing for Caddy to serve.

**This is a supported configuration, not an error.**

| | Published service | **Unpublished service** |
|---|---|---|
| Reachable at | `service.example.org` | `<vmname>.<zone>.internal` **only** |
| **What makes it reachable** | the **caddy-reach rule** (D3) — a `/32` on tcp/80+443, already emitted; **no `access-to` entry at all** | **`access-to` the zone of the service** — plus a pinhole; the client talks to the VM directly |
| TLS | yes | **none** — plain HTTP to the service port |
| Identity gate | yes (Caddy `forward_auth` → Authentik) | **none** — Caddy is not in the path |
| Split-horizon record | the DMZ gateway (D2) | **none** |
| Install / converge | succeeds | **succeeds**, with one clear warning |

> That row is the crux: publishing a service means clients need **no `access-to` grant at all** —
> the caddy-reach `/32` already covers it, and they never touch the service's own zone. Not
> publishing it means every client that
> needs it must be granted access into **the service's zone**, which is a far wider and more
> per-service grant. Publishing is the *narrower* configuration, not the looser one.

The degraded mode is explicitly *less* capable — no cert **and** no identity gating, because
R1's gate lives in the Caddy path this service does not have. The internal name
`<vmname>.<zone>.internal` is already served by Dnsmasq from the DHCP reservation, so it needs
no work here; the requirement is that the publishing path **detects the absence and stops
cleanly**.

> Today `proxy_split_horizon_gateway` failing produces
> `Could not derive a split-horizon gateway … — register DNS manually`, which conflates "this
> service is deliberately unpublished" with "I could not work out the address for a service that
> should be published". R3 requires these be different messages, only the second a problem.

---

## Decision — the model

### D1. The internal answer is Caddy — nothing more is claimed

> **The internal answer for a published name MUST be a Caddy listener.**

That is the whole invariant, and it is a property of the **record**, not of the caller. It is
**R1**: Caddy carries TLS and the identity gate, so an answer that routes around it is a
security regression, not an optimisation.

Whether a given caller can actually *reach* that answer is deliberately **not** part of this
invariant — it depends on which zone the caller lives in, and is settled by D2/D3. A zone
without `internet` access cannot use a public URL at all; that is not a broken record, it
is a correctly restricted sandbox, and such a client reaches services the way any other
restricted client does: by the `<vmname>.<zone>.internal` name and an explicit pinhole.

> v0.2 folded reachability into this invariant and thereby implied DNS should answer differently
> per caller — the assumption that produced the whole family of per-zone-address schemes. One
> record, one answer; reachability is a separate, per-zone question.

### D2. The target is the DMZ gateway — one answer, for everyone

> **Every split-horizon record for a published name resolves to the DMZ zone's gateway
> (`10.6.0.1` on the reference site) — regardless of which zone asked.**

Unbound holds **one** answer per published name. There is no resolution order, no per-zone
derivation, no per-module input, and nothing for three writers to infer differently. Whether the
client can *use* that answer is not DNS's business — it is decided by the firewall (D3) and then
by Caddy's access-list.

The DMZ gateway is a Caddy listener (R1 ✔) and, given D3, one every internet-capable client may
reach (D1 ✔).

This is the choice v0.1 got wrong. Encoding *which client is allowed* into *which address is
returned* is what produced both the drift and the one-apex-target dead end. Under D2:

- **DNS says "go to Caddy". Caddy says "you may / you may not".** Authorization moves entirely
  out of the resolver and into the layer that can actually express it per-service.
- A wildcard record becomes viable for any number of client zones, because there is only ever
  one correct answer to put at the apex.
- Service-to-service lookups need no special case: a VM in `srv` gets the same address.
- A client whose zone has **no `internet`** gets a **timeout** — exactly as it
  would for any other external web service. That is the same behaviour a restricted sandbox
  already has for `example.com`, so it needs no explanation and no special handling: a zone cut
  off from the internet is cut off from published services too, by the same mechanism.
- A client that *can* reach Caddy but is not entitled to the service is refused **by Caddy**,
  where the refusal is legible, rather than silently dropped at the firewall.

### D3. Reachability is a host-scoped rule that already exists — not a zone grant

> **Every zone that may reach the internet already gets a pass to the DMZ gateway `/32` on
> tcp/80 and 443 — and to nothing else in the DMZ.** This ADR does not introduce that rule
> (#366 did); it names it as the thing D2 stands on.

`zone_manager._configure_caddy_reachability` emits, per internet-capable zone, a band-1 pass
`<zone net> → <dmz gateway>/32 : tcp 80,443`, ordered ahead of that zone's RFC1918 block so the
packet reaches Caddy without the zone listing `dmz` anywhere. Its inline comment already states
D2's rationale verbatim. The rules are live on the reference site for `home`, `guest`,
`iotCloud`, `mgmt` and the service zone.

Isolation is unaffected and needs no new expression: a zone with no `internet` — `iotLocal`,
`iotCams` — gets no rule, resolves `10.6.0.1` like everyone else, and cannot connect. The
isolation was already expressed by withholding `internet`.

**Why not `access-to: dmz`.** Drafts v0.3 and v0.4 proposed the invariant *`internet` implies
`dmz`*, argued safe because an internet-capable zone can already reach that Caddy via the WAN
hairpin. The argument holds for the **gateway address** and not for the **zone**: `access-to`
grants the entire source subnet the entire target subnet (`zones.json` §access_mechanisms;
`rules_manager._resolve_peer_net` resolves a peer to its `ip_network`), and the DMZ is a /24 that
holds workloads — `vaultwarden` and `coturn` today. A guest or internet-capable IoT zone gaining
reach into that subnet is a different proposition from gaining reach to a reverse proxy that
refuses it. The invariant is therefore **withdrawn**: it was strictly wider than a rule that
already existed, and it changed `zones.json` to obtain reachability the firewall was already
providing.

> `iotUntrust` is the one uncomfortable case: it is `isolated: true` yet carries `internet`, so
> when enabled it receives the caddy-reach rule. That is a `/32` on two ports behind Caddy's
> ACL, not subnet reach — but it is better stated here than discovered later.

#### D3a. Overlay zones need the same rule — a prerequisite, not an open question

The candidate set is selected on `internet` in `access-to`. An Overlay zone has none: `admin` is
`access-to: ["mgmt"]`, `netbird` and `edge` are `[]`. So no overlay gets the rule, and under D2
a peer that resolves `10.6.0.1` has no path to it.

This is not hypothetical. On the reference site the *only* rule on the `wireguard` interface is
`tappaas-admin admin->mgmt` (destination `10.0.0.0/24`), and the three records D2 moves —
`network`, `logging`, `unifi-os` — sit on `10.0.0.1` today. Moving them to `10.6.0.1` **breaks
remote admin access to all three**. It is the same defect the #577 review raised for `netbird`,
on the overlay that is actually carrying traffic.

> **The candidate set MUST be widened to include `type: Overlay` zones with a non-empty
> `access-to`, on the same `/32` + tcp/80,443 terms, and that MUST land before any record
> moves.** `netbird` and `edge` (`access-to: []`) stay out: `netbird` is inert on the reference
> firewall today (no 100.64/10 route), and admitting an overlay to Caddy is a decision to take
> when that overlay is terminated, not pre-emptively.

An overlay's interface exists only where its tunnel is deployed: `admin` is the live case only on
a site running admin-vpn. Elsewhere the template `admin` zone keeps its `access-to` but there is
no `wireguard` interface, so the rule is skipped with a warning rather than attempted (#640).

#### D3b. The DMZ gateway's two loose ends — **closes #618**

Both sit at `10.6.0.1`, both predate this ADR, and both are D2's problem now, because D2 is what
points every internal client at that address.

**(i) The DMZ zone is excluded from the caddy-reach rule.** The candidate filter skips it
(`z.name != dmz.name`) on the reasoning that it "reaches the gateway locally". Live, "locally" is
one rule — `Zone dmz -> gateway`, `10.6.0.1/32`, protocol **any**, no port — and #399 exists to
restrict exactly that rule to DNS/NTP/DHCP/ICMP. When #399 lands, a DMZ-resident VM loses tcp/443
to Caddy and with it every published name, and there is no second rule to fall back on. No DMZ
workload is deployed on the reference site today, but `vaultwarden` and `coturn` are the two
modules that declare `zone0: dmz`.

> **Stop skipping `dmz`**: it gets the same `/32` + tcp/80,443 rule as every other zone. That is
> strictly narrower than what it relies on today, and it makes #399 and this ADR independent
> rather than a pair that must land together.

**(ii) The Service archetype still seeds `access-to: ["internet", "dmz"]`** — `archetypes.ts:46`
and `zones.ts:240` — which is the last `access-to` edge pointing into the DMZ and the one D3's
withdrawal does not reach. It compiles to the whole subnet on every port, ahead of the block
band:

```
opt1  rossen  36101  pass  any  →  10.6.0.0/24     Zone rossen -> dmz
```

`10.6.0.1` is inside that subnet, and `webgui.interfaces` / `ssh.interfaces` are unset, so the
firewall GUI and SSH answer there. Probed from a service VM (`openwebui`, `10.2.0.163`) on
2026-09-10: **`10.6.0.1:8443` and `:22` both open** — a tier-1 zone reaching the control plane,
against `zones.json`'s own isolation invariant. #399's fix does not touch this rule, so it
survives #399 intact.

The grant is redundant for exactly the reason the client-zone grant was: `rossen` already carries
`Zone rossen -> caddy https/http` to the `/32`.

> **Drop `dmz` from the Service seed** in both the archetype and the new-zone default, and retire
> it from existing Service zones on reconcile. A service VM that must reach a DMZ *workload*
> declares a pinhole (`dmz.pinhole-allowed-from`) — the mechanism this repo already uses for that
> — instead of a zone-wide grant that happens to include the firewall.

> **Implementation requirement — not deferred.** **#618 is closed by this ADR, not alongside it**,
> in the same sense as #594 in Appendix A. The D3 work already touches the caddy-reach candidate
> set and the zone seed, which is where both halves live; shipping D3 without them leaves D2
> depending on a rule #399 is about to remove, and leaves the control-plane exposure in place on
> every site that has a Service zone. **The ADR is not "done" until (a) the `dmz` zone carries its
> own caddy-reach rule and (b) no zone has `dmz` in `access-to`.**
>
> The **general** form of #618 — that *any* `access-to` edge reaches its target's gateway on all
> ports, because the loop passes neither `protocol` nor `destination_port` (both of which
> `_create_or_skip_rule` already accepts) — is wider than this ADR and stays with #399.

### D4. A wildcard certificate does not imply a wildcard record

`dnsMode` selects the **certificate strategy** (R2). It does **not** dictate the Unbound record
shape. The two are independent, and under D2 the record shape no longer affects correctness at
all — every record carries the same address, so `*` and per-host entries resolve identically.

| Certificate | Record shape | Verdict |
|---|---|---|
| wildcard (`*.example.org`) | wildcard `*` | valid — fewest records |
| **wildcard** | **per-service** | **valid, and often preferable** — explicit records, no `redirect`-zone apex constraints (#474), no collision pruning (#505), and **a name that is not published does not resolve**: a wildcard answers for every name under the domain, including ones in no Caddy handler, which sent a live diagnosis 15 minutes the wrong way during the 2026-09-06 outage |
| per-service | per-service | valid — the default |
| per-service | wildcard | valid but pointless — a wildcard record with no wildcard cert publishes names Caddy cannot serve |

Keeping this as one field is deliberate: a second field would be one more thing to disagree
with itself. The ADR's requirement is that the implementation **not infer record shape from
certificate strategy**, and that the pairing above be documented where `dnsMode` is.

### D5. One resolver, one implementation

Even reduced to "return the DMZ gateway", this must be **one** function that all writers call —
not one rule transcribed into bash and TypeScript, which is exactly what produced #577. It also
owns the R3 decision (is this name published at all?) so that too is answered once.

```
split_horizon_target(domain) -> (ip, "dmz") | UNPUBLISHED | ERROR
```

Concretely: a `network-manager split-horizon-target` subcommand invoked by
`network/services/proxy`, `acme-setup.sh`, and `environment-manager`.

---

## Use cases

Throughout: service module **`openwebui`**, published at **`openwebui.example.org`**, VM in a
**Service** zone, Caddy on the firewall, Unbound at `10.0.0.1`.

| Zone | Type | Subnet | Gateway (= a Caddy listener) |
|---|---|---|---|
| `mgmt` | Management | `10.0.0.0/24` | `10.0.0.1` |
| `home` | Client | `10.3.10.0/24` | `10.3.10.1` |
| `work` | Client | `10.3.20.0/24` | `10.3.20.1` |
| `srv` | Service | `10.2.0.0/24` | `10.2.0.1` |
| `srv2` | Service | `10.2.1.0/24` | `10.2.1.1` |
| **`dmz`** | DMZ | `10.6.0.0/24` | **`10.6.0.1`** ← the answer, in every case |

---

### Case 1 — one environment, one client zone

Environment `home-env` (domain `example.org`, `network.zone: srv`), client zone `home`,
`openwebui` deployed into `srv`.

**Information flow — same URL, four origins, one Caddy**

```
                          openwebui.example.org
                                  │
  ┌───────────────────────────────┼────────────────────────────────┐
  │ external client               │ internal client (any zone)     │
  │  public DNS → WAN IP          │  Unbound → 10.6.0.1 (dmz gw)   │
  │        │                      │        │                       │
  │        ▼                      │        ▼                       │
  │  firewall WAN:443 ────────────┴──▶ CADDY (on the firewall)     │
  │  (rule: allow WAN→wanip:443)      terminates TLS               │
  │                                            │                   │
  │                                            │ 1. access-list    │
  │                                            │    (proxyAllowedZones)
  │                                            │ 2. forward_auth   │
  │                                            │    → Authentik    │
  │                                            ▼                   │
  │                                    upstream: openwebui.srv     │
  │                                    (10.2.0.x:8080)             │
  └────────────────────────────────────────────────────────────────┘
```

**Resolution per origin**

Every internal client gets the **same** answer. The only thing that differs by zone is whether
it can reach that answer at all:

| Client is in | Unbound answer | Can it reach Caddy? |
|---|---|---|
| `home` (client) | `10.6.0.1` | ✅ has `internet` ⟹ caddy-reach rule (D3) |
| `mgmt` | `10.6.0.1` | ✅ |
| `srv` (the service zone) | `10.6.0.1` | ✅ |
| `dmz` | `10.6.0.1` | ✅ own gateway |
| `guest` (has `internet`) | `10.6.0.1` | ✅ |
| `iotLocal` (no `internet`) | `10.6.0.1` | ❌ **timeout** — no caddy-reach rule, exactly as for any external site |
| `admin` (overlay VPN peer) | `10.6.0.1` | ✅ **once D3a lands** — ❌ today |
| external | *not Unbound* — public DNS → WAN IP | ✅ WAN rule |

**From Caddy onward every row is identical** — TLS terminates, the identity gate runs
(`forward_auth` → Authentik), and the request is proxied to `openwebui.srv`. There is no
per-zone branch after this point, which is the whole benefit of D2.

So access is decided by **who you are, not where you are**: a `guest` device reaches Caddy and
is then asked to authenticate like everyone else, and most guests simply have no account or no
entitlement, so they get no further. That is the zero-trust position — the network position was
never doing this work, it only ever looked like it was.

**Rules required**

*Zone rules (`zones.json`)* — **nothing in this file changes.**

| Zone | Setting | Value | Why |
|---|---|---|---|
| `home` | `access-to` | `[internet]` — **unchanged** | reach to Caddy is the D3 rule, not an `access-to` entry |
| `srv` | `type` | `Service` | environment binds a service segment (ADR-014) |
| `srv` | `access-to` | `[internet]` — **`dmz` removed** (D3b) | the seed's `dmz` grant is redundant, and it reaches the firewall on 8443/22 |
| `srv` | `pinhole-allowed-from` | `[dmz]` | Caddy's upstream hop into the VM |
| `guest` | `access-to` | `[internet]` — unchanged | reaches Caddy by D3, refused by Caddy's ACL |
| `iotLocal`, `iotCams` | `access-to` | `[]` — unchanged | no `internet`, so no caddy-reach rule: isolated as intended |

> **The only `zones.json` change this ADR asks for is a removal** — `dmz` leaves the Service
> zone's `access-to` (D3b). Nothing gains a grant. Reachability comes from the D3 rule, which
> `zone_manager` already derives from `internet`. The only authored policy is
> `pinhole-allowed-from` on the service zone, and the module's `proxyAllowedZones`.

*Module rules (`openwebui.json`)*

| Field | Value | Why |
|---|---|---|
| `zone0` | `srv` | the VM's zone |
| `proxyDomain` | `openwebui.example.org` | the published name — its presence is what makes this a published service at all (R3) |
| `proxyAllowedZones` | *unset* | **the normal case.** Internal clients reach it; the identity gate decides who gets in |
| `proxyAllowedZones` | `[…, internet]` | the one value with real consequence: adding `internet` makes the service answer for **external** clients too |

**On `proxyAllowedZones`.** It is a coarse, zone-level pre-filter in front of the identity gate,
and it is easy to over-read. Two things about it matter here and nothing else does:

- Leaving it **unset** is the normal, correct configuration for a published service. The default
  admits the internal zones and excludes the internet.
- Adding **`internet`** is how a service becomes publicly reachable. That is a real decision.

Everything else it can express — narrowing to a specific list of internal zones — is a
belt-and-braces filter *in addition to* authentication, not the mechanism that protects the
service. **The identity gate is what protects the service.** A zone list that lets someone
through still leaves them at an Authentik login; a zone list that shuts someone out only saves
them the round trip. Case 3 shows why leaning on it for isolation is the wrong instinct.

---

### Case 2 — the same service in a second environment

Add environment `work-env` (domain `work.example.org`, `network.zone: srv2`), deployed as
`openwebui-work-env` (ADR-007 P5 naming), published at `openwebui.work.example.org`.

| Deployment | Published name | Env service zone | Inside answer |
|---|---|---|---|
| `openwebui` | `openwebui.example.org` | `srv` | `10.6.0.1` |
| `openwebui-work-env` | `openwebui.work.example.org` | `srv2` | `10.6.0.1` |

**Both resolve to the same address, and that is the point.** Caddy distinguishes the two
deployments by **SNI / Host header**, not by address: `openwebui.example.org` → upstream in
`srv`; `openwebui.work.example.org` → upstream in `srv2`. Adding an environment adds a Caddy
handler and a DNS record; it adds no new address and no new zone grant.

**Rules required** (delta from Case 1)

*Zone rules*

| Zone | Setting | Value | Why |
|---|---|---|---|
| `srv2` | `type` | `Service` | second environment's segment |
| `srv2` | `access-to` | `[internet]` — no `dmz` (D3b) | caddy-reach comes from D3, not from `access-to` |
| `srv2` | `pinhole-allowed-from` | `[dmz]` | Caddy's upstream hop into `srv2` |

*Module rules* (`openwebui-work-env.json`)

| Field | Value | Why |
|---|---|---|
| `environment` | `work-env` | drives vmname + `zone0` from the env (`network.zone: srv2`) |
| `proxyDomain` | `openwebui.work.example.org` | distinct name — the SNI Caddy routes on |

---

### Case 3 — two populations, each entitled to a different environment

Everyone in `home-env` may use `openwebui.example.org`; everyone in `work-env` may use
`openwebui.work.example.org`; neither may use the other's.

**There is nothing new to configure at the network layer.** Both names resolve to `10.6.0.1`,
from every zone. Both client zones have identical `access-to`. Both requests reach the same
Caddy. The differentiation is entirely in the **identity layer**:

| Step | `home` user → `openwebui.example.org` | `work` user → `openwebui.example.org` |
|---|---|---|
| Unbound | `10.6.0.1` | `10.6.0.1` |
| Firewall | allowed (caddy-reach, D3) | allowed (caddy-reach, D3) |
| Caddy | routes by SNI to the `home-env` handler | same handler |
| **`forward_auth` → Authentik** | authenticates; **is entitled** → in | authenticates; **not entitled** → refused |
| Upstream | `srv` | — |

That is the zero-trust position, and it is simpler than any zone-based scheme: the question
"may this person use this service?" is answered once, by Authentik, using group membership —
not by enumerating client zones per module, in two places, and hoping they agree.

It is also the only formulation that survives contact with reality: the same person on a laptop
in `home`, on a phone on `guest` Wi-Fi, and over the `netbird` overlay is **one identity in
three zones**. A zone-based rule gets that wrong three different ways; an identity-based one
does not have the problem.

**And the wildcard works here.** One `*.example.org → 10.6.0.1` is correct for every zone at
once, because the address encodes nothing about who may use it. This case was *impossible* to
express with a wildcard under v0.1.

**Rules required**

*Zone rules* — **none.** Both client zones stay `[internet]`, and D3's rule gives both the same
reach to the same Caddy. The
service zones keep `pinhole-allowed-from: [dmz]` so only Caddy reaches the VMs. Nothing here
distinguishes the two populations, and nothing should.

*Module rules*

| Module | Field | Value | Why |
|---|---|---|---|
| `openwebui` | `proxyDomain` | `openwebui.example.org` | the SNI Caddy routes on |
| `openwebui-work-env` | `proxyDomain` | `openwebui.work.example.org` | ditto |
| both | `proxyAllowedZones` | *unset* | zone filtering is not the mechanism — see below |
| both | `dependsOn` | `identity:accessControl` | wires `forward_auth`; **this is the isolation** |

*Identity rules* — where the case is actually expressed

| Entitlement | Where it lives |
|---|---|
| who may use `openwebui.example.org` | an Authentik group bound to that application |
| who may use `openwebui.work.example.org` | a different group, bound to the other application |
| membership | `people-manager`, per person — not per zone |

> **Do not use `proxyAllowedZones` to separate these.** It looks like it would work — it is why
> v0.1 put the isolation there — but it binds entitlement to *network position*, which breaks
> the moment a legitimate user connects from a different zone, and it duplicates a decision
> Authentik is already making. Reserve it for the coarse public/internal split (Case 1).

---

### Case 4 — a service with no external DNS entry (R3)

`openwebui` is deployed into `srv` but there is **no public record** for
`openwebui.example.org` — internal-only by choice, or the domain is not delegated yet.

**Nothing to split.** No public answer to differ from, so no split-horizon record, no ACME
certificate, no Caddy handler:

```
                    openwebui.example.org          <vmname>.<zone>.internal
                    ─────────────────────          ────────────────────────
  external client   NXDOMAIN (no public record)     n/a
  internal client   NXDOMAIN (no override)          Dnsmasq → 10.2.0.x  (the VM itself)
                                                            │
                                                            ▼
                                                    service port, PLAIN HTTP
                                                    ── no TLS
                                                    ── no identity gate (Caddy not in path)
```

**Required behaviour**

| Step | Behaviour |
|---|---|
| `install-module.sh` / converge | **succeeds** |
| `network:proxy` | detects "no public name", **skips publishing cleanly** — no Caddy handler, no Unbound record, no ACME request |
| Operator message | exactly one, naming the consequence: *"`openwebui` is not published (no external DNS for `openwebui.example.org`) — reachable only at `openwebui.srv.internal`, without TLS and without the identity gate."* |
| `network-manager validate` | reports it as **unpublished** — a distinct state from *misconfigured* |
| Later, when DNS appears | the next converge publishes it — no manual repair, no stale half-state |

**Rules required**

*Zone rules* — this is the one case needing a **client → service zone** path, because there is
no Caddy hop to borrow reachability from: the client zone needs `access-to` the service zone (or
a pinhole). Note the D3 caddy-reach rule does nothing for an unpublished service — there is no
Caddy hop to borrow.

*Module rules*

| Field | Value | Why |
|---|---|---|
| `proxyDomain` | *unset* | the explicit, intended form of "not published" |
| `proxyDomain` | set, but not publicly resolvable | the **transitional** form — same degraded behaviour, but validate flags it as *pending DNS* |

> These must not be conflated. An unset `proxyDomain` is a decision; a set-but-unresolvable one
> is an unfinished job. Today both produce the same "register DNS manually" warning.

---

## Consequences

**Good**

- One address, one rule, one implementation — the #577 drift vector is gone, and there is
  nothing left for a fourth writer to infer differently.
- The wildcard record becomes usable on multi-client-zone sites (impossible under v0.1).
- Service-to-service and client traffic get the same answer — no special case.
- Unauthorized access fails as a readable **403**, not a silent drop.
- Authorization lands in one place and the right one: **Authentik group membership, per person**
  — not a zone list duplicated per module, and not an emergent property of which gateway DNS
  happened to return. One identity moving between `home`, `guest` Wi-Fi and the `netbird`
  overlay is one answer, not three.

- **Radically less to implement, and the only `zones.json` churn is a removal.** The resolver is
  a constant lookup, the per-module input to DNS disappears entirely, and the firewall side is
  one already-shipped rule plus a widened candidate set (D3a, D3b). Compare v0.1: a
  preference-ordered client-zone search, a multi-zone warning path, and an unanswered
  service-to-service case; and compare v0.3/v0.4, which additionally rewrote every
  internet-capable zone's `access-to`.
- **It closes a live control-plane exposure** (#618). Removing `dmz` from the Service seed takes
  tcp/8443 and tcp/22 on the firewall away from every service VM — reach that exists today, on
  this site, and that #399 alone would not have removed.

**Costs / risks**

- **No widening; the one zone diff is a narrowing.** v0.3/v0.4 carried a cost entry here for the
  `internet ⟹ dmz` grant. Withdrawing D3 removes it: reachability is a `/32` on two ports the
  firewall already emits. What remains is D3b's *removal* of `dmz` from Service zones — which
  should still be reviewed, because a service VM that today reaches a DMZ workload zone-wide
  will need a declared pinhole instead. Nothing is deployed in the DMZ on the reference site,
  so there is nothing to migrate there today.
- **`guest` and internet-capable IoT zones reach Caddy — and already do.** They are refused by
  the access-list rather than by the firewall, which moves the boundary for those zones from the
  network layer to Caddy. That is the model working as designed, the refusal is legible and
  per-service, and it is the **status quo since #366** — not something this ADR introduces.
- **A cutover, smaller than it was.** 3 of 8 records move on the reference site (`network`,
  `logging`, `unifi-os`, all on `10.0.0.1`); the 5 already on `10.6.0.1` are correct as-is.
  **D3a must land first**, or exactly those three become unreachable over the admin VPN. That is
  the whole ordering constraint — there are no zone grants left to sequence.
- The DMZ gateway becomes a single point of failure for *all* internal published-name traffic.
  It already is for external traffic; this extends the blast radius inward. Observed 2026-09-06:
  one malformed upstream in one handler stopped all 23 published names for ~2h while
  `caddy-manager reconfigure` reported success. **#589 closed that blind spot** (the manager now
  verifies the service is running after a write), which is why this stays a recorded cost rather
  than a blocker.

---

## Open questions

v0.5 closed two of v0.4's three and shrank the third. What remains:

1. **Cutover mechanics** — one-shot migration command with a dry-run, or converge-on-next-
   reconcile with a pre-flight report? Three records move, and the only ordering constraint is
   that **D3a lands first**; there are no zone grants left to sequence.
2. **Whether `edge` and `netbird` should ever get the caddy-reach rule.** D3a deliberately
   admits only Overlay zones with a non-empty `access-to` — today that is `admin` alone. `edge`
   is a least-privilege satellite tunnel (ADR-010) whose per-role rules are applied by
   `satellite-manager`, and `netbird` is not terminated on the reference firewall at all. Both
   are decisions to take when the overlay is live; neither blocks this ADR.

*Closed since v0.4.* **"Is `guest` reaching Caddy acceptable?"** — it has been reaching it since
#366; the rule is host- and port-scoped and the refusal is Caddy's, so there is no new
consequence to accept. **"Do overlays need handling outside the invariant?"** — yes, and it is
**D3a**, promoted from an open question to a prerequisite because `admin` demonstrably breaks
without it.

## Testing

- **Unit (fast)** — the resolver as a pure function: published name → `(dmz_ip, "dmz")`;
  unpublished → `UNPUBLISHED`; no dmz zone → `ERROR`. Plus the **D3 candidate set** as a pure
  function over `zones.json`: every zone with `internet`, and every `type: Overlay` zone with a
  non-empty `access-to`, is a caddy-reach candidate; an isolated zone and an empty-`access-to`
  zone are not; **and `dmz` now IS one** (D3b(i) — the case that flips from v0.5). And the
  negative that keeps the #577 review's objection closed: **no zone's `access-to` gains anything
  from any of this.**
- **Unit (fast) — the #618 invariant (required deliverable of D3b).** As a pure function over
  `zones.json`: **no zone lists `dmz` in `access-to`** — and specifically that the `service`
  archetype and the new-zone default no longer seed it, so a freshly added Service zone does not
  reintroduce the edge one install later. Paired with the candidate-set test above, this is what
  makes "the DMZ gateway is reachable on two ports and nothing else" a checked property rather
  than a claim.
- **Unit (fast) — the #594 cardinality invariant (required deliverable of D5).** The record
  reconciler as a pure function over the current `*` rows: two identical rows in ⟹ exactly one
  row planned out; one correct row in ⟹ no change; zero rows in ⟹ one row planned. It MUST plan
  a rewrite on `count ≠ 1` even when the value already matches — the case today's value-only gate
  misses. Applying the plan twice is a no-op.
- **Contract (fast)** — a guard that fails if a second split-horizon implementation reappears,
  in the spirit of `test-tracked-exec-mode.sh`.
- **`--deep`** — per case, register the record then assert reachability *from the zone in
  question*; and assert an unentitled zone (guest) is still denied. The existing zone-node test
  already proves an L2 probe can be placed on an arbitrary VLAN, which is the harness this needs.
  Plus one probe that is **not** a VLAN: from an `admin` WireGuard peer, assert `10.6.0.1:443`
  answers — the D3a regression this ADR would otherwise ship. And the negatives that keep #618
  closed, run from a **service-zone** VM: `10.6.0.1:443` answers, while **`10.6.0.1:8443` and
  `10.6.0.1:22` are refused**, and a DMZ *workload* address is refused. Those three are open
  today (probed 2026-09-10) and are the regression test for D3b(ii).

## Documentation impact (ADR-013)

Landed with the implementation:

| Document | What it gained |
|---|---|
| `src/foundation/network/README.md` | the split-horizon section: D2's one answer, D5's resolver and its exit codes, R3's degraded mode |
| `src/foundation/network/DESIGN.md` | why caddy-reach sits in band 1 (ahead of the rfc1918 block) and who the candidate zones are |
| `manager/network-manager/ZONES.md` | the caddy-reach rule, invariant **I5**, and why reach is deliberately not an `access-to` entry |
| `manager/environment-manager/README.md` | `dnsMode` is the **certificate** strategy only (D4), and R3's unpublished domain |
| `services/proxy/fields.json` → regenerated `README.md` | `proxyAllowedZones` under D2: the access list is the only zone-level narrowing, and it is not the mechanism that protects a service |
| `schemas/zones-fields.json`, `ZONES.md` | the `service` archetype's `access-to` seed loses `dmz` (D3b) |
| **`docs/ADR/ADR-005` §6** | a supersession note. This ADR *Refines* §6, but §6 still prescribed the client-zone rule in detail — including "replace `dmz_gateway_ip()` with a zone-aware lookup", the exact inverse of D5 — and ADR-005's own banner routes readers into it as "still useful" |

**Dropped: a `docs/design/` network overview.** Earlier drafts listed one. No such document
exists — `docs/design/` holds ADR-implementation records, not a standing network overview — and
writing one would give the same explanation a second home to drift from. The material lives in
`network/README.md` (what it does) and `network/DESIGN.md` (why the rule is ordered as it is),
which are the documents a reader of this code already opens.

---

## Appendix A — How the Unbound record is written (today, and under this ADR) — #594

D5 says the *target* must come from one resolver. This appendix documents the other half: the
Unbound override is also *written* by more than one code path, triggered by more than one
lifecycle event, in **no fixed order**. #594 — two identical `*` rows that reconcile reads as
converged and never flattens — is a direct consequence of that surface, not of any single
writer. D5 must own writing (and its cardinality), not only target derivation, or the same class
of defect returns.

### A.1 The writers

Three code paths write an Unbound override. Two of them write the shared `*` apex:

| # | Writer | File | Writes | Mode | Coordinates with |
|---|---|---|---|---|---|
| W1 | `acme-setup.sh` (issuance) | `tappaas-cicd/scripts/acme-setup.sh:292` | the `*` apex (`add "*" domain WC_GW`) | wildcard only | nothing — appends via `unbound-manager add` |
| W2 | `environment-manager` reconcile → `registerWildcard` | `environment-manager/src/clients.ts:248` | the `*` apex | wildcard only | itself, via `wildcardDnsState` — **value only, not row count (#594)** |
| W3 | `network:proxy` install/update-service | `network/services/proxy/update-service.sh:181-205` | a per-service `host.domain`, or prunes one | per-service writes; wildcard prunes | reads `*` to decide skip/prune |

W1 and W2 are **mutually exclusive within a single reconcile** — [reconcile.ts:119](../../src/foundation/tappaas-cicd/manager/environment-manager/src/reconcile.ts#L119) defers the DNS step to W1 while a cert is being issued, and only runs W2 when a cert already exists. They are **not** mutually exclusive across the *lifecycle*: a first pass issues (W1 writes) and a later pass reconciles (W2 may write). Neither reads the other's row *count*.

### A.2 Two independent mode axes

The combinations that make this hard are the product of two axes that vary independently:

| Axis | Values | Set by | Consequence for the `*` row |
|---|---|---|---|
| **Certificate strategy** | `wildcard` \| `per-service` | env `dnsMode`, overridable per module by `proxyTls` (`dns01`→wildcard, `http01`→per-service — [update-service.sh:159-164](../../src/foundation/network/services/proxy/update-service.sh#L159)) | wildcard ⇒ a `*` apex exists and W3 is a no-op/prune; per-service ⇒ no `*`, W3 writes per host |
| **Certificate automation** | automated \| manual | automated when `~/.acme-dns-credentials.txt` is present (env-manager runs `acme-setup.sh` itself — [clients.ts:310](../../src/foundation/tappaas-cicd/manager/environment-manager/src/clients.ts#L310)); manual when the operator runs `acme-setup.sh` by hand | decides *whether W1 fires from inside reconcile* or *out-of-band from a shell* — i.e. whether the two `*` writers are interleaved by one process or by two |

Because `proxyTls` overrides `dnsMode` per module, a single environment can carry **both**
strategies at once — some modules wildcard-bound, others per-service — so W3's skip/prune branch
and the `*` apex coexist on the same domain.

### A.3 Three triggers, non-deterministic order

The writers are not invoked by one driver. Three lifecycle events call them, and the operator
can run them in any order (and re-run any of them):

```
  platform install ─────────────┐
    operator runs acme-setup.sh  │  (manual automation path)         ┐
                                 ▼                                    │
  environment install/reconcile ─── environment-manager reconcile    │  each may write / re-write
    ├─ no cert  → plan issue → W1 (acme-setup.sh) writes `*`          │  the SAME `*` apex, at a
    └─ cert ok  → W2 (registerWildcard) writes `*` (if value drifts)  │  time not ordered relative
                                 ▲                                    │  to the others
  module install / module update ── install-module / update-module   │
    └─ network:proxy → W3 (per-service add / wildcard prune)          ┘
```

There is no barrier and no lock between these. `acme-setup.sh` is a **multi-minute** DNS-01
issuance; a module install or an environment reconcile can run before, during, or after it, on a
different day, by a different operator action.

### A.4 Today — how a duplicate `*` is seeded and then frozen (#594)

```
  ── seeded (before add_override was delete-all-rewrite-one) ──
  W1 acme-setup.sh   :  add "*" example.com 10.2.0.1     → row 1
  W2 registerWildcard:  add "*" example.com 10.2.0.1     → row 2   (append, uncoordinated)

  ── frozen (current reconcile logic) ──
  wildcardDnsState() reads both rows, keeps last value only:
        currentTarget = "10.2.0.1"        row COUNT discarded  (clients.ts:236)
  computePlan(): currentTarget === gatewayIp && no collisions
        → "already resolves … no DNS change"                   (reconcile.ts:134,148)
        → registerWildcard never runs → the delete-all-rewrite-one flatten never fires
  ⟹ two identical rows persist across every future reconcile, forever.
```

The OPNsense writer was fixed to delete-every-match-then-write-one, so W1/W2 *newly* run no
longer append — but that flatten only executes when a writer is actually invoked, and the
value-only gate above ensures it never is once the value is already correct. Existing duplicates
are stranded. `state=absent` removes one row per call, so they do not self-heal from the delete
side either.

### A.5 Under this ADR — one writer, cardinality-aware (D5)

D2 removes the *value* disagreement (every `*` is the DMZ gateway), and D5 collapses W1/W2 into
one `network-manager split-horizon-target` call. The remaining requirement this appendix adds:

> **D5 owns the record's cardinality, not only its value.** The single writer's state read MUST
> report how many `*` rows exist, and the plan MUST converge on **exactly one** whenever
> `count ≠ 1` — independently of whether the value already matches.

```
  ── future ──
  split-horizon-target(domain) → (10.6.0.1, "dmz")      one derivation, all callers
  state read                   → { value, rowCount }    count is first-class
  plan                         → rewrite when  rowCount ≠ 1  OR  value ≠ target  OR  collisions
        rewrite = delete-every-match + write-one         → converges to exactly one row
  next reconcile               → rowCount == 1, value ok → no change   (idempotent)
```

This makes the invariant *"exactly one `*` override per domain"* a property the reconciler
actively maintains, closing #594 for both stranded and future duplicates. It is testable as a
pure function — the "applying it twice is a no-op" check applies verbatim to the
record: two identical rows in ⟹ one row out ⟹ stable.

> **Implementation requirement — not deferred.** #594 is **closed by this ADR, not alongside
> it.** The D5 work MUST land the cardinality-aware read and plan (row count as first-class
> state; converge on exactly one `*` when `count ≠ 1`) in the same change that introduces the
> single resolver — because that rewrite touches the very `wildcardDnsState`/`computePlan` paths
> where the bug lives, and shipping D5 without the count check would silently re-open #594. The
> ADR is therefore not "done" until a reconcile against a domain carrying two identical `*` rows
> flattens them to one. There is deliberately **no** separate/interim fix: it rides in with D5.
