#!/usr/bin/env bash
#
# cluster:storage — shared helpers for the dispatcher (install/update/delete/
# test-service.sh). A module never talks to a storage backend directly: it
# declares a share NAME in its `sharedStorage` array, and this dispatcher
# resolves that name against whichever backend's registry actually owns it,
# then rewrites the module's own `fileSystems` marker block. No SSH/mount/
# rebuild happens here — that's left to the module's own install.sh/update.sh,
# which always runs AFTER dependsOn services (this one included).
#
# Sourced after common-install-routines.sh. Relies on: CONFIG_DIR, error/die.

# Backend name -> registry file, relative to CONFIG_DIR. Add a new backend
# (e.g. CephFS) by adding ONE line here — every other dispatcher script
# (install/update/delete/test) is already backend-agnostic.
declare -gA STORAGE_BACKENDS=(
    [nfs]="nfs-shares.json"
)

# Is share <name> registered in ANY backend's registry? Prints nothing;
# returns 0/1. Used by test-service.sh and the install/update dispatchers to
# fail loudly on a stale/removed share rather than silently no-op.
storage_name_registered() {
    local name="$1" backend registry
    for backend in "${!STORAGE_BACKENDS[@]}"; do
        registry="${CONFIG_DIR}/${STORAGE_BACKENDS[$backend]}"
        [[ -f "${registry}" ]] || continue
        jq -e --arg n "${name}" 'has($n)' "${registry}" >/dev/null 2>&1 && return 0
    done
    return 1
}

# Collect the NixOS fileSystems snippet(s) for every sharedStorage entry
# declared by a module, one JSON line per entry:
#   {"mountPoint","access","device","fsType","options"}
# Delegates to each backend's own params script (self-contained computation,
# no SSH/side effects) — today only services/nfs/mount-params.sh exists.
storage_collect_nix_snippets() {
    local module_json="$1" node_fqdn="$2"
    local entry name mount_point access backend registry found
    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        name=$(jq -r '.name' <<<"${entry}")
        mount_point=$(jq -r '.mountPoint' <<<"${entry}")
        access=$(jq -r '.access // "rw"' <<<"${entry}")

        found=""
        for backend in "${!STORAGE_BACKENDS[@]}"; do
            registry="${CONFIG_DIR}/${STORAGE_BACKENDS[$backend]}"
            [[ -f "${registry}" ]] || continue
            if jq -e --arg n "${name}" 'has($n)' "${registry}" >/dev/null 2>&1; then
                found="${backend}"
                break
            fi
        done
        [[ -n "${found}" ]] || die "sharedStorage entry '${name}' is not registered in any backend's registry (has it been removed via nfs-manager.sh remove?)"

        case "${found}" in
            nfs)
                "${SCRIPT_DIR}/../nfs/mount-params.sh" "${name}" "${mount_point}" "${access}" "${node_fqdn}"
                ;;
            *)
                die "no params script wired for backend '${found}'"
                ;;
        esac
    done < <(jq -c '(.sharedStorage // [])[]' <<<"$(cat "${module_json}")")
}

# Rewrite the marked block in a module's own .nix source with the given
# fileSystems snippets (one or more `fileSystems."<mount>" = {...};` stanzas,
# newline-joined). Requires the marker comments already present — dies with
# clear guidance if absent (this is a one-time addition to a module's .nix,
# not something the dispatcher can safely inject blind).
#   BEGIN/END markers: "# BEGIN cluster:storage ... # END cluster:storage"
storage_rewrite_nix_block() {
    local nix_file="$1" content="$2"
    grep -q '# BEGIN cluster:storage' "${nix_file}" \
        || die "${nix_file} has no '# BEGIN cluster:storage' marker — add the marker block (see jellyfin.nix for the pattern) before this module can use cluster:storage"
    grep -q '# END cluster:storage' "${nix_file}" \
        || die "${nix_file} has a BEGIN marker but no matching '# END cluster:storage'"

    local tmp
    tmp="$(mktemp)"
    awk -v content="${content}" '
        /# BEGIN cluster:storage/ { print; print content; skip=1; next }
        /# END cluster:storage/   { skip=0 }
        !skip { print }
    ' "${nix_file}" > "${tmp}"
    mv "${tmp}" "${nix_file}"
}
