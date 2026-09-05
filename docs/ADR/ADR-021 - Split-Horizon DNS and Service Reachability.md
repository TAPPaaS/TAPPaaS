# ADR-021 — Split-Horizon DNS and Service Reachability

| | |
|---|---|
| **Status** | **Draft for review** — the Decision is a proposal; §Open questions lists what remains. |
| **Version** | 0.3 |
| **Date** | 2026-09-05 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-005 Variant/Domain Architecture](<ADR-005-variant-domain-architecture.md>) §6 (the split-horizon idea), [ADR-014 Zone and Environment Lifecycle](<ADR-014 - Zone and Environment Lifecycle.md>) (what a zone and an environment *are*) |
| **Refines** | ADR-005 §6 — which stated the goal but never named the resolution rule, leaving three implementations to infer it differently. |
| **Closes / addresses** | **#577** (wildcard split-horizon has two writers with different zone rules — three, in fact). Supersedes the interim reading of **#504** recorded in `acme-setup.sh` and `clients.ts`. Related: **#474** (a `redirect` zone permits local-data only at the apex), **#505** (wildcard supersedes per-service). |
| **Changelog** | v0.1 first stab: reachability invariant, one resolver, three cases. v0.2 (operator decision): the target is **the DMZ gateway, always** (D2), backed by a **zone invariant** (D3) — this replaces v0.1's client-zone-gateway rule, dissolves the one-apex-target problem, and answers three of v0.1's five open questions. Also: a wildcard **certificate** does not imply a wildcard **record** (D4), and R3's unpublished-service case is worked through as Case 4. v0.3 (operator simplification): D3's entitlement-set derivation is replaced by the invariant **`internet` implies `dmz`** — reaching published services is the same privilege as reaching the internet, which grants nothing new because an internet-capable zone can already reach the same Caddy via the WAN hairpin. Removes the `proxyAllowedZones`-derived entitlement set entirely and makes the rule authored (like the existing `mgmt.access-to` invariant) rather than validated. |

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
| **Zone policy** | `zones.json` | `access-to` and `pinhole-allowed-from` decide which zone may reach which target address. |

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
record set shows the drift plainly — 5 records on the dmz gateway, 3 on mgmt, 1 on a client-zone
gateway — with no rule that explains all three.

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
| per-service (default) | Caddy, HTTP-01 | one name per published host |
| wildcard | OPNsense ACME (`acme-setup.sh`), DNS-01 | `*.<domain>` |

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
| TLS | yes | **none** — plain HTTP to the service port |
| Identity gate | yes (Caddy `forward_auth` → Authentik) | **none** — Caddy is not in the path |
| Split-horizon record | the DMZ gateway (D2) | **none** |
| Install / converge | succeeds | **succeeds**, with one clear warning |

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

### D1. The reachability invariant

> **The internal answer for a published name MUST be an address the asking client is permitted
> to reach, and that address MUST be a Caddy listener.**

The second half is **R1** — Caddy carries the identity gate, so an answer that routes around it
is a security regression, not an optimisation. The first half is reachability. Both must hold.

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
- An unauthorized client gets a **403 from Caddy** — legible — instead of a silent timeout into
  a denied address.

### D3. The zone invariant — `internet` implies `dmz`

> **A zone with `internet` in its `access-to` MUST also have `dmz`.**
> A zone without `internet` gets neither, and therefore cannot reach a published service — which
> is the correct outcome for a deliberately isolated segment.

That is the whole rule. There is no entitlement list, no per-module derivation, and nothing to
compute: reaching published services is simply the same privilege as reaching the internet.

**Why this grants nothing new — the argument that makes it safe.** A zone with internet access
can *already* reach Caddy: it resolves the public name to the WAN IP and arrives via the
firewall's hairpin. `acme-setup.sh` records exactly this behaviour — internal clients resolving
the public WAN IP reach Caddy and "trip Caddy's zone ACL (HTTP 403)". They get there; they are
merely refused. So the `dmz` grant adds **no new destination**. It changes which *source zone*
Caddy sees, which is the entire purpose of split-horizon.

Conversely a zone with no internet access — `iotLocal`, `iotCams` today — gets no `dmz`,
resolves `10.6.0.1` like everyone else, and simply cannot connect. Isolation is preserved
without a single extra rule, because the isolation was already expressed by withholding
`internet`.

**Authored, not asked for.** `network-manager` maintains this on zone add/modify, exactly as it
already maintains the `mgmt.access-to` invariant (`zones.ts`). An operator never has to remember
it, and `validate` reports a zone that has drifted out of it.

> This is what makes D2 implementable rather than merely correct. #504 objected that *"home
> cannot reach the DMZ"*; the answer is that a zone which may reach the internet may reach the
> DMZ **by definition**, because it can already reach the same Caddy the long way round.

### D4. A wildcard certificate does not imply a wildcard record

`dnsMode` selects the **certificate strategy** (R2). It does **not** dictate the Unbound record
shape. The two are independent, and under D2 the record shape no longer affects correctness at
all — every record carries the same address, so `*` and per-host entries resolve identically.

| Certificate | Record shape | Verdict |
|---|---|---|
| wildcard (`*.example.org`) | wildcard `*` | valid — fewest records |
| **wildcard** | **per-service** | **valid, and often preferable** — explicit records, no `redirect`-zone apex constraints (#474), no collision pruning (#505) |
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

Every internal client gets the **same** answer; what differs is what happens next.

| Client is in | Unbound answer | Reaches Caddy? | Then |
|---|---|---|---|
| `home` (client) | `10.6.0.1` | ✅ has `internet` ⟹ has `dmz` (D3) | access-list **allows** → `srv` |
| `mgmt` | `10.6.0.1` | ✅ | allows → `srv` |
| `srv` (the service zone) | `10.6.0.1` | ✅ | allows → `srv` |
| `dmz` | `10.6.0.1` | ✅ own gateway | allows → `srv` |
| `guest` (has `internet`) | `10.6.0.1` | ✅ — it reaches Caddy | **403** — not in `proxyAllowedZones` |
| `iotLocal` (no `internet`) | `10.6.0.1` | ❌ no `dmz` — dropped at the firewall | — |
| external | *not Unbound* — public DNS → WAN IP | ✅ WAN rule | access-list decides |

> The last three rows are the model working as intended. `guest` is refused **by Caddy**, where
> the per-service policy lives and where the refusal is legible. `iotLocal` is refused **by the
> firewall**, because a zone denied the internet is denied published services too — one rule,
> two enforcement points, no special cases.

**Rules required**

*Zone rules (`zones.json`)*

| Zone | Setting | Value | Why |
|---|---|---|---|
| `home` | `access-to` | `[internet, dmz]` | `dmz` **authored by D3** from `internet` — not an operator decision |
| `srv` | `type` | `Service` | environment binds a service segment (ADR-014) |
| `srv` | `access-to` | `[internet, dmz]` | same invariant |
| `srv` | `pinhole-allowed-from` | `[dmz]` | Caddy's upstream hop into the VM |
| `guest` | `access-to` | `[internet, dmz]` | also authored — and refused at Caddy, not at the firewall |
| `iotLocal`, `iotCams` | `access-to` | `[]` — unchanged | no `internet`, so no `dmz`: isolated as intended |

> **Nothing in this table is a new decision for the operator.** The `dmz` entries follow from
> `internet` by D3 and are written by `network-manager`. The only authored policy is
> `pinhole-allowed-from` on the service zone, and the module's `proxyAllowedZones`.

*Module rules (`openwebui.json`)*

| Field | Value | Why |
|---|---|---|
| `zone0` | `srv` | the VM's zone |
| `proxyDomain` | `openwebui.example.org` | the published name |
| `proxyAllowedZones` | *unset* → default (`home`, `work`, `mgmt`, Active Service zones, `netbird`) | zero-trust default; also the set D3 validates for the `dmz` grant |
| `proxyAllowedZones` | `[home, internet]` | **to publish externally** — `internet` disables the access-list; the internal answer is unchanged |

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
| `srv2` | `access-to` | `[internet, dmz]` | D3 |
| `srv2` | `pinhole-allowed-from` | `[dmz]` | Caddy's upstream hop into `srv2` |

*Module rules* (`openwebui-work-env.json`)

| Field | Value | Why |
|---|---|---|
| `environment` | `work-env` | drives vmname + `zone0` from the env (`network.zone: srv2`) |
| `proxyDomain` | `openwebui.work.example.org` | distinct name — the SNI Caddy routes on |

---

### Case 3 — two client zones, each authorized to a different environment

`home` may use `home-env` only; `work` may use `work-env` only.

Under D2 **both names resolve to `10.6.0.1` for both zones** — DNS carries no authorization.
The isolation is enforced where it can be expressed per-service:

| Layer | `home` → `openwebui.example.org` | `work` → `openwebui.example.org` |
|---|---|---|
| Unbound | `10.6.0.1` | `10.6.0.1` |
| Firewall (D3 grant) | allowed to `dmz` | allowed to `dmz` |
| **Caddy access-list** | **allow** (`home` ∈ proxyAllowedZones) | **403 deny** |
| Caddy upstream | `srv` | — |

The `work` client gets a **clean 403 it can read**, not a timeout into a dropped packet. That is
strictly better diagnostics than v0.1's per-zone-address scheme, which failed silently at the
firewall — and it is why v0.1's Open Q2 ("should an unauthorized client get a deny it can
read?") no longer needs answering.

**And the wildcard works here.** One `*.example.org → 10.6.0.1` is correct for both client
zones simultaneously, because the address does not encode who may use it. This case was
*impossible* to express with a wildcard under v0.1.

**Rules required**

*Zone rules*

| Zone | Setting | Value | Why |
|---|---|---|---|
| `home` | `access-to` | `[internet, dmz]` | authored by D3 — **identical for both zones** |
| `work` | `access-to` | `[internet, dmz]` | same |
| `srv` | `pinhole-allowed-from` | `[dmz]` | only Caddy reaches the VM — not clients directly |
| `srv2` | `pinhole-allowed-from` | `[dmz]` | same |

> **The zone rules are the same for both client zones — they carry none of the isolation.** All
> of it lives in the two `proxyAllowedZones` lists below. That is the separation D2 buys: the
> network layer says "you may talk to the proxy", the proxy says "you may use this service".

*Module rules* — this is where the isolation lives

| Module | Field | Value | Why |
|---|---|---|---|
| `openwebui` | `proxyAllowedZones` | `[home, mgmt]` | Caddy 403s `work` |
| `openwebui-work-env` | `proxyAllowedZones` | `[work, mgmt]` | Caddy 403s `home` |

> Note what moved: in v0.1 `proxyAllowedZones` did double duty (DNS address *and* access-list).
> Under D2 it does **one** job — the access-list — and D3's `dmz` grant is the only zone-level
> input. One declaration, one meaning.

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
a pinhole). Note this also means the D3 `dmz` grant does nothing for an unpublished service.

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
- Authorization becomes auditable: an `access-to: dmz` grant you can see in `zones.json`, plus a
  per-service `proxyAllowedZones`, instead of an emergent property of DNS.

- **Radically less to implement.** The resolver is a constant lookup, the zone rule is a
  one-line invariant maintained where an equivalent one already is, and the per-module input to
  DNS disappears entirely. Compare v0.1: a preference-ordered client-zone search, a multi-zone
  warning path, and an unanswered service-to-service case.

**Costs / risks**

- **A widening on paper, none in practice.** Internet-capable zones gain `dmz` in `access-to`.
  They could already reach that same Caddy via the WAN hairpin (and be refused by its ACL), so
  no new destination is opened — but the `zones.json` diff *looks* like a widening and should be
  reviewed as one.
- **`guest` and internet-capable IoT zones now reach Caddy.** They are refused by the
  access-list rather than by the firewall. That is the model working as designed — the refusal
  is legible and per-service — but it does move the boundary from the network layer to Caddy for
  those zones. **If that is not acceptable for `guest`, the invariant needs an explicit
  exclusion**, and it stops being a one-line rule (see Open Q2).
- **A cutover.** On the reference site 4 of 9 records move (the 5 already on `10.6.0.1` are
  correct as-is). The zone grants are now *authored*, so they are not operator work — but they
  must land before the records move.
- The DMZ gateway becomes a single point of failure for *all* internal published-name traffic.
  It already is for external traffic; this extends the blast radius inward.

---

## Open questions

D2/D3 resolved four of v0.1's five (service-to-service, deny-legibility, the client-zone/
Management-zone type muddle, and — via `internet ⟹ dmz` — the entitlement-set derivation).
Remaining:

1. **Cutover mechanics** — one-shot migration command with a dry-run, or converge-on-next-
   reconcile with a pre-flight report? 4 records move; the authored `dmz` grants must land
   first, or clients break in between.
2. **Is `guest` reaching Caddy acceptable?** Under D3 it does (it has `internet`), and is
   refused by the access-list rather than the firewall. This is the one place the simple rule
   has a consequence worth confirming deliberately: a captive/guest segment now gets a TCP
   connection to the reverse proxy it did not have. If not acceptable, D3 needs an exclusion
   for `type: Guest` — at the cost of no longer being a one-line invariant.
3. **`netbird` (overlay)** — it is in the default `proxyAllowedZones` but has **no `access-to`
   at all** today, so `internet ⟹ dmz` gives it nothing. Do WireGuard peers reach `10.6.0.1`
   by a path that makes the grant unnecessary, or do overlays need handling outside the
   invariant?

## Testing

- **Unit (fast)** — the resolver as a pure function: published name → `(dmz_ip, "dmz")`;
  unpublished → `UNPUBLISHED`; no dmz zone → `ERROR`. Plus the D3 invariant as a pure function
  over `zones.json`: every zone with `internet` has `dmz`; a zone without `internet` has
  neither; applying it twice is a no-op (it is authored on every add/modify).
- **Contract (fast)** — a guard that fails if a second split-horizon implementation reappears,
  in the spirit of `test-tracked-exec-mode.sh`.
- **`--deep`** — per case, register the record then assert reachability *from the zone in
  question*; and assert an unentitled zone (guest) is still denied. The existing zone-node test
  already proves an L2 probe can be placed on an arbitrary VLAN, which is the harness this needs.

## Documentation impact (ADR-013)

`docs/design/` network overview (split-horizon section), `src/foundation/network/README.md`
(`network:proxy` behaviour), `manager/environment-manager/README.md` (`dnsMode` = certificate
strategy only, per D4), the `proxyAllowedZones` field docs (single meaning under D2), and
`ZONES.md` (the D3 invariant).
