#!/usr/bin/env bash
# component-install-lib.sh — shared helpers for component verb scripts
# (ADR-007 post-implementation refactor, Phase 3.8 — F8: the nix-build/link
# scaffolding used to be pasted verbatim into every component's install.sh;
# per the lib/ doctrine it lives here ONCE and is sourced, never copied).
#
# Source it repo-relative from a component's install.sh (works on a virgin
# checkout, before anything is linked into ~/bin):
#
#   here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${here}/../../lib/component-install-lib.sh"
#
# Deliberately tiny and side-effect free (unlike common-install-routines.sh,
# which initialises module context when sourced).

# build_and_link_nix_component <component-dir> <name> [tool ...]
#
# Build the component as a flake package (<flake-root>#<name>) with a GC-rooted
# --out-link under ${TAPPAAS_GCROOTS:-~/.tappaas-gcroots}/<name> — the root
# keeps nix-collect-garbage from deleting the build out from under the ~/bin
# symlinks — then link each <tool> (default: just <name>) from the build's
# bin/ into ${TAPPAAS_BIN:-/home/tappaas/bin}. Idempotent; returns non-zero
# on build failure or a missing tool.
build_and_link_nix_component() {
    local dir="$1" name="$2"; shift 2
    local tools=("$@")
    [ "${#tools[@]}" -eq 0 ] && tools=("${name}")
    local bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
    local gcroots="${TAPPAAS_GCROOTS:-${HOME}/.tappaas-gcroots}"
    mkdir -p "${bin}" "${gcroots}"
    echo "  building ${name} (nix build, flake-pinned)..."
    # nix build --print-out-paths writes the store path to stdout (captured into
    # $out) and the
    # BUILD LOG on stderr — dot-per-line it to the terminal (house style) and
    # keep the full log for post-mortem. The dot filter writes to fd 2 so the
    # captured stdout stays exactly the store path.
    # Build through the flake, not `nix-build default.nix`, so pkgs comes from
    # the nixpkgs pinned in flake.lock instead of the ambient <nixpkgs> search
    # path. That path is unset under systemd — so the nightly never built these
    # at all, logging only a warning — and interactively it resolves via the
    # network flake registry, which hangs on HTTP 429 once the registry cache
    # goes stale. Same revision as the system closure, and no network. (#467)
    local flake_root="${dir}"
    while [ ! -f "${flake_root}/flake.nix" ]; do
        [ "${flake_root}" = "/" ] && { echo "  ERROR: no flake.nix above ${dir}" >&2; return 1; }
        flake_root="$(dirname "${flake_root}")"
    done

    local out log="/tmp/tappaas-build-${name}.log"
    out="$(
        nix build "${flake_root}#${name}" --print-out-paths --out-link "${gcroots}/${name}" \
            2> >(tee "${log}" | while IFS= read -r _; do printf '.' >&2; done)
    )" || {
        echo "" >&2
        echo "  ERROR: nix build failed for ${name} — log tail (full log: ${log}):" >&2
        tail -8 "${log}" >&2 2>/dev/null || true
        return 1
    }
    echo "" >&2
    local t
    for t in "${tools[@]}"; do
        if [ -e "${out}/bin/${t}" ]; then
            ln -sfn "${out}/bin/${t}" "${bin}/${t}"
            echo "  linked ${bin}/${t} -> ${out}/bin/${t}"
        else
            echo "  ERROR: build did not produce ${t}" >&2
            return 1
        fi
    done
}

# link_component_executables <component-dir>
#
# Link every regular file in <component-dir> into ~/bin, skipping the verb
# scripts (install/update/test/validate.sh), *.md docs and test-*. The
# bash-component half of the install contract (controllers + the bash entry
# points TS managers still carry).
link_component_executables() {
    local dir="$1"
    local bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
    mkdir -p "${bin}"
    local f b
    for f in "${dir}"/*; do
        [ -f "${f}" ] || continue
        b="$(basename "${f}")"
        case "${b}" in install.sh|update.sh|test.sh|validate.sh|*.md) continue ;; esac
        case "${b}" in test-*) continue ;; esac
        [ -x "${f}" ] || chmod +x "${f}"
        ln -sfn "${f}" "${bin}/${b}"
        echo "  linked ${bin}/${b}"
    done
}

# run_component_test_scripts <component-dir>
#
# Run every co-located test-*.sh in <component-dir>; return non-zero if any
# fails (the standard bash-component test.sh body).
run_component_test_scripts() {
    local dir="$1" rc=0 t
    shopt -s nullglob
    for t in "${dir}"/test-*.sh; do
        echo "== $(basename "${t}") =="
        bash "${t}" || rc=1
    done
    return "${rc}"
}
