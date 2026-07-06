#!/bin/sh
#
# apply-caddy-isdnsname.sh — patch OPNsense os-caddy ToDomain + AuthToDomain
# fields to allow underscored hostnames (#237 follow-up).
#
# Runs ON the firewall (FreeBSD). Pushed there by pre-update.sh and invoked
# after the scp lands the script. Idempotent: re-running is a no-op.
#
# Background: OPNsense's HostnameField uses PHP's FILTER_FLAG_HOSTNAME by
# default, which forbids underscores in hostnames per RFC 952/1123. The os-
# caddy plugin uses HostnameField for the ToDomain (upstream) and AuthToDomain
# (forward-auth) fields, so it rejects internal DNS names like
# litellm.srvHome.internal. Setting <IsDNSName>Y</IsDNSName> on the field
# flips the validator to RFC 2181 mode, which accepts underscores in DNS
# labels — fine for internal-only DNS.
#
# Restarts configd after the edit so the model change picks up.
#
# Exit codes:
#   0  patched or already patched
#   1  Caddy.xml not found
#

set -u

CADDY_XML=/usr/local/opnsense/mvc/app/models/OPNsense/Caddy/Caddy.xml

if [ ! -f "${CADDY_XML}" ]; then
    echo "${CADDY_XML} not found — is os-caddy installed?" >&2
    exit 1
fi

# Backup once (first run only — never overwrite a pre-existing backup).
if [ ! -f "${CADDY_XML}.pre-237.bak" ]; then
    cp "${CADDY_XML}" "${CADDY_XML}.pre-237.bak"
fi

CHANGED=0

# 1. Patch the <handle><ToDomain type="HostnameField"> block (multi-line form).
#    Add <IsDNSName>Y</IsDNSName> as the first child if it's not already there.
if grep -q '<ToDomain type="HostnameField">' "${CADDY_XML}"; then
    # Check whether the line FOLLOWING <ToDomain ...> contains IsDNSName.
    # Use awk to detect the pattern across two lines reliably.
    if ! awk '
        /<ToDomain type="HostnameField">/ { inside = 1; next }
        inside && /<IsDNSName>Y<\/IsDNSName>/ { found = 1 }
        inside && /<\/ToDomain>/             { inside = 0 }
        END { exit found ? 0 : 1 }
    ' "${CADDY_XML}"; then
        # Insert just after the opening tag, preserving original indentation.
        sed -i.tmp -E 's|(<ToDomain type="HostnameField">)|\1\n                    <IsDNSName>Y</IsDNSName>|' "${CADDY_XML}"
        rm -f "${CADDY_XML}.tmp"
        CHANGED=1
        echo "  patched: <handle><ToDomain> → +<IsDNSName>Y</IsDNSName>"
    fi
fi

# 2. Patch the self-closing <AuthToDomain type="HostnameField"/> form. Expand
#    it to a block with IsDNSName=Y. Only act if it's still self-closing.
if grep -q '<AuthToDomain type="HostnameField"/>' "${CADDY_XML}"; then
    sed -i.tmp -E 's|<AuthToDomain type="HostnameField"/>|<AuthToDomain type="HostnameField"><IsDNSName>Y</IsDNSName></AuthToDomain>|' "${CADDY_XML}"
    rm -f "${CADDY_XML}.tmp"
    CHANGED=1
    echo "  patched: <AuthToDomain/> → <AuthToDomain><IsDNSName>Y</IsDNSName></AuthToDomain>"
fi

if [ "${CHANGED}" -eq 0 ]; then
    echo "  Caddy.xml ToDomain/AuthToDomain already patched — no change"
    exit 0
fi

# OPNsense reloads MVC model XML on the next API request, so we DO NOT need
# to restart configd here. Restarting configd is disruptive: it briefly
# unbinds VLAN interfaces and can leave the runtime in a state where the
# kernel-level IP assignment for opt-style interfaces falls out of sync with
# /conf/config.xml (observed in #237 verification — srvHome VLAN 210 lost
# its IP after configd restart and only `ifconfig vlan0.210 inet 10.2.10.1/24`
# brought it back).
#
# If a future os-caddy version caches model definitions, add a targeted
# `configctl caddy reload` here instead — never the global configd restart.

echo "  patch active on next API request (no service restart needed)"
exit 0
