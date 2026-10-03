#!/usr/bin/env bash
#
# register-group-lights.sh — diyHue synthetic "group light" registration (Route B)
#
# Creates ONE diyHue light per non-empty deCONZ group, each bound to the deCONZ
# GROUP action endpoint (protocol_cfg.deconzType="group" -> handled by the patched
# lights/protocols/deconz.py adapter). The SysAP then controls a whole fixture as
# ONE Hue entity -> one command -> one Zigbee groupcast (atomic), instead of N
# per-light commands. Restores the pre-migration emulated_hue+ZHA-group behaviour.
#
# Idempotent: skips a group-light that already exists (matched by uniqueid -gNN).
# Run ON the diyHue/deCONZ VM (reads creds from config.yaml; no hardcoded secrets).
#
# Usage:  sudo bash register-group-lights.sh
#
set -euo pipefail

DIYHUE="http://127.0.0.1"
CONFIG="/var/lib/diyhue/config.yaml"
GW_MAC="00:21:2e:ff:ff:05:40:0a"   # deCONZ gateway mac — base for synthetic uniqueids

[ -r "$CONFIG" ] || { echo "ERROR: cannot read $CONFIG (run with sudo on the VM)"; exit 2; }

# deCONZ backend creds from diyHue's own config (no hardcoded secrets)
dcz_host=$(awk '/^deconz:/{f=1} f&&/deconzHost:/{print $2; exit}' "$CONFIG")
dcz_port=$(awk '/^deconz:/{f=1} f&&/deconzPort:/{print $2; exit}' "$CONFIG")
dcz_user=$(awk '/^deconz:/{f=1} f&&/deconzUser:/{print $2; exit}' "$CONFIG")
DECONZ="${dcz_host}:${dcz_port}"
# diyHue API user (first whitelist key)
HU=$(sed -n '/^whitelist:/,/^[a-z]/p' "$CONFIG" | grep -oE '[A-Za-z0-9_-]{32}' | head -1)
[ -n "$dcz_user" ] && [ -n "$HU" ] || { echo "ERROR: could not read deconzUser / diyHue key from config"; exit 2; }

# SysAP-facing name per deCONZ group (match the old emulated_hue names for a clean re-link)
name_for() {
  case "$1" in
    "Bedroom North") echo "Spot-WW BN" ;;
    "Bedroom South") echo "Spot-WW BS" ;;
    "Guest Toilet")  echo "Spot-WW GT" ;;
    "Hall")          echo "Spot-WW HA" ;;
    "Kitchen")       echo "Spot-WS KI" ;;
    "Landing")       echo "Spot-WW LA" ;;
    "Living Room")   echo "Spot-WS LR" ;;
    "Shower")        echo "Spot-WS SH1" ;;
    *)               echo "$1" ;;   # fall back to the deCONZ group name
  esac
}

# dedup by NAME: diyHue assigns its own top-level uniqueid (not our protocol_cfg one),
# so name is the reliable key. Synthetic group-lights use the bare fixture name
# ("Spot-WW BS"); the imported individuals are "Light Spot-WW BS3" etc.
existing_names=$(curl -s "$DIYHUE/api/$HU/lights" | jq -r '.[].name')

# one group-light per non-empty deCONZ group (skip the Phoscon all-off pseudo-group)
curl -s "http://$DECONZ/api/$dcz_user/groups" \
  | jq -r 'to_entries[] | select(.value.lights|length > 0) | select(.value.name != "Phoscon_All_Off") | "\(.key)\t\(.value.name)"' \
  | while IFS=$'\t' read -r gid gname; do
      uniqueid="${GW_MAC}-g${gid}"
      name="$(name_for "$gname")"
      if printf '%s\n' "$existing_names" | grep -qxF "$name"; then
        echo "skip (exists): $name  (deCONZ group $gid)"
        continue
      fi
      echo "create: $name  ->  deCONZ group $gid (${gname})"
      curl -s -X POST "$DIYHUE/api/$HU/lights" -H 'Content-Type: application/json' -d "{
        \"ip\":\"$DECONZ\",\"protocol\":\"deconz\",\"config\":{
          \"lightModelID\":\"LTW001\",\"lightName\":\"$name\",
          \"ip\":\"$DECONZ\",\"deconzUser\":\"$dcz_user\",\"deconzId\":\"$gid\",
          \"deconzType\":\"group\",\"modelid\":\"LTW001\",\"uniqueid\":\"$uniqueid\"}}" >/dev/null
      sleep 1
    done

echo "done. group-lights now in diyHue:"
# synthetic group-lights carry the bare fixture name ("Spot-..."); individuals are "Light Spot-...".
curl -s "$DIYHUE/api/$HU/lights" | jq -r '.[] | select((.name|startswith("Spot")) and (.name|startswith("Light")|not)) | "  \(.name)"' | sort
