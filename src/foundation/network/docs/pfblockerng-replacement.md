# Blocking on TAPPaaS, compared with pfBlockerNG and Pi-hole

What a TAPPaaS firewall blocks, how it compares with what people know from pfBlockerNG
(pfSense) and Pi-hole, and what OPNsense offers beside it. TAPPaaS curates no list of its
own: every list stays its publisher's, and TAPPaaS only decides which ones apply where.

## At a glance

| Job | pfBlockerNG | Pi-hole | TAPPaaS |
|---|---|---|---|
| Refuse names on ad, tracker and threat lists | DNSBL | its core job | Unbound's blocklists, from `site.json` `dnsBlocklists` |
| Different lists for different networks | per-interface DNSBL | groups per client | `dnsBlocklists.zones`: the zones whose clients are filtered |
| Names never blocked | DNSBL whitelist | allowlist | `dnsBlocklists.allow` |
| Lists kept current | its cron | gravity update | a daily cron job the network update keeps |
| Block known-bad networks, both ways | IPv4/IPv6 feeds | — | `site.json` `ipBlocklists`: a URL-table alias, blocked on the WAN and from every zone |
| Ban clients that abuse a published service | — | — | CrowdSec on the firewall, from Caddy's logs |
| Block whole countries | GeoIP | — | an OPNsense GeoIP alias, set by hand |
| A page that says a name is blocked | DNSBL VIP | blocking page | none: a blocked name answers NXDOMAIN |
| Reports | its dashboard | its dashboard | *Reporting → Unbound DNS*; the firewall log |

## DNS blocklists — `dnsBlocklists`

```jsonc
"dnsBlocklists": {
  "lists": ["hgz013", "oisd1"],    // OPNsense's catalogue codes
  "zones": ["home", "guest"],      // whose clients are filtered; none listed: every client
  "allow": ["example.org"]         // never blocked
}
```

`site-manager site modify --dnsBlocklistsLists hgz013,oisd1 --dnsBlocklistsZones home,guest`
writes it, and `module-manager update network` applies it. A new site starts with hagezi
Threat Intelligence Mini (`hgz013`) for its home and guest zones; ads and tracking lists are the
operator's choice.

- **Lists** come from OPNsense's catalogue. Threat feeds: `hgz011`–`hgz013` (hagezi: full, Medium,
  Mini). Unbound holds every name in memory: the full list (`hgz011`, about 1.5 million names)
  needs well over 2 GB free on the firewall, the Mini list (`hgz013`) a fraction of it. Ads and
  tracking: `oisd0`, `oisd1`, `ag`, `el`, `ep`, `sb`, and hagezi's `hgz001`–`hgz008` levels.
  OPNsense changes the catalogue between releases; a code it no longer offers is skipped with
  a warning, and the network update names the codes it does offer.
- **Zones.** Leave the service zones out: their modules download updates, images and models,
  and a false positive there fails an update rather than a web page.
- **Custom list URLs** are not in `dnsBlocklists`. Add an entry by hand in *Services → Unbound
  DNS → Blocklist*; TAPPaaS leaves hand-made entries alone, and its daily refresh covers them.
- **A block page.** OPNsense can answer a blocked name with an address of your choice instead
  of NXDOMAIN (*Destination Address*), for a web server that explains the block. TAPPaaS
  answers NXDOMAIN: a client sees a failed lookup.

Why is a name blocked? On the firewall:

```sh
python3 /usr/local/opnsense/scripts/unbound-dnsbl/dnsbl_match.py --domain <name> --src <client-ip>
```

## IP blocklists — `ipBlocklists`

```jsonc
"ipBlocklists": ["https://www.spamhaus.org/drop/drop.txt", "https://www.spamhaus.org/drop/dropv6.txt"]
```

Each URL becomes an OPNsense *URL Table (IPs)* alias that the firewall refreshes daily from
its publisher. Its addresses are blocked twice: arriving on the WAN, ahead of every published
service and port forward, and as a destination from every zone, ahead of the zones' own rules.
`site-manager site modify --ipBlocklists <url>,<url>` writes the field; empty (the default)
blocks nothing. Removing a URL removes its alias at the next network update; an empty list
removes the rules too.

## CrowdSec — bans for abusive clients

CrowdSec runs on the firewall and reads Caddy's access logs. A client that keeps failing to
sign in, probes for known exploits or announces itself as a scanner is banned at the firewall
for four hours, for every published name. It acts on what it sees, after the fact; IP
blocklists act before. It runs local only: nothing about the site's traffic leaves it, and no
community list comes in. See [network/README.md](../README.md#crowdsec--bans-at-the-firewall).

## GeoIP — by hand

1. Create a free MaxMind account and licence key; set it under *Firewall → Aliases → GeoIP
   settings*.
2. Add an alias of type **GeoIP** with the countries.
3. Add a block rule on WAN with the alias as source, without a TAPPaaS description, so the
   network update leaves it alone.

Block inbound only: blocking destinations by country breaks content delivery networks.

## What OPNsense offers beside it

None of these is configured by TAPPaaS. Each is a plugin or a GUI setting an operator can add.

| Feature | What it adds | Cost |
|---|---|---|
| Q-Feeds connector (`os-q-feeds-connector`) | threat-intelligence feeds as firewall aliases and as an Unbound filter | Community tier free (registration, delayed data); paid tiers for current data |
| Intrusion detection (Suricata, *Services → Intrusion Detection*) | rule-based inspection, inline since OPNsense 26.1; ET Open rules | free |
| os-maltrail | alerts on traffic to known-malicious hosts; reports, does not block | free |
| Zenarmor (`os-sensei`) | application and category filtering | free tier; categories and policies need a subscription |

## Known gaps

- No block page: clients see a failed lookup, not a notice.
- GeoIP blocking and custom DNS list URLs are GUI configuration, kept by OPNsense's own
  backups rather than by `site.json`.
