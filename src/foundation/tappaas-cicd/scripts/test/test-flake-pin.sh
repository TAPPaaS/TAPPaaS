#!/usr/bin/env bash
#
# A rebuild says what nixpkgs it pins, and warns when that moves BACK (#680).
#
# tappaas-self-rebuild.sh builds from the checkout's flake (ADR-017 D3), so one
# lock in this repository decides the nixpkgs revision of every site that adopts
# the sanctioned path. A host that used to build from a newer flake of its own
# downgrades on the first such rebuild — kernel, curl, gnutls, bind — while the
# rebuild reports success. The comparison below is what breaks that silence.
#
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SELF="${HERE}/../tappaas-self-rebuild.sh"
pass=0; fail=0
ok()  { echo "  ✓ $*"; pass=$((pass+1)); }
bad() { echo "  ✗ $*"; fail=$((fail+1)); }

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT
mkdir -p "${W}/bin" "${W}/cicd"

# The block under test, lifted from the script so this stays a unit test: no
# nixos-rebuild, no root, no switch.
extract() { sed -n '/^_lock="\${CICD_DIR}\/flake.lock"/,/^fi$/p' "${SELF}"; }
[[ -n "$(extract)" ]] || { echo "could not extract the pin check from ${SELF}"; exit 2; }

run_case() {   # <lock-epoch> <lock-rev> <running-version> <running-rev>
    cat > "${W}/cicd/flake.lock" <<JSON
{ "nodes": { "nixpkgs": { "locked": { "rev": "$2", "lastModified": $1 } } } }
JSON
    cat > "${W}/bin/nixos-version" <<STUB
#!/usr/bin/env bash
[[ "\${1:-}" == "--json" ]] && { printf '{"nixpkgsRevision":"%s"}\n' "$4"; exit 0; }
printf '%s\n' "$3"
STUB
    chmod +x "${W}/bin/nixos-version"
    (
        PATH="${W}/bin:${PATH}"; CICD_DIR="${W}/cicd"
        info(){ echo "INFO $*"; }; warn(){ echo "WARN $*"; }
        eval "$(extract)"
    ) 2>&1
}

# Older lock than the running system, different revision → a downgrade.
out="$(run_case 1747930000 aaaaaaaaaaaa1111 25.11.20260608.e820eb4 e820eb4bbbbb2222)"
grep -q "moves nixpkgs BACKWARDS" <<<"${out}" && ok "a lock older than the running system is called out" \
    || bad "silent downgrade: ${out}"
grep -q "running now : e820eb4bbbbb" <<<"${out}" && grep -q "this flake  : aaaaaaaaaaaa" <<<"${out}" \
    && ok "…naming both revisions, so the operator can see which is which" || bad "revisions not named"

# Same revision → nothing to warn about, whatever the dates say.
out="$(run_case 1747930000 b77b3de87756 25.11.20260522.b77b3de b77b3de87756)"
grep -q "BACKWARDS" <<<"${out}" && bad "warned about the revision it is already on" \
    || ok "the revision it already runs is not a downgrade"

# Newer lock → an upgrade, no warning.
out="$(run_case 1790000000 ccccccccccc33333 25.11.20260522.b77b3de b77b3de87756)"
grep -q "BACKWARDS" <<<"${out}" && bad "warned about an upgrade" || ok "a newer lock is not a downgrade"

# The pin and its age are always on the record.
grep -q "nixpkgs pin: ccccccccccc3" <<<"${out}" && grep -qE "[0-9]+d old" <<<"${out}" \
    && ok "every rebuild records the pin and how old it is" || bad "pin/age not reported: ${out}"

echo "── one pin for the estate (ADR-028 D1) ──"
# The mothership must not hold a nixpkgs of its own: two locks refreshed by
# hand are what D1 removes, and the only thing that keeps them together is that
# one FOLLOWS the other. Asserted against the shipped files, because a
# hand-edited flake.nix is exactly how the second pin comes back.
_cicd_flake="${HERE}/../../flake.nix"
_cicd_lock="${HERE}/../../flake.lock"
_tmpl_lock="${HERE}/../../../templates/flake.lock"
if [[ -r "${_cicd_flake}" && -r "${_cicd_lock}" && -r "${_tmpl_lock}" ]]; then
    grep -q 'inputs.nixpkgs.follows = "templates/nixpkgs"' "${_cicd_flake}" \
        && ok "the mothership's flake follows templates/nixpkgs" \
        || bad "tappaas-cicd/flake.nix does not follow the estate pin"
    grep -q 'inputs.nixpkgs.url' "${_cicd_flake}" \
        && bad "tappaas-cicd/flake.nix still declares a nixpkgs url of its own" \
        || ok "…and declares no nixpkgs url of its own"
    _f="$(jq -r '(.nodes.root.inputs.nixpkgs | if type == "array" then join("/") else . end) // ""' "${_cicd_lock}")"
    [[ "${_f}" == "templates/nixpkgs" ]] \
        && ok "the lock records the follows, not a revision" \
        || bad "tappaas-cicd/flake.lock resolves nixpkgs itself ('${_f}')"
    # The guarantee in the form that matters: the same bits, both places.
    _a="$(jq -r '.nodes.nixpkgs.locked.rev // ""' "${_cicd_lock}")"
    _b="$(jq -r '.nodes.nixpkgs.locked.rev // ""' "${_tmpl_lock}")"
    [[ -n "${_a}" && "${_a}" == "${_b}" ]] \
        && ok "both locks name the same revision (${_a:0:12})" \
        || bad "locks disagree: cicd=${_a:0:12} templates=${_b:0:12}"
else
    bad "flake files not found beside this suite"
fi

echo "── summary: ${pass} pass, ${fail} fail ──"
[[ "${fail}" -eq 0 ]]
