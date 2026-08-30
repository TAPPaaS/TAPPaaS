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
    # tappaas_fw_ssh() (ADR-018, firewall identity domain): under sudo -n
    # SSH's default identity search looks in /root/.ssh (empty), never $HOME.
    if ! declare -F tappaas_fw_ssh >/dev/null 2>&1 && [ -f /home/tappaas/bin/common-install-routines.sh ]; then
        # shellcheck source=/home/tappaas/bin/common-install-routines.sh disable=SC1091
        . /home/tappaas/bin/common-install-routines.sh ""
    fi
    echo "== DEEP: dhcp-manager pxe round-trip (live firewall, self-cleaning) =="
    if command -v dhcp-manager >/dev/null 2>&1 \
       && ping -c 1 -W 1 "${TAPPAAS_FIREWALL_FQDN:-firewall.mgmt.internal}" >/dev/null 2>&1; then
        if dhcp-manager --no-ssl-verify pxe status >/dev/null 2>&1; then
            echo "  SKIP: PXE already enabled (operator/provisioner owns it) — not touching"
        else
            _pxe_ok=1
            _fw="${TAPPAAS_FIREWALL_FQDN:-firewall.mgmt.internal}"
            dhcp-manager --no-ssl-verify pxe enable --next-server 10.0.0.250 --bootfile zztest.efi --zone mgmt --ipxe-script-url http://10.0.0.250:8090/boot.ipxe >/dev/null 2>&1 || _pxe_ok=0
            if [ "${_pxe_ok}" = "1" ] && dhcp-manager --no-ssl-verify pxe status >/dev/null 2>&1; then
                echo "  ok: pxe enable → status sees the boot entry"
            else
                echo "[Error]   pxe enable/status failed" >&2; _pxe_ok=0
            fi
            # The drop-in must carry the negated iPXE tag (breaks the
            # stock-iPXE self-download loop — inexpressible via the API,
            # stage-1 finding).
            if printf 'grep -q "tag:!tappaas-ipxe" /usr/local/etc/dnsmasq.conf.d/tappaas-pxe.conf && echo NEGATED\n' \
                 | tappaas_fw_ssh "root@${_fw}" 'sh -s' 2>/dev/null | grep -q NEGATED; then
                echo "  ok: drop-in carries the negated iPXE tag"
            else
                echo "[Error]   drop-in lacks the negated tag (or is missing)" >&2; _pxe_ok=0
            fi
            # host set/del round-trip — AND its reconfigure must not wipe
            # the PXE drop-in (that is the whole point of conf.d).
            # Guard: skip if tappaas9 is a REAL pinned node on this site.
            if printf 'grep -E "dhcp-host=.*tappaas9" /usr/local/etc/dnsmasq.conf && echo REAL\n' \
                 | tappaas_fw_ssh "root@${_fw}" 'sh -s' 2>/dev/null | grep -q REAL; then
                echo "  SKIP: tappaas9 has a live MAC pinning — not touching it"
            else
                if dhcp-manager --no-ssl-verify host set tappaas9 --ip 10.0.0.18 --mac de:ad:be:ef:99:99 >/dev/null 2>&1 \
                   && printf 'grep -q "de:ad:be:ef:99:99" /usr/local/etc/dnsmasq.conf && echo PINNED\n' \
                        | tappaas_fw_ssh "root@${_fw}" 'sh -s' 2>/dev/null | grep -q PINNED; then
                    echo "  ok: host set renders a dhcp-host reservation"
                else
                    echo "[Error]   host set did not render a reservation" >&2; _pxe_ok=0
                fi
                dhcp-manager --no-ssl-verify host del tappaas9 >/dev/null 2>&1 || _pxe_ok=0
                if printf 'grep -q "de:ad:be:ef:99:99" /usr/local/etc/dnsmasq.conf || echo CLEARED\n' \
                     | tappaas_fw_ssh "root@${_fw}" 'sh -s' 2>/dev/null | grep -q CLEARED; then
                    echo "  ok: host del clears the pinning again"
                else
                    echo "[Error]   host del left the reservation behind" >&2; _pxe_ok=0
                fi
                if dhcp-manager --no-ssl-verify pxe status >/dev/null 2>&1; then
                    echo "  ok: PXE drop-in survived the host reconfigures"
                else
                    echo "[Error]   a reconfigure wiped the PXE drop-in" >&2; _pxe_ok=0
                fi
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
