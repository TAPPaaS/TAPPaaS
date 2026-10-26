# control-plane-components.sh — a module's own controllers and managers (ADR-035 D5, D7).
# Sourced, not run.
#
# A module declares the components it brings in its JSON (D3):
#
#   "controllers": [{ "name": "unifi-controller", "path": "controller/unifi-controller",
#                     "plugsInto": ["switch-manager", "ap-manager"] }],
#   "managers":    [{ "name": "foo-manager", "path": "manager/foo-manager" }]
#
#   cpc_register <module-dir> <module> <instance>   install / update of an instance
#   cpc_unregister <instance>                       delete of an instance
#   cpc_relink                                      every sweep's refresh
#
# Registering runs the component's own install.sh (it builds and links its
# executables into ~/bin, as a standard component's does) and records it in
# config/control-plane.json: one entry per component and module source, listing
# the instances that use it. A name a standard component or another module's
# source already has is refused, naming the owner (D3). Two copies of one module
# share the entry; the links and the entry go with the last instance. A
# controller from a repository whose release is not verified that plugs into a
# foundation manager is a warning, not a refusal (D7).
#
# Environment: CONFIG_DIR (config/), TAPPAAS_BIN (~/bin), TAPPAAS_GCROOTS.

CPC_CONF="${CONFIG_DIR:-/home/tappaas/config}"
CPC_REGISTRY="${CONTROL_PLANE_REGISTRY:-${CPC_CONF}/control-plane.json}"
CPC_BIN="${TAPPAAS_BIN:-/home/tappaas/bin}"

_cpc_info()  { if declare -F info  >/dev/null; then info  "$@"; else echo "[Info] $*"; fi; }
_cpc_debug() { if declare -F debug >/dev/null; then debug "$@"; elif [[ "${TAPPAAS_DEBUG:-0}" == 1 ]]; then echo "[Debug] $*"; fi; }
_cpc_warn()  { if declare -F warn  >/dev/null; then warn  "$@"; else echo "[Warning] $*" >&2; fi; }
_cpc_error() { if declare -F error >/dev/null; then error "$@"; else echo "[Error] $*" >&2; fi; }

_cpc_read() { if [[ -s "${CPC_REGISTRY}" ]]; then jq -c . "${CPC_REGISTRY}" 2>/dev/null || echo '{"version":1,"components":[]}'; else echo '{"version":1,"components":[]}'; fi; }

# _cpc_write <json>: atomically, readable by the console and the self-check.
_cpc_write() {
    local tmp
    mkdir -p "$(dirname "${CPC_REGISTRY}")"
    tmp="$(mktemp "${CPC_REGISTRY}.XXXXXX")" || return 1
    jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.generated = $t' <<<"$1" > "${tmp}" \
        && chmod 644 "${tmp}" && mv -f "${tmp}" "${CPC_REGISTRY}"
}

# _cpc_lock: the registry's lock (shared with control-plane-registry.sh), on fd 8.
_cpc_lock() {
    mkdir -p "$(dirname "${CPC_REGISTRY}")"
    exec 8>"${CPC_REGISTRY}.lock"
    flock -w 60 8 || { _cpc_error "control plane: ${CPC_REGISTRY} is locked by another writer"; return 1; }
}
_cpc_unlock() { flock -u 8 2>/dev/null; exec 8>&-; }

# _cpc_repository <dir>: "<name> <verified>" of the site repository holding <dir>.
_cpc_repository() {
    local dir="$1" name="" status=""
    if [[ -r "${CPC_CONF}/site.json" ]]; then
        name="$(jq -r --arg d "${dir}/" '[.repositories[]? | .path as $p | select($p != null and ($d | startswith($p + "/"))) | .name][0] // empty' "${CPC_CONF}/site.json" 2>/dev/null)"
    fi
    [[ -n "${name}" && -r "${CPC_CONF}/sbom/signatures.json" ]] \
        && status="$(jq -r --arg n "${name}" '[.repositories[]? | select(.name == $n) | .status][0] // empty' "${CPC_CONF}/sbom/signatures.json" 2>/dev/null)"
    printf '%s %s\n' "${name:-unknown}" "$([[ "${status}" == verified ]] && echo true || echo false)"
}

_cpc_language() {
    if [[ -f "$1/tsconfig.json" ]]; then echo typescript
    elif [[ -f "$1/pyproject.toml" ]]; then echo python
    else echo bash; fi
}

# cpc_register <module-dir> <module> <instance>
# Install / update: refuse a taken name, run each component's install.sh, record
# it. On a refusal or a failed install, the components this call registered are
# taken back and it returns 1. A module that declares none: nothing, rc 0.
cpc_register() {
    local mdir="$1" module="$2" instance="$3"
    local mjson="${mdir}/${module}.json" decl reg n=0 i name kind path src plugs owner ownsrc repo verified foundation lang contract
    local -a done_names=()
    [[ -r "${mjson}" ]] || { _cpc_error "control plane: no ${mjson}"; return 1; }
    decl="$(jq -c '[(.controllers // [])[] | . + {kind: "controller"}] + [(.managers // [])[] | . + {kind: "manager", plugsInto: []}]' "${mjson}" 2>/dev/null)" \
        || { _cpc_error "control plane: ${mjson}: controllers/managers are not lists"; return 1; }
    [[ "$(jq length <<<"${decl}")" -gt 0 ]] || return 0
    _cpc_lock || return 1
    reg="$(_cpc_read)"
    foundation="$(jq -c '[.components[]? | select(.module == "tappaas-cicd" and .kind == "manager") | .name]' <<<"${reg}")"
    for i in $(seq 0 $(( $(jq length <<<"${decl}") - 1 ))); do
        name="$(jq -r ".[$i].name" <<<"${decl}")"; kind="$(jq -r ".[$i].kind" <<<"${decl}")"
        path="$(jq -r ".[$i].path" <<<"${decl}")"; plugs="$(jq -c ".[$i].plugsInto // []" <<<"${decl}")"
        src="$(cd "${mdir}/${path}" 2>/dev/null && pwd -P)" \
            || { _cpc_error "control plane: ${module}: ${kind} ${name}: no directory ${path}"; _cpc_rollback; return 1; }
        owner="$(jq -r --arg n "${name}" '[.components[]? | select(.name == $n or ((.aliases // []) | index($n))) | .module][0] // empty' <<<"${reg}")"
        ownsrc="$(jq -r --arg n "${name}" '[.components[]? | select(.name == $n) | .source][0] // empty' <<<"${reg}")"
        if [[ "${owner}" == "tappaas-cicd" ]]; then
            _cpc_error "control plane: ${module}: '${name}' is a standard component of tappaas-cicd — choose another name (ADR-035 D3)"
            _cpc_rollback; return 1
        elif [[ -n "${owner}" && "${ownsrc}" != "${src}" ]]; then
            _cpc_error "control plane: ${module}: '${name}' is registered by module '${owner}' (${ownsrc}) — remove that module first to use this one (ADR-035 D3)"
            _cpc_rollback; return 1
        elif [[ -z "${owner}" && -e "${CPC_BIN}/${name}" && "$(readlink -f "${CPC_BIN}/${name}")" != "${src}"/* \
                 && "$(readlink -f "${CPC_BIN}/${name}")" != /nix/store/* ]]; then
            _cpc_error "control plane: ${module}: ${CPC_BIN}/${name} already exists and is not a registered component — not shadowed (ADR-035 D5)"
            _cpc_rollback; return 1
        fi
        [[ -x "${src}/install.sh" ]] || { _cpc_error "control plane: ${module}: ${name} has no install.sh"; _cpc_rollback; return 1; }
        done_names+=("${name}")
        if ! TAPPAAS_BIN="${CPC_BIN}" bash "${src}/install.sh" > "${TMPDIR:-/tmp}/tappaas-component-${name}.log" 2>&1; then
            _cpc_error "control plane: ${module}: ${name}: install.sh failed — log: ${TMPDIR:-/tmp}/tappaas-component-${name}.log"
            tail -5 "${TMPDIR:-/tmp}/tappaas-component-${name}.log" >&2
            _cpc_rollback; return 1
        fi
        [[ -e "${CPC_BIN}/${name}" ]] || { _cpc_error "control plane: ${module}: ${name}: its install.sh linked no ${CPC_BIN}/${name}"; _cpc_rollback; return 1; }
        read -r repo verified < <(_cpc_repository "${src}")
        lang="$(_cpc_language "${src}")"
        contract="$(jq -c '.contracts // []' "${src}/contract.json" 2>/dev/null || echo '[]')"
        reg="$(jq -c --arg n "${name}" --arg k "${kind}" --arg m "${module}" --arg i "${instance}" --arg s "${src}" \
                 --arg r "${repo}" --argjson v "${verified}" --arg l "${lang}" --argjson p "${plugs}" --argjson c "${contract}" \
                 --arg ver "$(jq -r '.version // ""' "${mjson}")" '
            ([.components[]? | select(.name == $n) | .instances // []][0] // []) as $old
            | .components = ([.components[]? | select(.name != $n)]
                + [{name: $n, kind: $k, module: $m, repository: $r, verified: $v, source: $s, language: $l,
                    package: null, manifest: (if $k == "manager" then "help-json" else null end), aliases: [],
                    plugsInto: $p, contracts: $c, version: $ver, instances: (($old + [$i]) | unique)}])' <<<"${reg}")"
        n=$((n + 1))
        if [[ "${kind}" == controller && "${verified}" != true ]]; then
            local fm; fm="$(jq -r --argjson f "${foundation}" '[.[] | select(. as $x | $f | index($x))] | join(", ")' <<<"${plugs}")"
            [[ -n "${fm}" ]] && _cpc_warn "control plane: ${name} comes from ${repo}, whose release is not verified, and plugs into the foundation's ${fm} (ADR-035 D7)"
        fi
    done
    _cpc_write "${reg}" || { _cpc_error "control plane: could not write ${CPC_REGISTRY}"; _cpc_rollback; return 1; }
    _cpc_unlock
    _cpc_debug "  control plane: ${n} component(s) of ${module} registered for ${instance}: ${done_names[*]}"
}

# Called inside cpc_register under its lock: the registry file was not written,
# so the links this call's install.sh runs made for components the registry
# does not already hold go (an update's existing links stay).
_cpc_rollback() {
    local nm
    for nm in "${done_names[@]}"; do
        jq -e --arg n "${nm}" '.components[]? | select(.name == $n)' "${CPC_REGISTRY}" >/dev/null 2>&1 && continue
        rm -f "${CPC_BIN:?}/${nm}"
    done
    _cpc_unlock
}

# cpc_unregister <instance>: take the instance off every entry; an entry left
# with no instance goes, with its links (name and aliases) and its GC root.
cpc_unregister() {
    local instance="$1" reg gone nm
    [[ -s "${CPC_REGISTRY}" ]] || return 0
    _cpc_lock || return 1
    reg="$(_cpc_read)"
    gone="$(jq -r --arg i "${instance}" '.components[]? | select(.module != "tappaas-cicd" and ((.instances // []) == [$i])) | .name, (.aliases // [])[]' <<<"${reg}")"
    reg="$(jq -c --arg i "${instance}" '
        .components = [.components[]?
            | if .module != "tappaas-cicd" and ((.instances // []) | index($i)) then .instances -= [$i] else . end
            | select(.module == "tappaas-cicd" or ((.instances // []) | length > 0))]' <<<"${reg}")"
    _cpc_write "${reg}" || { _cpc_unlock; _cpc_error "control plane: could not write ${CPC_REGISTRY}"; return 1; }
    _cpc_unlock
    for nm in ${gone}; do
        [[ -L "${CPC_BIN}/${nm}" ]] && rm -f "${CPC_BIN:?}/${nm}"
        rm -f "${TAPPAAS_GCROOTS:-${HOME}/.tappaas-gcroots}/${nm}"
    done
    [[ -n "${gone}" ]] && _cpc_info "  control plane: removed $(tr '\n' ' ' <<<"${gone}")(no instance of their module is left)"
    return 0
}

# cpc_relink: every module component, rebuilt and relinked from its source (as
# refresh does tappaas-cicd's own); a link into a module's controller/ or
# manager/ that no entry owns any more goes. Returns the number that failed.
cpc_relink() {
    local reg failed=0 name src l r owned
    reg="$(_cpc_read)"
    while IFS=$'\t' read -r name src; do
        [[ -n "${name}" ]] || continue
        if [[ ! -x "${src}/install.sh" ]]; then
            _cpc_warn "  control plane: ${name} is registered but ${src} is gone — delete its module, or restore it"
            failed=$((failed + 1)); continue
        fi
        TAPPAAS_BIN="${CPC_BIN}" bash "${src}/install.sh" > "${TMPDIR:-/tmp}/tappaas-component-${name}.log" 2>&1 \
            || { _cpc_warn "  control plane: ${name}: install.sh failed — log: ${TMPDIR:-/tmp}/tappaas-component-${name}.log"; failed=$((failed + 1)); }
    done < <(jq -r '.components[]? | select(.module != "tappaas-cicd") | [.name, .source] | @tsv' <<<"${reg}")
    owned="$(jq -c '[.components[]? | .name, (.aliases // [])[]]' <<<"${reg}")"
    for l in "${CPC_BIN}"/*; do
        [[ -L "${l}" ]] || continue
        r="$(readlink -f "${l}" 2>/dev/null)" || continue
        case "${r}" in */src/foundation/tappaas-cicd/*) continue ;; */controller/*-controller/*|*/manager/*-manager/*) ;; *) continue ;; esac
        jq -e --arg n "${l##*/}" 'index($n)' >/dev/null <<<"${owned}" && continue
        rm -f "${l}" && _cpc_info "  control plane: removed ${l##*/} — no registered component owns it"
    done
    return "${failed}"
}
