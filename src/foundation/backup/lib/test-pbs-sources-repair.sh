#!/usr/bin/env bash
#
# Unit tests for the deb822 stanza-separator repair in pbs-host.sh (#749).
#
# The defect: installing backup on a PVE node appended the PBS stanza with no
# blank line before it. deb822 separates stanzas with an empty line, so apt read
# the two as ONE stanza with duplicate keys, the later URIs won, and the node's
# PVE repository silently ceased to exist — tappaas3 sat on pve-manager 9.2.10
# against its peers' 9.2.20, with `apt list --upgradable` reporting nothing
# because there was no candidate to report.
#
# These are the two awk programs the repair runs, tested on text. No ssh, no apt.
#
# Usage: ./test-pbs-sources-repair.sh   (exit 0 = all passed)
#
set -uo pipefail

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); }
bad() { echo "  ✗ $1"; fail=$((fail + 1)); }

# The two programs, kept identical to pbs-host.sh's.
detect() { awk 'NR>1 && /^Types:/ && prev != "" { found=1 } { prev=$0 } END { exit !found }' "$1"; }
repair() { awk 'NR>1 && /^Types:/ && prev != "" { print "" } { print; prev=$0 }' "$1"; }

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT

printf 'Types: deb\nURIs: http://d/pve\nComponents: pve-no-subscription\nEnabled: true\nTypes: deb\nURIs: http://d/pbs\nComponents: pbs-no-subscription\n' > "${W}/bad"
printf 'Types: deb\nURIs: http://d/pve\nEnabled: true\n\nTypes: deb\nURIs: http://d/pbs\n' > "${W}/good"
printf 'Types: deb\nURIs: http://d/pve\nEnabled: true\n' > "${W}/single"
printf 'Types: deb\nURIs: http://d/a\nEnabled: true\nTypes: deb\nURIs: http://d/b\nEnabled: true\nTypes: deb\nURIs: http://d/c\n' > "${W}/three"

detect "${W}/bad"    && ok "detects a missing separator"           || bad "a missing separator was not detected"
detect "${W}/good"   && bad "a well-formed file was flagged"       || ok "a well-formed file is left alone"
detect "${W}/single" && bad "a single stanza was flagged"          || ok "a single stanza is not a defect"

repair "${W}/bad" > "${W}/fixed"
detect "${W}/fixed" && bad "the repair did not separate the stanzas" || ok "the repair separates the stanzas"

# Both URIs must survive: the point is that the PVE repo comes BACK, not that the
# file merely parses. A repair that dropped a stanza would satisfy detect().
if grep -q 'http://d/pve' "${W}/fixed" && grep -q 'http://d/pbs' "${W}/fixed"; then
    ok "both repositories survive the repair"
else
    bad "the repair lost a repository"
fi

# Idempotent, because it runs on every sweep.
repair "${W}/fixed" > "${W}/again"
cmp -s "${W}/fixed" "${W}/again" && ok "a second run changes nothing" || bad "the repair is not idempotent"

# More than two stanzas: a site may carry its own.
repair "${W}/three" > "${W}/three-fixed"
if ! detect "${W}/three-fixed" && [[ "$(grep -c '^Types:' "${W}/three-fixed")" == "3" ]]; then
    ok "three concatenated stanzas are all separated, none lost"
else
    bad "three concatenated stanzas were not handled"
fi

# A file whose first line is Types: must not gain a leading blank line — apt
# tolerates it, but a repair that rewrites the first byte of every sources file
# on every sweep is a diff nobody wants to read.
[[ "$(head -c 6 "${W}/fixed")" == "Types:" ]] && ok "no leading blank line is introduced" \
    || bad "the repair prefixed the file with a blank line"

echo ""
echo "  ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
