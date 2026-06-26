# Firewall Hardening Backlog

Open security hardening items voor de TAPPaaS OPNsense firewall. Data-gedreven vanuit zones.json en observaties uit operationele sessies.

---

## #H1 — GUI toegang beperken tot mgmt + netbird zones

**Status:** ⚠️ Open  
**GitHub:** [TAPPaaS/TAPPaaS#384](https://github.com/TAPPaaS/TAPPaaS/issues/384)  
**Prioriteit:** Hoog | **Complexiteit:** Laag

### Probleem

OPNsense GUI (lighttpd op `:8443`) is bereikbaar vanuit elke zone waar OPNsense een interface op heeft. OPNsense's anti-lockout regel laat toegang toe tot de eigen interface-IP per zone, waardoor hosts in home (10.3.10.x), work (10.3.20.x), guest (10.5.10.x) etc. potentieel de GUI kunnen bereiken als ze het IP en de poort weten.

Zone-manager's block-private regels beschermen inter-zone verkeer maar niet verkeer gericht aan OPNsense's eigen interfaces.

### Fix

Voeg een expliciete block-regel toe vóór de anti-lockout regel die GUI-poort (8443) blokkeert vanuit alle niet-admin zones:

**OPNsense → Firewall → Rules → Floating (of per non-admin interface):**

| Veld | Waarde |
|---|---|
| Action | Block |
| Interface | alle niet-mgmt/niet-netbird interfaces |
| Protocol | TCP |
| Destination | `this firewall` |
| Destination port | 8443 |
| Description | Block GUI from non-admin zones |

Pass-regel voor mgmt en netbird zones (boven de block):

| Veld | Waarde |
|---|---|
| Action | Pass |
| Source | 10.0.0.0/24 (mgmt) + 100.64.0.0/10 (netbird) |
| Destination | `this firewall` |
| Destination port | 8443 |
| Description | Allow GUI from mgmt + netbird only |

### Context

- OPNsense GUI: `https://firewall.mgmt.internal:8443`
- mgmt zone: `10.0.0.0/24`
- netbird overlay: `100.64.0.0/10` (zone type: Overlay, state: Manual)
- Tegengesteld aan WAN: WAN heeft Block private + Block bogon aan; OPT1 (NetBird wt0) heeft ze uit

---

## #H2 — OPT1 (NetBird wt0) firewall regel buiten zone-manager pipeline

**Status:** ⚠️ Open  
**GitHub:** [TAPPaaS/TAPPaaS#385](https://github.com/TAPPaaS/TAPPaaS/issues/385)  
**Prioriteit:** Medium | **Complexiteit:** Medium

### Probleem

De firewall regel op OPT1 (`any → 10.0.0.0/24`, toegevoegd 2026-06-26 na ONT-wijziging) is handmatig aangemaakt en niet beheerd door zone-manager. De `netbird` zone heeft `state: Manual` en `access-to: []` by design — zone-manager maakt geen interface of firewall regels voor deze zone.

Na een zone-manager `--execute` of firewall herinstallatie kan deze regel verdwijnen of in een verkeerde volgorde terechtkomen.

### Achtergrond

Uit zones.json comment (issue #367):
> "state=Manual + vlantag=0 mean zone-manager never creates an interface, DHCP, or firewall rules for it"

De OPT1 regel is dus structureel buiten zone-manager. Dit is correct by design, maar de regel moet wel persistent zijn.

### Fix opties

**Optie A (aanbevolen):** Voeg de OPT1 regel toe aan `config-firewall.sh` of `update.sh` van de firewall module, zodat hij na elke firewall update opnieuw wordt gezet:

```bash
# In update.sh: zorg dat OPT1 regel bestaat
opnsense-controller firewall add-rule \
  --interface opt1 \
  --action pass \
  --source any \
  --destination 10.0.0.0/24 \
  --description "NetBird clients → mgmt zone only"
```

**Optie B:** Documenteer de regel in `firewall-config.xml.template` zodat hij bij installatie al aanwezig is.

### Huidige staat

Handmatig geconfigureerd in OPNsense GUI:
- Interface: OPT1 (wt0)
- Action: Pass
- Source: any
- Destination: 10.0.0.0/24
- Protocol: any
- Description: NetBird clients → mgmt zone only

OPT1 interface flags (Interfaces → OPT1):
- Block private networks: ☐ (uit — tegengesteld aan WAN)
- Block bogon networks: ☐ (uit — 100.70.x.x is RFC 6598, anders als bogon gezien)

---

## #H3 — Pinhole shadowing door block-private regels

**Status:** ⚠️ Open (gedocumenteerd)  
**GitHub:** [TAPPaaS/TAPPaaS#386](https://github.com/TAPPaaS/TAPPaaS/issues/386)  
**Prioriteit:** Hoog | **Complexiteit:** Hoog

### Probleem

Zone-manager emits `quick` block-private regels in band 2, vóór per-module auto-pinholes in band 3. Auto-pinholes die nieuwe connectivity geven (zone X → zone Y, waarbij Y niet in X's `access-to` staat maar wel in `pinhole-allowed-from`) worden nooit bereikt.

Volledig gedocumenteerd in `ISSUES/zone-manager-block-private-shadows-auto-pinholes.md`.

### Root cause

Regelband volgorde in OPNsense:

| Band | Range | Bron | Volgorde |
|---|---|---|---|
| 2 | 1000–9999 | zone-manager (block private, `quick`) | vroeg |
| 3 | 10000–19999 | rules-manager (auto-pinholes) | laat |

Auto-pinholes die `quick` block-private regels niet vooraf laten gaan, worden nooit geëvalueerd.

### Fix richting

Optie C (schoonst): zone-manager laat block-private regels weg voor bron-zones die in `pinhole-allowed-from` staan van de doel-zone. De auto-pinhole wordt de enige bron van waarheid voor dat pad.

Zie het volledige diagnose-document voor reproduciestappen.

---

## #H4 — Unbound DNS Python mismatch (mitigatie aanwezig)

**Status:** ⚠️ Mitigatie aanwezig, permanente fix open  
**GitHub:** [TAPPaaS/TAPPaaS#387](https://github.com/TAPPaaS/TAPPaaS/issues/387)  
**Prioriteit:** Medium | **Complexiteit:** Laag-Medium

Volledig gedocumenteerd in `src/foundation/firewall/ISSUES.md` (UNBOUND-DNSBL-PYTHON).

**Mitigatie:** `update.sh` runt zone-manager pas ná reboot.  
**Permanente fix:** patch `unbound.inc` om Python DNSBL module te verwijderen, of wacht op OPNsense upstream fix voor py311-dnspython.

---

## Overzicht

| # | Item | GitHub | Status | Prioriteit | Complexiteit |
|---|---|---|---|---|---|
| H1 | GUI toegang beperken tot mgmt+netbird | [#384](https://github.com/TAPPaaS/TAPPaaS/issues/384) | ⚠️ Open | Hoog | Laag |
| H2 | OPT1 regel in pipeline opnemen | [#385](https://github.com/TAPPaaS/TAPPaaS/issues/385) | ⚠️ Open | Medium | Medium |
| H3 | Pinhole shadowing (zone-manager) | [#386](https://github.com/TAPPaaS/TAPPaaS/issues/386) | ⚠️ Open | Hoog | Hoog |
| H4 | Unbound DNS Python mismatch | [#387](https://github.com/TAPPaaS/TAPPaaS/issues/387) | 🔶 Mitigatie | Medium | Laag-Medium |

### Fixes gedaan

| Datum | Fix | Effect |
|---|---|---|
| 2026-06-26 | NetBird route `10.0.0.0/8` → `10.0.0.0/24` | Alleen mgmt zone via tunnel, andere zones niet direct bereikbaar |
| 2026-06-26 | OPT1 firewall regel toegevoegd | NetBird tunnel kan mgmt zone bereiken na ONT-wijziging |

---

**Datum aangemaakt:** 2026-06-26  
**Bronnen:** zones.json, operationele sessies 2026-06-18/26, ISSUES/zone-manager-block-private-shadows-auto-pinholes.md, src/foundation/firewall/ISSUES.md
