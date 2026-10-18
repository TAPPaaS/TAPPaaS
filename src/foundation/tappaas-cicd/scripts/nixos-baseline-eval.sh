#!/usr/bin/env bash
#
# nixos-baseline-eval.sh — evaluate module NixOS configs WITH the TAPPaaS baseline,
# offline, before any VM is rebuilt (#324).
#
# Every module .nix used to carry its own copy of templates/tappaas-common.nix,
# and the copies drifted: no app VM got zram (#323), the cloud-init network fix
# (#448), the host-key fix or the file-backup trigger (#626). Importing the
# baseline instead fails on any option a module still restates with another
# value — and on a guest that failure is a rebuild that rolls back. This finds it
# here: each module is evaluated as update-os.sh builds it (the nixpkgs pinned in
# templates/flake.lock), with the baseline imported when the module does not yet
# import it itself. Nothing is built; the system's derivation is only computed,
# which forces every option definition and assertion.
#
# The guest's /etc/nixos files are stood in for: the module's own siblings and
# JSON, the baseline from this checkout, and empty site / backup fragments.
#
# Usage: nixos-baseline-eval.sh [--as-is] [--drv] [--nixpkgs <path|url>] [<module.nix>...]
#   (no files)  every module .nix under src/ that sets system.stateVersion,
#               except the templates themselves and the mothership (a flake)
#   --as-is     evaluate the module alone, without adding the baseline (the "before")
#   --drv       print each system's derivation: removing a copy that equals the
#               baseline should leave it unchanged (compare two runs; nix-diff)
#   --nixpkgs   nixpkgs to evaluate against (default: the template's pinned rev)
#   --src DIR   the tree to evaluate (a src/ directory) instead of this checkout's —
#               another release's, unpacked (the release CVE preview, #788)
# Exit: 0 all evaluate; 1 at least one fails; 2 usage or no nix.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../.." && pwd)"
BASELINE="${SRC}/foundation/templates/tappaas-common.nix"
AS_IS=0; DRV=0; NIXPKGS=""
FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --as-is)   AS_IS=1; shift ;;
        --drv)     DRV=1; shift ;;
        --nixpkgs) NIXPKGS="${2:?--nixpkgs needs a value}"; shift 2 ;;
        --src)     SRC="$(cd "${2:?--src needs a directory}" && pwd)"; BASELINE="${SRC}/foundation/templates/tappaas-common.nix"; shift 2 ;;
        -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)        echo "nixos-baseline-eval: unknown option $1" >&2; exit 2 ;;
        *)         FILES+=("$1"); shift ;;
    esac
done
command -v nix-instantiate >/dev/null 2>&1 || { echo "nixos-baseline-eval: needs nix (run it on the mothership)" >&2; exit 2; }

if [[ -z "${NIXPKGS}" ]]; then
    # The pin by its narHash (ADR-033 D8), as update-os.sh fetches it.
    pin="$(jq -r '.nodes.nixpkgs.locked | select(.type == "github" and .narHash != null)
        | "builtins.fetchTarball { url = \"https://github.com/\(.owner)/\(.repo)/archive/\(.rev).tar.gz\"; sha256 = \"\(.narHash)\"; }"' \
        "${SRC}/foundation/templates/flake.lock" 2>/dev/null)"
    [[ -n "${pin}" ]] || { echo "nixos-baseline-eval: no pinned nixpkgs in templates/flake.lock; pass --nixpkgs" >&2; exit 2; }
    NIXPKGS="$(nix eval --impure --raw --expr "${pin}")" \
        || { echo "nixos-baseline-eval: could not fetch the pinned nixpkgs by its narHash" >&2; exit 2; }
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(
        grep -rl --include='*.nix' 'system\.stateVersion' "${SRC}" \
            | grep -v -e '/foundation/templates/' -e '/flake\.nix$' -e '/foundation/tappaas-cicd/tappaas-cicd\.nix$' | sort)
fi

# A module imports the baseline when a live (uncommented) line names it.
imports_baseline() { sed -E 's/#.*$//' "$1" | grep -q 'tappaas-common\.nix'; }

# A fixed place, not mktemp: the stand-in /etc/nixos path ends up in the
# derivations, and two runs (before and after a change) must be comparable.
WORK="${TMPDIR:-/tmp}/tappaas-nixos-baseline-eval"
rm -rf "${WORK}"; mkdir -p "${WORK}"; trap 'rm -rf "${WORK}"' EXIT
PASS=0; FAIL=0
for f in "${FILES[@]}"; do
    f="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
    name="$(basename "$f" .nix)"; rel="${f#"${SRC}"/}"
    d="${WORK}/${name}"; mkdir -p "${d}/etc"
    cp "$(dirname "$f")"/*.nix "${d}/" 2>/dev/null
    for x in "$(dirname "$f")"/*.json "$(dirname "$f")"/*.patch "$(dirname "$f")"/*.diff; do
        [[ -f "$x" ]] && cp "$x" "${d}/" && cp "$x" "${d}/etc/"
    done
    cp "${BASELINE}" "${d}/etc/tappaas-common.nix"
    printf '{ }\n' > "${d}/etc/tappaas-site.nix"
    printf '{ }\n' > "${d}/etc/tappaas-backup.nix"
    # A module that steps along what the guest runs reads its build facts (#797):
    # the stand-in guest is a fresh one, so its own collector on an empty root.
    [[ -f "$(dirname "$f")/build-facts.sh" ]] \
        && FACTS_ROOT="${d}/guest" bash "$(dirname "$f")/build-facts.sh" > "${d}/etc/tappaas-build-facts.env"
    printf '{ ... }: { fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; }; }\n' \
        > "${d}/etc/hardware-configuration.nix"
    # The guest's /etc/nixos is this directory's etc/.
    sed -i.orig -e "s#/etc/nixos/#${d}/etc/#g" "${d}"/*.nix "${d}/etc/tappaas-common.nix" && rm -f "${d}"/*.orig "${d}"/etc/*.orig
    extra=""
    (( AS_IS )) || imports_baseline "$f" || extra="./etc/tappaas-common.nix"
    printf '{ imports = [ ./%s.nix %s ]; }\n' "${name}" "${extra}" > "${d}/wrapper.nix"

    # --drv instantiates (writes the .drv files, builds nothing) so two runs can
    # be compared derivation by derivation; otherwise the path is only computed.
    if (( DRV )); then
        mode=(--quiet -A config.system.build.toplevel)
    else
        mode=(--eval --quiet -A config.system.build.toplevel.drvPath)
    fi
    if out="$(nix-instantiate "${mode[@]}" -I "nixpkgs=${NIXPKGS}" -I "nixos-config=${d}/wrapper.nix" \
                '<nixpkgs/nixos>' 2>&1)"; then
        echo "  ok: ${rel}$( (( DRV )) && printf ' %s' "$(tail -1 <<<"${out}")")"; PASS=$((PASS+1))
    else
        echo "  FAIL: ${rel}"; FAIL=$((FAIL+1))
        # The verdict, not the trace: the error line and the definitions it names.
        sed -e "s#${d}/etc/#/etc/nixos/#g" -e "s#${d}/#./#g" <<<"${out}" \
            | grep -E '^error:|^ *- In |^ *… while|conflicting|has no|does not exist|undefined' \
            | grep -v '… while' | head -8 | sed 's/^/        /'
    fi
done
echo
echo "${PASS} evaluate, ${FAIL} fail ($( (( AS_IS )) && echo "as-is" || echo "with the baseline"))"
(( FAIL == 0 ))
