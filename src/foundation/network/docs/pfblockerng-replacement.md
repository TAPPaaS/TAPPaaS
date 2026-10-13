# Replacing pfBlockerNG on a TAPPaaS firewall

pfBlockerNG is a pfSense package; OPNsense has no single equivalent. On TAPPaaS its four jobs
are covered as follows — one by TAPPaaS itself, three by OPNsense features you set up in its GUI.

| pfBlockerNG feature | On TAPPaaS | Managed by |
|---|---|---|
| **DNSBL** — refuse names on ad, tracker and threat lists | Unbound's blocklists, from `site.json` `dnsBlocklists` | TAPPaaS (network update) |
| **IP blocklists** (IPv4/IPv6 feeds) | a *URL Table* alias plus a block rule | OPNsense GUI |
| **GeoIP blocking** | a *GeoIP* alias plus a block rule | OPNsense GUI |
| **Alerts and reports** | Unbound's query reporting; the firewall log | OPNsense GUI |

## DNSBL → `dnsBlocklists`

Declare it in `config/site.json` and update the `network` module:

```jsonc
"dnsBlocklists": {
  "lists": ["atf", "hgz011", "oisd1"],
  "zones": ["home", "guest"],
  "allow": ["example.org"]
}
```

```bash
module-manager update network
```

| pfBlockerNG | `dnsBlocklists` |
|---|---|
| DNSBL feeds and groups | `lists` — OPNsense's catalogue codes (the network update names the valid ones if one is wrong). Threat feeds: `atf` (abuse.ch ThreatFox), `hgz011`–`hgz013` (hagezi threat intelligence). Ads and tracking: `oisd0`, `oisd1`, `ag`, `el`, `ep`, `sb`, and hagezi's `hgz001`–`hgz008` levels |
| DNSBL whitelist | `allow` |
| Per-interface DNSBL | `zones` — filtering applies to those zones' clients, IPv4 and IPv6; none listed: every client |
| DNSBL VIP / web server for blocked pages | none: a blocked name answers NXDOMAIN |
| Custom feed URLs | not in `dnsBlocklists`; add an entry by hand in *Services → Unbound DNS → Blocklist* (TAPPaaS leaves hand-made entries alone) |

Leave the service zones out of `zones`: their modules download updates, images and models, and
a false positive there makes an update fail.

To see why a name is blocked, on the firewall:

```sh
python3 /usr/local/opnsense/scripts/unbound-dnsbl/dnsbl_match.py --domain <name> --src <client-ip>
```

## IP blocklists → URL Table alias

1. *Firewall → Aliases → Add*: type **URL Table (IPs)**, the feed's URL, a refresh interval
   (e.g. daily). Spamhaus DROP (`https://www.spamhaus.org/drop/drop.txt`) is the usual start.
2. *Firewall → Rules → WAN*: a **block** rule, source the alias, placed first.
3. For outbound filtering, a block rule with the alias as destination on the zones you choose.

TAPPaaS does not reconcile these: a rule without a TAPPaaS description is left alone by the
network update, so it survives updates.

## GeoIP blocking → GeoIP alias

1. Create a free MaxMind account and licence key; set it under *Firewall → Aliases → GeoIP
   settings* (the URL includes the key).
2. Add an alias of type **GeoIP**, selecting the countries.
3. Block rule on WAN with the alias as source.

Prefer blocking inbound only: blocking destinations by country breaks content delivery networks.

## Alerts and reports

- *Reporting → Unbound DNS* shows queries, blocked names and top clients once *Enable
  statistics* is on under *Services → Unbound DNS → Advanced*.
- Blocked connections from an IP rule appear in *Firewall → Log Files → Live View*; give the
  rule logging.
- Intrusion detection (Suricata, *Services → Intrusion Detection*) and os-maltrail cover the
  behavioural alerts pfBlockerNG does not; both are optional plugins TAPPaaS does not configure.

## Known gaps

- No blocked-page web server: clients see a failed lookup, not a notice.
- TAPPaaS manages DNSBL only. IP and GeoIP blocklists are GUI configuration, kept by OPNsense's
  own backups rather than by `site.json`.
