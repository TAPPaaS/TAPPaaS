# Issue: test-debian-srv-lan2 toont geen IP in PVE (geen guest-agent)

## Symptoom
`test-debian-srv-lan2.json` heeft `"dependsOn": ["cluster:vm", "templates:debian"]` — identiek aan het werkende `test-debian.json`. De VM krijgt wél een IP (pfSense dient DHCP op `lan2`), maar:
- Proxmox toont geen IP in de GUI-kolom.
- `update-os.sh` kan het IP niet vinden en hangt in `wait_for_vm_ip`.
- Gevolg: `qemu-guest-agent` wordt nooit geïnstalleerd.

## Installatie-keten (referentie)
```
install-module.sh
 └─ Stap 4 → templates/services/debian/install-service.sh
     └─ update-service.sh
         └─ /home/tappaas/bin/update-os.sh <vmname> <vmid> <node>
             ├─ wait_for_vm_ip()          ← faalt hier
             │    1. get_vm_ip_guest_agent() — werkt niet op verse VM (agent ontbreekt)
             │    2. get_vm_ip_dhcp()        — grept /var/db/dnsmasq.leases op
             │                                  firewall.mgmt.internal (verkeerde DHCP-server)
             ├─ wait_for_ssh()
             ├─ wait_for_cloud_init()
             └─ update_debian() → `apt-get install -y qemu-guest-agent`
```
Bron: [update-os.sh:64-110](../scripts/update-os.sh#L64-L110), [update-os.sh:220-226](../scripts/update-os.sh#L220-L226)

## Root cause
Beide IP-detectie-methoden werken hier niet:

1. **`get_vm_ip_guest_agent`** — PVE's `qm guest cmd ... network-get-interfaces` heeft een draaiende `qemu-guest-agent` nodig. Op een verse Debian cloud-image zit die er nog niet in → leeg.
2. **`get_vm_ip_dhcp`** — grept hardcoded `/var/db/dnsmasq.leases` op `firewall.mgmt.internal`. Maar `lan2` wordt door **pfSense** bediend (andere DHCP-server, ander bestand, andere host). De lease van de `srv/lan2`-VM staat dus nooit in die file.

Hierdoor is er een **kip-en-ei**: voor installatie van de guest-agent is SSH nodig, voor SSH is IP nodig, voor IP is de guest-agent of een bereikbare DHCP-server nodig. Voor zones die niet door de mgmt-firewall worden bediend breekt de keten hier.

## Verschil met werkende `test-debian.json`
| Veld | test-debian.json (werkt) | test-debian-srv-lan2.json (faalt) |
|---|---|---|
| `node` | tappaas1 | tappaas2 |
| `bridge0` | `lan` | `lan2` |
| `zone0` | `mgmt` (vlantag 0) | `srv` (vlantag 210) |
| DHCP-server | mgmt-firewall (dnsmasq) | pfSense op lan2 |

De mgmt-zone werkt toevallig omdat `get_vm_ip_dhcp` precies die ene DHCP-server bevraagt.

## Mogelijke fixes

### A — `update-os.sh`: extra DHCP-source voor pfSense
Uitbreiden van [`get_vm_ip_dhcp`](../scripts/update-os.sh#L64-L80) zodat hij, afhankelijk van de zone van de VM, ook de juiste DHCP-server bevraagt. Voor pfSense bv. via `/var/dhcpd/var/db/dhcpd.leases` (of via de pfSense API). Zone → DHCP-server mapping kan uit `zones.json` worden afgeleid.

### B — Guest-agent via cloud-init pre-installeren (structureel beste)
De Debian cloud-image zelf of de per-VM user-data `packages:` uitbreiden met `qemu-guest-agent`. Dan is de agent al actief bij eerste boot → `get_vm_ip_guest_agent` werkt meteen → PVE toont IP → `update-os.sh` heeft de DHCP-fallback niet meer nodig. Haalt de kip-en-ei situatie volledig weg voor alle zones.

### C — Zone-onafhankelijke IP-discovery
Bv. ARP-scan vanaf de juiste node (`arp-scan --interface=<br> <subnet>`) met MAC-match. Lastiger want vereist L2-bereik vanaf ergens waar Claude/het script kan landen.

## Aanbeveling
**B** is de nette structurele fix en elimineert de fallback-afhankelijkheid. **A** is de minimale fix als we `update-os.sh` zonder image-wijziging willen laten werken — dan ook de zone → DHCP-mapping ergens formaliseren (bv. in `zones.json`).

## Te verifiëren
```bash
# IP van VM 909 vanaf pfSense
ssh root@<pfsense-host> "cat /var/dhcpd/var/db/dhcpd.leases" | grep -iB2 -A10 '<vm-mac>'
# MAC van VM 909
ssh root@tappaas2.mgmt.internal "qm config 909 | grep ^net0"
# Bevestigen dat mgmt-firewall hem NIET heeft
ssh root@firewall.mgmt.internal "grep -i '<vm-mac>' /var/db/dnsmasq.leases" || echo "niet in mgmt-firewall — bevestigd"
```
