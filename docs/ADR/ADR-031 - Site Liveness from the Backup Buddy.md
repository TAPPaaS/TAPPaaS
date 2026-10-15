# ADR-031 — Site Liveness from the Backup Buddy

| | |
|---|---|
| **Status** | **Accepted** (operator, 2026-10-15) — P1, P2 and P3 built 2026-10-15. |
| **Version** | 0.2 |
| **Date** | 2026-10-15 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | **#776** (a site that has gone dark is reported by nobody). Builds on the buddy tunnel (#796, `backup/BUDDY.md`), log alerting and its watchdog (#126), and the site mail path (#651). |
| **Changelog** | v0.5 (2026-10-15) — **P3 built**: the satellite watches its home site (the infra tunnel's handshake), mailing directly (operator's choice: port 25, as the nodes). v0.4 (2026-10-15) — **P3, first half built**: a `debianhost` backup node gets the pulse, `jq` and postfix (D4). v0.3 (2026-10-15) — **P2 built**: the pulled side reports when its buddy last pulled, to both operators; the `pulse` health gate and the deep module test. v0.2 (2026-10-15) — **Accepted, P1 built**: the open questions answered (both operators mailed; the mothership after 30 minutes; the standalone watcher in P1), and the satellite becomes a P3 variant: installing a satellite installs a watcher. v0.1 — first draft, from the operator's idea: the backup buddy watches the site from outside; the local backup node is the local watcher. |

## Context

On 2026-10-03 makerfloss lost all three nodes, most likely to a power cut, and stayed down for two
and a half days. Nothing reported it, and nothing could have. Every TAPPaaS notice is sent from
inside the site: the sweep's failure mail and the security notice go through a node's postfix, the
log alerting runs on the logging VM, and its watchdog runs on the mothership. A dark site has no one
left to say it is dark.

What is needed is a watcher **outside** the site, that has its **own** way to send mail.

Two TAPPaaS facts make the backup buddy that watcher:

- **A buddy is another site, with its own power, uplink and mail.** It keeps our off-site copy
  (BUDDY.md), so the relationship already exists, is set up by both operators, and is meant to last.
- **The buddy already reaches us.** The pulling side dials a WireGuard tunnel to the pulled side and
  reaches its PBS on `.1:8007` (BUDDY.md, *One pull, one tunnel*). If that stops answering, the
  pulled site is gone — or at least its firewall, its uplink or its PBS host is.

The issue proposed the satellite as the watcher (the WireGuard handshake of the home peer). That
works only for sites with a satellite and needs a mail path on the satellite, which is still to be
decided. A buddy has a mail path already: its own site's.

### What can see what

Only the **pulling** side can reach the other PBS; the pulled side exposes its PBS to the puller
and reaches nothing in return. So in each relationship, one direction can be watched directly:

| Relationship (`backup-manager peers`) | We can probe them | They can probe us |
|---|---|---|
| `pull` — we pull their copy | **yes**: their PBS on `.1:8007` in our tunnel | no |
| `remote` — they pull ours | no | **yes**, if they run a watcher |
| both (mutual buddies) | yes | yes |

hrossen today has one buddy, `rasmus`, as `remote`: rasmus pulls hrossen. Only rasmus can see
hrossen go dark, and rasmus is not a TAPPaaS site. A watcher for a non-TAPPaaS buddy is therefore
part of the design, not an extra.

## Decision

### D1. Every site's backup node runs a pulse

The **backup node** — the Host the PBS runs on (`backup.json` `.node`; a Proxmox node, or a
`debianhost` machine) — runs a timer, `tappaas-pulse.timer`, every 5 minutes. The backup node, not
the mothership, because the backup node is bare metal and is the part of a site most likely to be
the last one standing: the mothership is a VM on it or next to it, and the pulse also watches the
mothership (D3).

The pulse is one script, `pulse.sh`, with its configuration in `/etc/tappaas/pulse.json` and its
state in `/var/lib/tappaas/pulse/`. The backup module's update writes both and installs the timer;
nothing on the backup node is edited by hand.

### D2. It pings the buddy

For every peer we **pull** from, the pulse opens a TLS connection to the peer's PBS at its tunnel
address and checks the certificate fingerprint recorded at `peer add` (`pulse.json` carries both).
An answer with the right fingerprint is *up*; anything else is a failure.

A buddy is **down** after 15 minutes of failures. Then:

- one mail **"buddy `<name>` unreachable since `<time>`"** — then once a day while it lasts;
- one mail **"buddy `<name>` back"** when it answers again.

The mail goes to **two** addresses:

- **our own operator** (`site.json` `email`): our off-site copy of them is no longer being pulled;
- **the buddy's operator** (new: the peer's `contact`, see D5): their site may be down, and this
  mail is the one the dark site cannot send itself.

**False alarms from our own uplink.** Before a buddy is declared down, the pulse checks that *we*
can reach the internet (D3). With our uplink down, a buddy that does not answer proves nothing: the
pulse reports our own uplink instead and says nothing about the buddy.

### D3. It pings itself

The pulse also checks its own site, so that the backup node is the **local** watcher too:

| Check | How | Down means |
|---|---|---|
| uplink | DNS lookup of a public name and a TCP connect to it | our internet is gone: buddy probes are skipped (D2), and a notice is queued for when mail works |
| firewall | the default gateway answers (ICMP) and resolves a name | the site's network is gone |
| mothership | the mothership answers SSH on its mgmt address | no sweeps, no alert watchdog, no log alerting |
| log alerting | the alert watchdog's heartbeat file on the mothership is younger than its limit (read over SSH) | already covered by the watchdog, unless the mothership is down too |
| own PBS | its API answers on `localhost:8007` | backups and the buddy's pull fail |

Each local check has the same down / repeat / back shape as D2, mailed to our own operator only.
The mothership is down after **30 minutes**, not 15: a mothership reboot during an update takes
minutes, and that is not an outage.

The mothership's alert watchdog stays as it is. The pulse adds the one thing it cannot do: report
the mothership itself.

### D4. Mail from the backup node

On a Proxmox node the pulse mails through the node's own postfix — the path `site-notify.sh`
already uses (it sends through a node). The pulse calls `sendmail` locally, so it does not depend
on the mothership.

A backup node that is a `debianhost` machine may have no mail transfer agent. The backup update
installs postfix there as the nodes have it — loopback only, delivering directly — together with
`jq`; such a machine then needs outbound SMTP, as the nodes do. (Relaying through a node's postfix
was considered and not chosen: the nodes accept mail from loopback only, and opening them to the
mgmt network for relaying is more exposure than a second MTA.)

A mail that does not go out is retried on the next run, as the alert watchdog does.

### D5. Contacts are part of the peer

`backup-manager peer add pull|remote` takes `--contact <email>`: the address of the other site's
operator, which the two operators already exchange (BUDDY.md, *What the two operators exchange*,
gains a row). `backup-manager peer modify <kind> <name> --contact <email>` sets it later.
`backup-manager peers` shows it.

A peer without a contact still gets watched; only our own operator is told.

### D6. The pulled side sees whether its copy is still being taken

On the side that is pulled (`remote`), the pulse cannot reach the buddy. It reads instead when the
buddy last pulled: the newest reader session of the buddy's auth-id in our PBS task log. Older than
two of the buddy's sync intervals (default 2 days) is a notice to our operator and the buddy's:
**"backup buddy `<name>` has not pulled our backups"**, with when it last did. A buddy that has
never pulled gets the same 2 days from when the pulse first saw it. This is slower than
D2 by design: it watches the copy, not the site.

### D7. A watcher for a buddy that is not TAPPaaS

For a buddy whose PBS is not TAPPaaS (BUDDY.md Setups 3 and 4), the same `pulse.sh` runs on their
PBS host as a standalone script: one file, a `pulse.json` they write from a printed template, a
systemd timer, and their own `sendmail`. BUDDY.md Setup 3 gains the steps. It does D2 for the
TAPPaaS site they pull, and nothing else.

### D8. Visible state

- `backup-manager pulse` on the mothership: each watched target, up / down since, last probe,
  last mail. It reads the pulse state from the backup node over SSH.
- `module test backup` fails when the timer is not running, warns when a target is down.
- A health gate `pulse` reports the same in `health-manager validate`.

## What this does not cover

- **Both sites dark at once** (a regional power cut): nobody is left to tell. A third watcher (an
  external heartbeat service, or the satellite) is the answer; not in this ADR.
- **A site with no buddy**: no outside watcher. Documented as the trade-off; the satellite watcher
  of #776 stays open as an option for such sites.
- **Proving TAPPaaS works** beyond the firewall and the PBS: a site whose PBS answers but whose
  applications are down is not dark, and the log alerting reports it.

## Alternatives considered

| | Alternative | Verdict |
|---|---|---|
| A1 | **Satellite watches the home WireGuard handshake** (#776 as filed) | Not rejected, deferred: needs a satellite and a mail path on it. Complementary for sites without a buddy. |
| A2 | **The mothership pings the buddy** | Rejected: the mothership is a VM; it is not what is left when a site partly fails, and it cannot report itself. |
| A3 | **External SaaS heartbeat** (healthchecks.io style) | Not in TAPPaaS by default (a third party sees the site's liveness); documented as an operator option. |
| A4 | **Watch the WireGuard handshake on the firewall** | Rejected as the main signal: it is on OPNsense, needs the firewall API from outside, and says only that the tunnel is up, not that the PBS behind it answers. |

## Implementation plan

| Phase | Content |
|---|---|
| **P1** — built 2026-10-15 | `backup/pulse/pulse.sh` with D2 (pull peers) and D3 (uplink, firewall, mothership, own PBS); `lib/pbs-pulse.sh` writes `pulse.json` from the PBS's remotes and the peers' contacts and installs the timer from every backup update, on a Proxmox-node backup node; mail via the node's postfix; `peer add … --contact` and `peer modify … --contact` (D5); `backup-manager pulse`. D7 moved here: the same script runs standalone, BUDDY.md Setup 3. |
| **P2** — built 2026-10-15 | D6: `pulledBy` in `pulse.json` from every `remote` peer's login and contact; the newest reader session in the PBS task list. D8: the `pulse` health gate and `module test backup --deep`. |
| **P3** — built 2026-10-15 | D4 for a `debianhost` backup node (postfix as on the nodes). **The satellite as a watcher**: a managed satellite's install and every update put a pulse on it that watches the home site through the infra tunnel — the newest WireGuard handshake on `wg-infra`, which the home firewall keeps fresh — and mails the Site's operator, delivering directly (the operator's decision: outbound port 25, unblocked at the VPS provider). It keeps running after a lockdown. A satellite that is also the Site's PBS host gets this watcher only, not the buddy checks. |

## Testing

- **Unit:** `pulse.sh` against stubbed probes and a stubbed `sendmail`: down after three failures,
  one mail, the daily repeat, the "back" mail, no buddy mail while our uplink is down, two
  recipients when a contact is set.
- **Live, hrossen:** a test `pull` peer pointing at a throwaway PBS (a container) through a real
  buddy tunnel. Stop the container: within 20 minutes one mail to each address; start it: "back".
  Stop the mothership VM's SSH (firewall rule) for the D3 mothership check. Teardown: peer deleted,
  container destroyed, tunnel and rules gone.
- **Real case:** hrossen ↔ rasmus once rasmus runs the standalone watcher (D7).

## Decisions on the open questions (operator, 2026-10-15)

1. **Both operators are mailed** when a buddy stops answering.
2. **Thresholds**: 5-minute probes, down after 15 minutes, a daily repeat; the mothership after 30.
3. **The standalone watcher is P1**: hrossen's buddy is not TAPPaaS, and only it can watch hrossen.
4. **The satellite is a P3 variant**: a satellite install brings its own watcher.
