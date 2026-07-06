#!/usr/bin/env bash
# opnsense-controller/test.sh — build the package env (nix), then run the
# co-located Python unit tests (stdlib `unittest`) against it. Mirrors
# identity-controller/test.sh.
#
# These are OFFLINE unit tests (mocked OPNsense API) for the zone / rules / dhcp /
# caddy / acme / dns managers. The LIVE opnsense plane (real rules, NAT, split-
# horizon, connectivity) is exercised by network/test.sh — this wrapper closes the
# gap where these unit tests were not run by the component contract at all.
#
# Exit non-zero on any failure.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== building opnsense-controller (nix) =="
( cd "${here}" && nix-build -A default default.nix >/dev/null )

py="${here}/result/bin/python"
if [ ! -x "${py}" ]; then
    echo "[Error] python not found in build result: ${py}" >&2
    exit 1
fi

echo "== unit tests (python -m unittest discover src/test) =="
PYTHONPATH="${here}/src" "${py}" -m unittest discover -s "${here}/src/test" -v

# ── DEEP: dhcp-manager pxe enable/disable round-trip (live firewall) ────
# Self-cleaning regression guard for the N3 PXE DHCP verbs (node-provisioning
# design): enable writes the TAPPaaS-tagged dnsmasq boot entry, status must
# see it (rc 0), disable must remove it (status rc 1). Never touches an
# operator-enabled PXE setup (skips if already enabled).
if [ "${TAPPAAS_TEST_DEEP:-0}" = "1" ]; then
    echo "== DEEP: dhcp-manager pxe round-trip (live firewall, self-cleaning) =="
    if command -v dhcp-manager >/dev/null 2>&1 \
       && ping -c 1 -W 1 "${TAPPAAS_FIREWALL_FQDN:-firewall.mgmt.internal}" >/dev/null 2>&1; then
        if dhcp-manager --no-ssl-verify pxe status >/dev/null 2>&1; then
            echo "  SKIP: PXE already enabled (operator/provisioner owns it) — not touching"
        else
            _pxe_ok=1
            dhcp-manager --no-ssl-verify pxe enable --next-server 10.0.0.250 --bootfile zztest.efi --zone mgmt >/dev/null 2>&1 || _pxe_ok=0
            if [ "${_pxe_ok}" = "1" ] && dhcp-manager --no-ssl-verify pxe status >/dev/null 2>&1; then
                echo "  ok: pxe enable → status sees the boot entry"
            else
                echo "[Error]   pxe enable/status failed" >&2; _pxe_ok=0
            fi
            dhcp-manager --no-ssl-verify pxe disable >/dev/null 2>&1 || _pxe_ok=0
            if dhcp-manager --no-ssl-verify pxe status >/dev/null 2>&1; then
                echo "[Error]   pxe disable left the boot entry behind" >&2; _pxe_ok=0
            else
                echo "  ok: pxe disable cleans up (status reports disabled)"
            fi
            [ "${_pxe_ok}" = "1" ] || exit 1
        fi
    else
        echo "  SKIP: firewall unreachable or dhcp-manager not installed"
    fi
fi
