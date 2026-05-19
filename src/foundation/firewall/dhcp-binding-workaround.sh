#!/usr/bin/env bash
# DHCP-binding workaround — omzeilt kapotte oxl-lib dnsmasq_range-laag.
# Issue #5 (reopent/superseert GitHub #179). Root cause: oxl-lib dnsmasq_range
# geeft interface-param niet door; rauwe OPNsense addRange+interface=optN werkt wel.
# Bewezen werkend via TESTPROBE (rauwe addRange + interface=optN -> saved).
# Idempotent: verwijdert bestaande range per description, maakt opnieuw met binding.
#
# ⚠️ MAPPING IS HARDCODED, NIET afgeleid uit zones-soho.json (bewust: oxl-lib =
#    de kapotte laag, dus toolchain-parsing vermijden). Bron van waarheid =
#    VM 130's 12-zone zones-soho.json × geverifieerde opt-binding
#    (interfaces/overview/export). Bij wijziging van zones-soho.json
#    (zone toevoegen/hernoemen/subnet wijzigen) MOET de Z-array hieronder
#    handmatig mee.
# ⚠️ OPT-NUMMERS KUNNEN WIJZIGEN na een herinstallatie (OPNsense wijst vrije
#    opt-nummers toe). Na standaard-install 2026-05-19: opt2-8 hernummerd
#    naar opt12-16. Altijd verifiëren via overview/export voor draaien.
#    Laatst geverifieerd: 2026-05-19 post-reinstall (VM 130 @ main).
# ⚠️ Zolang dit script de DHCP-binding beheert: NOOIT `zone-manager --execute`
#    zonder `--*-only` (configure_all-DHCP overschrijft binding met interface='').
set -euo pipefail

# env-var-guard (Issue 1: cred-file-parser kapot → env-vars verplicht, per shell;
# zie runbook Step 6-body voor de export-workaround)
: "${OPNSENSE_TOKEN:?OPNSENSE_TOKEN niet gezet — zie runbook Step 6-body env-var-workaround}"
: "${OPNSENSE_SECRET:?OPNSENSE_SECRET niet gezet — zie runbook Step 6-body env-var-workaround}"

F="https://10.0.0.1:8443/api/dnsmasq/settings"
AUTH="-u $OPNSENSE_TOKEN:$OPNSENSE_SECRET"

# opt -> "name|start|end"  (uit zones-soho.json x geverifieerde opt-binding)
# Post-reinstall 2026-05-19: opt2/3/6/7/8 hernummerd naar opt12/13/14/15/16
declare -A Z=(
  [opt1]="srv-home|10.2.10.50|10.2.10.250"
  [opt12]="srv-work|10.2.20.50|10.2.20.250"
  [opt13]="srv-cust|10.2.30.50|10.2.30.250"
  [opt4]="home|10.3.10.50|10.3.10.250"
  [opt10]="work|10.3.20.50|10.3.20.250"
  [opt5]="iot-local|10.4.10.50|10.4.10.250"
  [opt14]="iot-cloud|10.4.20.50|10.4.20.250"
  [opt15]="iot-cams|10.4.30.50|10.4.30.250"
  [opt16]="guest|10.5.10.50|10.5.10.250"
  [opt9]="dmz|10.6.0.50|10.6.0.250"
)

# bestaande zone-ranges (description "<name> DHCP") ophalen voor idempotente delete
existing=$(curl -sk $AUTH "$F/searchRange")

for opt in "${!Z[@]}"; do
  IFS='|' read -r name start end <<< "${Z[$opt]}"
  desc="$name DHCP"
  dom="$name.internal"

  # idempotent: verwijder bestaande range met deze description
  uuid=$(echo "$existing" | python3 -c "
import sys,json
for r in json.load(sys.stdin)['rows']:
    if r.get('description')=='$desc': print(r['uuid']); break
" 2>/dev/null || true)
  if [ -n "${uuid:-}" ]; then
    curl -sk $AUTH -X POST "$F/delRange/$uuid" >/dev/null
    echo "  $name: oude range verwijderd ($uuid)"
  fi

  # aanmaken met interface-binding (bewezen werkend)
  resp=$(curl -sk $AUTH -X POST "$F/addRange" -H "Content-Type: application/json" \
    -d "{\"range\":{\"interface\":\"$opt\",\"start_addr\":\"$start\",\"end_addr\":\"$end\",\"description\":\"$desc\",\"domain\":\"$dom\",\"lease_time\":\"86400\"}}")
  echo "  $name -> $opt : $resp"
done

# service herladen (werkende endpoint: dnsmasq/service/reconfigure, NIET settings/service/reconfigure)
echo -n "reconfigure: "
curl -sk $AUTH -X POST "https://10.0.0.1:8443/api/dnsmasq/service/reconfigure" | head -c 40; echo

# DIRECTE-API-VERIFICATIE (de waarheid, niet tool-output)
echo "--- verificatie ---"
curl -sk $AUTH "$F/searchRange" | python3 -c '
import sys,json
r=json.load(sys.stdin)["rows"]
print(len(r),"ranges total")
for x in sorted(r,key=lambda z:z.get("start_addr","")):
    print(repr(x.get("interface")), x.get("start_addr"), "-", x.get("end_addr"))'