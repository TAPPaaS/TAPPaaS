#!/usr/bin/env bash
#
# TAPPaaS — manage a person's single Authentik login and their roles
# (ADR-006, issue #56). One person = one Authentik user; ROLES are group
# memberships, scoped to a variant (client) — except `installer`, which is global.
#
#   Role               Group it maps to            Scope
#   installer          tappaas-installers          global (variant ignored)
#   admin              <scope>-admins              default or --variant
#   user               <scope>-users              default or --variant
#   module-admin:<m>   <scope>-<m>-admins          default or --variant
#
# where <scope> = `tappaas` for the default variant, else the variant name.
#
# Verbs:
#   add    <username> --email <addr> [--name N] [--variant v] [--role R ...] [--no-credential]
#   modify <username> [--variant v] [--add-role R ...] [--remove-role R ...]
#                     [--email E] [--name N] [--credential]
#   delete <username> [--yes]
#   show   <username>
#   list   [--variant v]
#
# Examples:
#   user.sh add lars --email lars@example.org --role admin
#   user.sh add jane --email jane@acme.org --variant acme --role module-admin:nextcloud
#   user.sh modify lars --add-role admin
#   user.sh modify jane --variant acme --remove-role user --add-role admin
#   user.sh delete lars
#   user.sh show lars
#
# Credential delivery (add, or modify --credential): a one-time enrollment LINK
# when the brand has a recovery flow (emailed once SMTP is set up — deferred to
# the SMTP issue), else a generated PASSWORD is set and printed.
#
# Override the CLI for testing: AUTHENTIK_MANAGER="/path/to/wrapper" user.sh …

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

CONFIG_FILE="${CONFIG_DIR}/configuration.json"
AUTHENTIK_MANAGER="${AUTHENTIK_MANAGER:-authentik-manager}"
ROLES_ENSURE="${ROLES_ENSURE:-/home/tappaas/bin/roles-ensure.sh}"

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit "${1:-0}"
}

# ── shared helpers ──────────────────────────────────────────────────────────
scope_prefix() { [[ -z "$1" ]] && echo "tappaas" || echo "$1"; }

require_authentik() {
    ${AUTHENTIK_MANAGER} test >/dev/null 2>&1 \
        || die "authentik-manager cannot reach Authentik (check ~/.authentik-credentials.txt)"
}

validate_variant() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    jq -e --arg v "$v" '(.tappaas.variants // {}) | has($v)' "${CONFIG_FILE}" >/dev/null \
        || die "variant '$v' is not registered (run: variant-manager.sh add $v …)"
}

# Resolve a role spec to its group name (on stdout). With ensure=1, an opt-in
# module-admin group is created so it can be assigned.
# Usage: resolve_role_group <role> <prefix> <variant> <ensure:0|1>
resolve_role_group() {
    local role="$1" prefix="$2" variant="$3" ensure="$4" module
    case "${role}" in
        installer)
            [[ -z "${variant}" ]] || warn "role 'installer' is global — ignoring --variant ${variant}" >&2
            echo "tappaas-installers" ;;
        admin) echo "${prefix}-admins" ;;
        user)  echo "${prefix}-users" ;;
        module-admin:*)
            module="${role#module-admin:}"
            [[ -n "${module}" ]] || die "role 'module-admin:' needs a module (e.g. module-admin:nextcloud)"
            if [[ "${ensure}" -eq 1 ]]; then
                ${AUTHENTIK_MANAGER} group-ensure "${prefix}-${module}-admins" --parent "${prefix}" \
                    --attr "tappaas.variant=${variant}" --attr "tappaas.role=module-admin" \
                    --attr "tappaas.module=${module}" >/dev/null
            fi
            echo "${prefix}-${module}-admins" ;;
        *) die "unknown role '${role}' (expected: installer|admin|user|module-admin:<module>)" ;;
    esac
}

deliver_credential() {
    local username="$1" link
    info "${BOLD}Credential${CL}"
    if link="$(${AUTHENTIK_MANAGER} user-recovery-link "${username}" 2>/dev/null)" && [[ -n "${link}" ]]; then
        info "  ${GN}✓${CL} one-time enrollment link (share securely; expires per Authentik policy):"
        echo "    ${link}"
        info "  (emailed automatically once SMTP is configured — ADR-006 / SMTP issue)"
    else
        warn "  no recovery flow on the brand yet — setting an initial password instead:"
        ${AUTHENTIK_MANAGER} user-set-password "${username}" | sed 's/^/    /'
        info "  share the generated password over a secure channel; the user changes it after login"
    fi
}

# Read-only API helper (for show/list).
_api() {
    local creds="${HOME}/.authentik-credentials.txt"
    [[ -f "${creds}" ]] || die "no ${creds}"
    local url token
    url="$(grep '^url=' "${creds}" | cut -d= -f2-)"
    token="$(grep '^token=' "${creds}" | cut -d= -f2-)"
    curl -fsS -H "Authorization: Bearer ${token}" "${url}/api/v3$1"
}

# ── verbs ───────────────────────────────────────────────────────────────────
cmd_add() {
    local username="" email="" name="" variant="" no_cred=0; local -a roles=()
    while [[ $# -gt 0 ]]; do case "$1" in
        --email) email="${2:-}"; shift 2 ;;
        --name) name="${2:-}"; shift 2 ;;
        --variant) variant="${2:-}"; shift 2 ;;
        --role) roles+=("${2:-}"); shift 2 ;;
        --no-credential) no_cred=1; shift ;;
        -*) die "add: unknown option $1" ;;
        *) if [[ -z "${username}" ]]; then username="$1"; shift; else die "add: unexpected arg $1"; fi ;;
    esac; done
    [[ -n "${username}" ]] || die "add: username required"
    [[ -n "${email}" ]] || die "add: --email required"
    [[ ${#roles[@]} -gt 0 ]] || roles=("user")

    validate_variant "${variant}"; require_authentik
    local prefix; prefix="$(scope_prefix "${variant}")"
    [[ -x "${ROLES_ENSURE}" ]] && { "${ROLES_ENSURE}" --variant "${variant}" >/dev/null || warn "roles-ensure failed; assuming groups exist"; }

    local -a groups=() r
    for r in "${roles[@]}"; do groups+=("$(resolve_role_group "$r" "${prefix}" "${variant}" 1)"); done

    info "${BOLD}add user '${username}'${CL} (scope '${variant:-<default>}', roles: ${roles[*]})"
    local -a a=("user-ensure" "${username}" "--email" "${email}")
    [[ -n "${name}" ]] && a+=("--name" "${name}")
    for g in "${groups[@]}"; do a+=("--group" "${g}"); done
    ${AUTHENTIK_MANAGER} "${a[@]}"
    info "  ${GN}✓${CL} groups: ${groups[*]}"
    [[ "${no_cred}" -eq 1 ]] && { info "  (credential skipped: --no-credential)"; return 0; }
    deliver_credential "${username}"
}

cmd_modify() {
    local username="" email="" name="" variant="" do_cred=0; local -a add_roles=() rm_roles=()
    while [[ $# -gt 0 ]]; do case "$1" in
        --add-role) add_roles+=("${2:-}"); shift 2 ;;
        --remove-role) rm_roles+=("${2:-}"); shift 2 ;;
        --email) email="${2:-}"; shift 2 ;;
        --name) name="${2:-}"; shift 2 ;;
        --variant) variant="${2:-}"; shift 2 ;;
        --credential) do_cred=1; shift ;;
        -*) die "modify: unknown option $1" ;;
        *) if [[ -z "${username}" ]]; then username="$1"; shift; else die "modify: unexpected arg $1"; fi ;;
    esac; done
    [[ -n "${username}" ]] || die "modify: username required"
    { [[ ${#add_roles[@]} -gt 0 || ${#rm_roles[@]} -gt 0 || -n "${email}" || -n "${name}" || "${do_cred}" -eq 1 ]]; } \
        || die "modify: nothing to do (use --add-role/--remove-role/--email/--name/--credential)"

    validate_variant "${variant}"; require_authentik
    local prefix; prefix="$(scope_prefix "${variant}")"
    _api "/core/users/?page_size=1000" | jq -e --arg u "${username}" '.results[]|select(.username==$u)' >/dev/null \
        || die "modify: user '${username}' not found (use 'add' to create)"

    info "${BOLD}modify user '${username}'${CL} (scope '${variant:-<default>}')"
    [[ -x "${ROLES_ENSURE}" && ${#add_roles[@]} -gt 0 ]] && "${ROLES_ENSURE}" --variant "${variant}" >/dev/null 2>&1 || true

    local r g
    for r in "${add_roles[@]}"; do
        g="$(resolve_role_group "$r" "${prefix}" "${variant}" 1)"
        ${AUTHENTIK_MANAGER} user-add-to-groups "${username}" --group "${g}" >/dev/null
        info "  ${GN}+${CL} role ${r} (${g})"
    done
    for r in "${rm_roles[@]}"; do
        g="$(resolve_role_group "$r" "${prefix}" "${variant}" 0)"
        ${AUTHENTIK_MANAGER} user-remove-from-groups "${username}" --group "${g}" >/dev/null
        info "  ${RD:-}${BOLD}-${CL} role ${r} (${g})"
    done
    if [[ -n "${email}" || -n "${name}" ]]; then
        local -a a=("user-ensure" "${username}")
        [[ -n "${email}" ]] && a+=("--email" "${email}")
        [[ -n "${name}" ]] && a+=("--name" "${name}")
        ${AUTHENTIK_MANAGER} "${a[@]}" >/dev/null
        info "  ${GN}✓${CL} updated profile${email:+ email=${email}}${name:+ name=${name}}"
    fi
    [[ "${do_cred}" -eq 1 ]] && deliver_credential "${username}"
    info "  ${GN}✓${CL} done"
}

cmd_delete() {
    local username="" yes=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --yes|-y) yes=1; shift ;;
        -*) die "delete: unknown option $1" ;;
        *) if [[ -z "${username}" ]]; then username="$1"; shift; else die "delete: unexpected arg $1"; fi ;;
    esac; done
    [[ -n "${username}" ]] || die "delete: username required"
    require_authentik
    if [[ "${yes}" -ne 1 ]]; then
        if [[ -t 0 ]]; then
            read -rp "Delete Authentik user '${username}' (login + MFA lost; re-addable)? [y/N] " ans
            [[ "${ans}" =~ ^[Yy] ]] || die "aborted"
        else
            die "delete: refusing to delete non-interactively without --yes"
        fi
    fi
    ${AUTHENTIK_MANAGER} user-delete "${username}"
}

cmd_show() {
    local username="${1:-}"
    [[ -n "${username}" ]] || die "show: username required"
    local u
    u="$(_api "/core/users/?page_size=1000" | jq -c --arg n "${username}" '.results[]|select(.username==$n)')"
    [[ -n "${u}" ]] || die "show: user '${username}' not found"
    info "${BOLD}${username}${CL}"
    echo "${u}" | jq -r '"  email: \(.email)\n  name:  \(.name)\n  active: \(.is_active)\n  roles (groups):"'
    echo "${u}" | jq -r '.groups_obj[]?.name | "    - \(.)"'
}

cmd_list() {
    local variant=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --variant) variant="${2:-}"; shift 2 ;;
        *) die "list: unexpected arg $1" ;;
    esac; done
    local prefix; prefix="$(scope_prefix "${variant}")"
    info "${BOLD}users in scope '${variant:-<default>}' (members of ${prefix}-*)${CL}"
    _api "/core/users/?page_size=1000" | jq -r --arg p "${prefix}-" '
        .results[]
        | . as $u
        | [.groups_obj[]?.name | select(startswith($p) or .=="tappaas-installers")] as $roles
        | select(($roles|length) > 0)
        | "  \($u.username)  <\($u.email)>  [\($roles | join(", "))]"' \
        | sort
}

# ── dispatch ────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || usage 1
VERB="$1"; shift || true
case "${VERB}" in
    add)    cmd_add "$@" ;;
    modify) cmd_modify "$@" ;;
    delete) cmd_delete "$@" ;;
    show)   cmd_show "$@" ;;
    list)   cmd_list "$@" ;;
    --help|-h|help) usage 0 ;;
    *) error "unknown verb '${VERB}'"; usage 1 ;;
esac
