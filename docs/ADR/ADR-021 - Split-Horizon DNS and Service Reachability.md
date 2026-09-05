# ADR-021 — Split-Horizon DNS and Service Reachability

| | |
|---|---|
| **Status** | **Draft for review** — first stab, written to be argued with. The Decision section is a *proposal*; §Open questions lists what must be settled before it is Proposed. |
| **Version** | 0.1 |
| **Date** | 2026-09-05 |
| **Author** | Lars Rossen |
| **Parent** | [ADR-005 Variant/Domain Architecture](<ADR-005-variant-domain-architecture.md>) §6 (the split-horizon idea), [ADR-014 Zone and Environment Lifecycle](<ADR-014 - Zone and Environment Lifecycle.md>) (what a zone and an environment *are*) |
| **Refines** | ADR-005 §6 — which stated the goal but never named the resolution rule, leaving three implementations to infer it differently. |
| **Closes / addresses** | **#577** (wildcard split-horizon has two writers with different zone rules — three, in fact). Supersedes the interim reading of **#504** recorded in `acme-setup.sh` and `clients.ts`. Related: **#474** (a `redirect` zone permits local-data only at the apex), **#505** (wildcard supersedes per-service). |
| **Changelog** | v0.1 first stab: the reachability invariant (D1), one resolver (D2), the three worked cases, and the zone-rule / module-rule tables per case. |

## Context

A TAPPaaS service is published at **one URL** — `openwebui.example.org` — and must resolve
correctly whether the client is on the public internet, in a client zone, in the management
zone, or in the service zone next to it. That is *split-horizon DNS*: the same name, a
different answer inside than outside.

The mechanism has three moving parts:

| Part | Where it runs | Role |
|---|---|---|
| **Caddy** (`os-caddy`) | **on the OPNsense firewall** | terminates TLS for every published name and proxies to the service VM. It is reachable on **every** interface the firewall owns — i.e. at **each zone's gateway IP**. |
| **Unbound** | on the firewall, `10.0.0.1:53` | the internal resolver. Holds the *inside* answer as a host override. Dnsmasq cannot do this — it does not serve public domains and cannot express a wildcard. |
| **Zone policy** | `zones.json` | `access-to` and `pinhole-allowed-from` decide which client zone may reach which target address. |

**Caddy living on the firewall is the fact that makes this tractable, and the fact all three
current implementations lost sight of.** Because Caddy answers on every zone gateway, the
inside answer does not have to be "the address of the service" or "the address of the DMZ" —
it can be *the client's own gateway*, which is always reachable from that client, needs no
`access-to` grant, and is the same Caddy.

### The problem this ADR exists to fix

Three code paths write the internal answer, and they resolve it from different zones:

| Writer | Record it owns | Zone it resolves | Cites |
|---|---|---|---|
| `network/services/proxy/update-service.sh` → `proxy_split_horizon_gateway()` | per-service `host.domain` | the authorized **client** zone (`home`→`work`→`mgmt`, or `proxyAllowedZones`) | #504, ADR-005 §6 |
| `tappaas-cicd/scripts/acme-setup.sh` (wildcard mode) | the wildcard `*` | the environment's **service** zone, fallback **dmz** | #504, ADR-005 §6 |
| `manager/environment-manager/src/clients.ts` → `wildcardDnsState()` | the wildcard `*` | the environment's **service** zone, fallback **dmz** | #504, ADR-005 §6 |

All three cite the same authority and disagree. #577 read this as 1-vs-1; it is 2-vs-1, and the
majority is wrong on reachability. On the reference site:

```
home:   access-to=[internet]              pinhole-allowed-from=(none)
dmz:    access-to=[internet]              pinhole-allowed-from=[internet]
rossen: access-to=[internet,dmz]          pinhole-allowed-from=[dmz]   (type Service)
```

A `home` client pointed at the **service** zone gateway (`10.2.0.1`) is denied; pointed at the
**dmz** gateway (`10.6.0.1`) it is denied. Pointed at **its own** gateway (`10.3.10.1`) it
reaches Caddy. So #504's stated goal — *"not the DMZ, which home/work cannot reach"* — is **not**
achieved by the service-zone rule; that rule swapped one denied address for another.

The live record set shows the drift plainly (5 × dmz, 3 × mgmt, 1 × home gateway), of which only
the last matches the rule the proxy applies today.

### Why one rule is not enough by itself

Unbound's wildcard installs `local-zone: "<domain>" redirect`, which has **one apex target**.
One address cannot be simultaneously correct for two client zones. Any rule must therefore say
what happens when more than one client zone is authorized — today the proxy warns and picks the
first, which is honest but arbitrary. This ADR makes that limit explicit and scopes the fix for
it (D5).

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

This turns a convenience into an invariant: *split-horizon exists so that internal clients get
the same gated path as external ones, not so that they get a shortcut around it.* Any future
optimisation that answers with a service address must be rejected on this ground alone.

> Consequence for D2: every candidate in the resolution order is a firewall interface (a Caddy
> listener) by construction. That is not a coincidence — it is the requirement.

### R2. Both certificate models must work, and neither may change the address

A site runs one of two certificate strategies, and split-horizon must be identical under both:

| `dnsMode` | Certificate | Who issues | Record shape |
|---|---|---|---|
| `per-service` (default) | one cert per published host | Caddy, HTTP-01 | `host.domain A <target>` |
| `wildcard` | one `*.<domain>` cert | OPNsense ACME (`acme-setup.sh`), DNS-01 | `* .domain A <target>` + prune per-host |

The certificate model decides **record shape and who issues the cert**. It MUST NOT decide the
**address**. Today it does — flipping `dnsMode` moves clients from a client-zone gateway to a
service-zone gateway — and that coupling is half of #577. R2 makes the address a function of
zone authorization only (D2), and `dnsMode` a function of certificate strategy only (D3).

### R3. A service with no external DNS entry degrades — it must not fail

Not every service is published. A module may have no public DNS record at all — deliberately
(internal-only), or transitionally (the record is not created yet, or the site has no public
domain). ACME cannot issue for a name that does not resolve publicly, so there is no
certificate and nothing for Caddy to serve that name on.

**This is a supported configuration, not an error.** The required behaviour:

| | Published service | **Unpublished service (no external DNS)** |
|---|---|---|
| Reachable at | `service.example.org` | `<vmname>.<zone>.internal` **only** |
| TLS | yes (Caddy, per-service or wildcard cert) | **none** — plain HTTP to the service port |
| Identity gate | yes (Caddy `forward_auth` → Authentik) | **none** — Caddy is not in the path |
| Split-horizon record | client-zone gateway (D2) | **none** — nothing to resolve |
| Install / converge | succeeds | **succeeds**, with one clear warning |

So the degraded mode is explicitly *less* capable — no cert **and** no identity gating, because
R1's gate lives in the Caddy path this service does not have. The install must say so once,
plainly, rather than failing or (worse) silently leaving a half-configured proxy entry.

The internal name `<vmname>.<zone>.internal` is already served by Dnsmasq from the DHCP
reservation, so it needs no split-horizon record and no work from this ADR — the requirement is
simply that the publishing path **detects the absence and stops cleanly**, and that
`network-manager validate` reports the service as unpublished rather than broken.

> Today `proxy_split_horizon_gateway` failing produces
> `Could not derive a split-horizon gateway … — register DNS manually`, which conflates "this
> service is deliberately unpublished" with "I could not work out the address for a service that
> should be published". R3 requires these be different messages, only the second of which is a
> problem.

---

## Decision — the model

### D1. The reachability invariant (the rule everything else serves)

> **The internal answer for a published name MUST be an address the asking client is permitted
> to reach, and that address MUST be a Caddy listener.**

The second half is **R1** — Caddy carries the identity gate, so an answer that routes around it
is a security regression, not an optimisation. The first half is reachability. Both must hold.

Corollary, and the reason the client-zone rule is right: *the client's own zone gateway always
satisfies both halves.* It is self-traffic (no `access-to` grant needed) and it is Caddy.

An answer that is merely "the right service" but unreachable is a **failure**, not a degradation
— it presents as a hang or a TLS timeout with nothing in the service's own logs.

### D2. One resolver, one implementation

There is exactly **one** function that answers *"what address should `<name>` resolve to
inside?"*. All writers call it; none re-derives it.

```
split_horizon_target(domain, client_zone_set) -> (ip, zone, warning?)
```

Resolution order:

1. **The authorized client zone** — the first zone in the module's `proxyAllowedZones`
   (declared order is intent), else the default order `home` → `work` → `mgmt`, that is
   *Active* and has a subnet. → its gateway IP.
2. **The environment's service zone** — only when no client zone resolves. Correct for
   service-to-service traffic inside that zone, and honest about clients it cannot serve.
3. **The dmz gateway** — last resort, where Caddy also listens.
4. **Fail loudly — but only for a name that is meant to be published.** A service with no
   external DNS entry is **not** an error (R3): the resolver is never asked, the publish path
   skips cleanly. A name that *should* resolve and cannot is a real failure the caller reports,
   not a warning it walks past. These are different outcomes and must read differently.

It must be **one implementation**, not one rule transcribed into bash and TypeScript — that
transcription is what produced #577. Concretely: a `network-manager split-horizon-target`
subcommand (or equivalent) invoked by the proxy service, `acme-setup.sh`, and
`environment-manager`.

### D3. Per-service and wildcard are two renderings of the same answer

This is **R2** made concrete. `dnsMode` decides the *shape* of the record and *who issues the
certificate*, never the *address*:

| `dnsMode` | Record | Written by |
|---|---|---|
| `per-service` (default) | `host.domain A <target>`, one per published module | `network:proxy` |
| `wildcard` | `* .domain A <target>` + prune colliding per-host records (#505) | `acme-setup.sh` (at issuance) / `environment-manager` (on reconcile) |

Flipping `dnsMode` today silently changes the address as well as the shape. Under D2 it changes
only the shape.

### D4. Zone policy is the source of truth for "authorized"; DNS never widens it

The resolver *reads* `access-to` / `pinhole-allowed-from` and the module's `proxyAllowedZones`;
it never assumes a grant. If a client zone is not authorized for a service, the fix is a zone
rule or a module rule — **not** a DNS record pointing somewhere the firewall will drop.

Caddy's own access-list (from `proxyAllowedZones`) remains the enforcement point. DNS decides
*which Caddy listener you talk to*; the access-list decides *whether Caddy answers you*. Both
must agree, and they are derived from the same `proxyAllowedZones` list.

### D5. One wildcard cannot serve two client zones — say so, and scope the fix

When more than one client zone is authorized **and** `dnsMode: wildcard`, one apex target cannot
serve both. Until Unbound **access-control-view** (per-subnet answers) is implemented:

- the resolver returns the primary and emits **one** warning naming the zones that will not be
  served;
- `environment-manager validate` reports it as a **configuration warning**, so it is visible
  before it is a support call;
- `dnsMode: per-service` has no such limit (one record per host, each free to differ) and is
  therefore the recommended mode for a multi-client-zone site.

Implementing access-control-view is the follow-up this ADR deliberately does not take on.

---

## Use cases

Throughout: service module **`openwebui`**, published at **`openwebui.example.org`**, VM in a
**Service** zone, Caddy on the firewall, Unbound at `10.0.0.1`.

Reference addressing:

| Zone | Type | Subnet | Gateway (= a Caddy listener) |
|---|---|---|---|
| `mgmt` | Management | `10.0.0.0/24` | `10.0.0.1` |
| `home` | Client | `10.3.10.0/24` | `10.3.10.1` |
| `work` | Client | `10.3.20.0/24` | `10.3.20.1` |
| `srv` | Service | `10.2.0.0/24` | `10.2.0.1` |
| `srv2` | Service | `10.2.1.0/24` | `10.2.1.1` |
| `dmz` | DMZ | `10.6.0.0/24` | `10.6.0.1` |

---

### Case 1 — one environment, one client zone, `per-service`

The baseline install: environment `home-env` (domain `example.org`, `network.zone: srv`), one
client zone `home`, `openwebui` deployed into `srv`.

**Information flow — same URL, four origins**

```
                          openwebui.example.org
                                  │
  ┌───────────────────────────────┼────────────────────────────────┐
  │ external client               │ internal client (home)         │
  │  public DNS → WAN IP          │  Unbound → 10.3.10.1           │
  │        │                      │        │                       │
  │        ▼                      │        ▼                       │
  │  firewall WAN:443 ────────────┴──▶ CADDY (on the firewall)     │
  │  (rule: allow WAN→wanip:443)      terminates TLS for           │
  │                                    openwebui.example.org       │
  │                                            │                   │
  │                                            │ access-list check │
  │                                            │ (proxyAllowedZones)│
  │                                            ▼                   │
  │                                    upstream: openwebui.srv     │
  │                                    (10.2.0.x:8080)             │
  └────────────────────────────────────────────────────────────────┘
```

The **same Caddy** serves all origins; only the *listener* differs. That is the whole trick:
external traffic arrives on the WAN listener, `home` traffic on the `home` listener, `mgmt`
traffic on the `mgmt` listener — and Caddy's upstream and access-list are identical for all.

**Resolution per origin**

| Client is in | Unbound answer | Why | Reaches Caddy? |
|---|---|---|---|
| `home` (client) | `10.3.10.1` | its own gateway (D2 step 1) | ✅ self-traffic |
| `mgmt` | `10.3.10.1` | same record — mgmt is authorized *to* home | ✅ via `mgmt.access-to: home` |
| `srv` (the service zone itself) | `10.3.10.1` | same record | ⚠️ **only if** `srv.access-to` includes `home` — see Open Q3 |
| `dmz` | `10.3.10.1` | same record | ⚠️ same caveat |
| external | *not Unbound* — public DNS → WAN IP | outside never sees the override | ✅ WAN rule |

**Rules required**

*Zone rules (`zones.json`)*

| Zone | Setting | Value | Why |
|---|---|---|---|
| `home` | `access-to` | `[internet]` | no grant needed for its own gateway — self-traffic |
| `srv` | `type` | `Service` | environment binds to a service segment (ADR-014) |
| `srv` | `pinhole-allowed-from` | `[home, mgmt]` | lets Caddy's upstream hop reach the VM |
| `dmz` | — | unchanged | not on the path in this case |

*Module rules (`openwebui.json`)*

| Field | Value | Why |
|---|---|---|
| `zone0` | `srv` | the VM's zone |
| `proxyDomain` | `openwebui.example.org` | the published name |
| `proxyAllowedZones` | *unset* → default (`home`, `work`, `mgmt`, Active Service zones, **not** internet) | zero-trust default; resolver picks `home` first |
| `proxyAllowedZones` | `[home, internet]` | **to publish externally** — `internet` disables the access-list; the resolver still returns `10.3.10.1` for the inside answer |

> **Note the split**: `internet` in `proxyAllowedZones` changes only Caddy's *access-list*. The
> internal record stays the client-zone gateway. External clients never consult Unbound.

---

### Case 2 — the same service in a second environment

Add environment `work-env` (domain `work.example.org`, `network.zone: srv2`). `openwebui` is
deployed a second time as `openwebui-work-env` (ADR-007 P5 naming), VM in `srv2`, published at
`openwebui.work.example.org`.

Two independent names, two independent records, **one** resolver:

| Deployment | Published name | Env service zone | Authorized client zone | Inside answer |
|---|---|---|---|---|
| `openwebui` | `openwebui.example.org` | `srv` | `home` | `10.3.10.1` |
| `openwebui-work-env` | `openwebui.work.example.org` | `srv2` | `home` (default order) | `10.3.10.1` |

**Both resolve to the same gateway — and that is correct.** The client's zone gateway is a
Caddy listener; Caddy distinguishes the two deployments by **SNI / Host header**, not by
address. `openwebui.example.org` → upstream in `srv`; `openwebui.work.example.org` → upstream in
`srv2`.

This is the point at which the service-zone rule visibly breaks down: it would answer `10.2.0.1`
and `10.2.1.1`, two addresses a `home` client is authorized for neither.

**Rules required** (delta from Case 1)

*Zone rules*

| Zone | Setting | Value | Why |
|---|---|---|---|
| `srv2` | `type` | `Service` | second environment's segment |
| `srv2` | `pinhole-allowed-from` | `[home, mgmt]` | Caddy's upstream hop into `srv2` |

*Module rules* (`openwebui-work-env.json`)

| Field | Value | Why |
|---|---|---|
| `environment` | `work-env` | drives vmname + `zone0` from the env (`network.zone: srv2`) |
| `proxyDomain` | `openwebui.work.example.org` | distinct name — the SNI Caddy routes on |
| `proxyAllowedZones` | *unset* → default | same default; same client zone authorized |

> **Naming is the isolation, not addressing.** Two environments sharing one client zone is
> normal and needs no DNS distinction.

---

### Case 3 — two client zones, each authorized to a different environment

`home` may reach `home-env` only; `work` may reach `work-env` only.

| Deployment | Name | Authorized client zone | Inside answer |
|---|---|---|---|
| `openwebui` | `openwebui.example.org` | `home` | `10.3.10.1` |
| `openwebui-work-env` | `openwebui.work.example.org` | `work` | `10.3.20.1` |

Each name resolves to **the gateway of the client zone that is allowed to use it** — the two
answers differ because the two authorizations differ, which is exactly the intent.

**Failure mode this makes explicit:** a `work` client that asks for `openwebui.example.org`
gets `10.3.10.1`, an address `work` is not authorized to reach → the connection is dropped by
the firewall. That is the **correct** outcome (deny), but it presents as a timeout. D5's
warning and Caddy's access-list (which would return **403** if the packet did arrive) are the
diagnosable surface; see Open Q2 on making the deny legible.

**Rules required**

*Zone rules*

| Zone | Setting | Value | Why |
|---|---|---|---|
| `home` | `access-to` | `[internet]` | self-traffic to `10.3.10.1` needs no grant |
| `work` | `access-to` | `[internet]` | same |
| `srv` | `pinhole-allowed-from` | `[home, mgmt]` | **only** `home` — the authorization boundary |
| `srv2` | `pinhole-allowed-from` | `[work, mgmt]` | **only** `work` |

*Module rules*

| Module | Field | Value | Why |
|---|---|---|---|
| `openwebui` | `proxyAllowedZones` | `[home, mgmt]` | resolver picks `home` (first, declared order = intent); Caddy 403s `work` |
| `openwebui-work-env` | `proxyAllowedZones` | `[work, mgmt]` | resolver picks `work`; Caddy 403s `home` |

> **`proxyAllowedZones` is doing double duty here, deliberately**: it is both the DNS resolution
> input and the Caddy access-list. One declaration, so the two cannot drift apart (D4).

**With `dnsMode: wildcard` this case cannot be fully served.** One `*.example.org` apex target
must choose `home` *or* `work`. Per D5 the resolver picks the primary and warns. **Recommendation:
a site with two mutually-exclusive client zones uses `per-service`.**

---

### Case 4 — a service with no external DNS entry (R3)

`openwebui` is deployed into `srv` but the site has **no public record** for
`openwebui.example.org` — internal-only by choice, or the domain is not delegated yet.

**Nothing to split.** There is no public answer to differ from, so there is no split-horizon
record, no ACME certificate, and no Caddy handler. The service is reachable only at the name
Dnsmasq already serves from its DHCP reservation:

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

The degradation is real and must be stated to the operator: **losing the Caddy path loses the
identity gate with it (R1)**. An unpublished service is reachable by anything the firewall lets
onto its zone, with no authentication in front of it.

**Required behaviour**

| Step | Behaviour |
|---|---|
| `install-module.sh` / converge | **succeeds** |
| `network:proxy` | detects "no public name" and **skips publishing cleanly** — no Caddy handler, no Unbound record, no ACME request |
| Operator message | exactly one, naming the consequence: *"`openwebui` is not published (no external DNS for `openwebui.example.org`) — reachable only at `openwebui.srv.internal`, without TLS and without the identity gate."* |
| `network-manager validate` | reports it as **unpublished**, a distinct state from *misconfigured* |
| Later, when DNS appears | the next converge publishes it — no manual repair, no stale half-state to clean up |

**Rules required**

*Zone rules* — unchanged from Case 1: the client zone needs `access-to` the **service** zone
(or a pinhole) to reach the VM directly, because there is no Caddy hop to borrow reachability
from. This is the one case where a client zone genuinely needs a grant into a service zone.

*Module rules*

| Field | Value | Why |
|---|---|---|
| `proxyDomain` | *unset* | the explicit, intended form of "not published" |
| `proxyDomain` | set, but the name does not resolve publicly | the **transitional** form — same degraded behaviour, but validate should flag it as *pending DNS*, since the operator's intent was to publish |

> These two must not be conflated. An unset `proxyDomain` is a decision; a set-but-unresolvable
> one is an unfinished job. Today both produce the same "register DNS manually" warning.

---

## Consequences

**Good**

- One rule, one implementation, three callers — the #577 drift vector is removed.
- The answer is always reachable by construction (D1), instead of reachable by coincidence.
- `dnsMode` becomes a pure record-shape choice; flipping it no longer re-points clients.
- Case 3 shows the model expresses per-zone authorization without per-zone DNS.

**Costs / risks**

- **Existing records move.** On the reference site 8 of 9 records change target. That is a real
  cutover: it must be a single reconcile that rewrites all of them, not a drip.
- The wildcard limit (D5) becomes an explicit, warned-about restriction rather than an
  unnoticed one — some sites will have to move to `per-service`.
- A shared resolver invoked from bash is another process hop per published module.

---

## Open questions (must be settled before this leaves Draft)

1. **Is the client-zone rule right for *service-to-service* traffic?** A VM in `srv` calling
   `openwebui.example.org` gets the `home` gateway. Should service-origin lookups instead get
   the service-zone gateway — and if so, can Unbound distinguish the caller without
   access-control-view? (This is the strongest argument the service-zone rule had, and it
   deserves a real answer rather than being dismissed.)
2. **Should an unauthorized client get a deny it can read?** Today it is a timeout. Options:
   let the packet reach Caddy and 403 (legible, but admits the packet), or keep the drop and
   surface it in `network-manager validate`.
3. **Case 1 row 3/4 caveat:** should a Service or DMZ zone be granted `access-to` its
   environment's authorized client zone purely so the shared record resolves for it? That feels
   backwards; the alternative is accepting that intra-service lookups follow Q1's answer.
4. **Cutover mechanics** — one-shot migration command, or converge-on-next-reconcile with a
   pre-flight report? Given 8/9 records move, I lean to an explicit command with a dry-run.
5. **Does `mgmt` belong in the default order at all?** It is a Management zone, not a client
   zone; ADR-014 is explicit that an environment binds a Service zone and a client zone
   *consumes* one. Keeping `mgmt` third is pragmatic (the mothership is there) but muddies the
   type model.

## Testing

- **Unit (fast)** — the resolver as a pure function: table-driven over (zones.json,
  proxyAllowedZones) → expected (ip, zone, warning). Must cover: no client zone resolvable;
  multiple authorized; Inactive zone skipped; `internet`/`netbird` skipped.
- **Contract (fast)** — every writer calls the shared resolver: a grep-style guard, in the
  spirit of `test-tracked-exec-mode.sh`, that fails if a second implementation reappears.
- **`--deep`** — for each case: register the record, then assert reachability *from the zone in
  question* (the existing zone-node test already proves an L2 probe from a node can be placed
  on an arbitrary VLAN, which is the harness this needs).

## Documentation impact (ADR-013)

`docs/design/` network overview (split-horizon section), `src/foundation/network/README.md`
(`network:proxy` behaviour), `manager/environment-manager/README.md` (`dnsMode` semantics —
shape only, not address), and the `proxyAllowedZones` field docs (its double duty per D4).
