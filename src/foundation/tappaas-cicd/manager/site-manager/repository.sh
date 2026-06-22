#!/usr/bin/env bash
#
# TAPPaaS Repository Manager
#
# Manages module repositories for the TAPPaaS platform. Supports adding,
# removing, modifying, and listing external module repositories that
# contain TAPPaaS modules alongside the main TAPPaaS repository.
#
# Storage: the repository list is the canonical `.repositories` array in
# site.json (ADR-007). Reads fall back to the legacy
# configuration.json .tappaas.repositories while both files coexist; writes
# always target site.json .repositories.
#
# Usage: repository.sh <command> [options]
#
# Commands:
#   add <url> [--branch <branch>]      Add a new module repository
#   remove <name> [--force]            Remove a module repository
#   modify <name> [--url <url>] [--branch <branch>]  Modify a repository
#   list                               List all tracked repositories
#
# Examples:
#   repository.sh add github.com/someone/tappaas-community
#   repository.sh add github.com/someone/tappaas-community --branch develop
#   repository.sh remove tappaas-community
#   repository.sh modify tappaas-community --branch stable
#   repository.sh list
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
# CONFIG_DIR is overridable from the environment so tests can point at an
# isolated fixture dir (default: the live config dir).
CONFIG_DIR="${CONFIG_DIR:-/home/tappaas/config}"
readonly CONFIG_DIR
# Canonical repository store: site.json .repositories (ADR-007). The legacy
# configuration.json .tappaas.repositories is only consulted as a read fallback.
readonly SITE_FILE="${CONFIG_DIR}/site.json"
readonly CONFIG_FILE="${CONFIG_DIR}/configuration.json"
readonly CLONE_DIR="/home/tappaas"

# ── Logging ──────────────────────────────────────────────────────────

# Color definitions
readonly YW=$'\033[33m'
readonly RD=$'\033[01;31m'
readonly GN=$'\033[1;92m'
readonly DGN=$'\033[32m'
readonly BL=$'\033[36m'
readonly CL=$'\033[m'
readonly BOLD=$'\033[1m'

info()  { echo -e "${DGN}$*${CL}"; }
warn()  { echo -e "${YW}[WARN]${CL} $*"; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <command> [options]

Manage TAPPaaS module repositories.

Commands:
    add <url> [--branch <branch>] [--managed full|tracked] [--catalog <path>]
        Add a new module repository. The repository is cloned into
        ${CLONE_DIR}/<name>/ where <name> is derived from the URL.
        Default branch: stable.
        --managed full     (default) repo carries TAPPaaS modules; its module
                           catalog is validated. --catalog overrides the catalog
                           path (default: src/module-catalog.json, legacy
                           src/modules.json accepted).
        --managed tracked  register the repo without catalog requirements.

    remove <name> [--force]
        Remove a module repository. Blocked if installed modules
        depend on the repository (use --force to override).

    modify <name> [--url <new-url>] [--branch <new-branch>]
        Modify a repository's URL and/or branch. If only changing
        branch, fetches and checks out the new branch in place.
        If changing URL, re-clones and updates module locations.

    list
        List all tracked repositories with name, URL, branch,
        and available module count.

Options:
    -h, --help    Show this help message

Examples:
    ${SCRIPT_NAME} add github.com/someone/tappaas-community
    ${SCRIPT_NAME} add github.com/someone/tappaas-community --branch develop
    ${SCRIPT_NAME} remove tappaas-community
    ${SCRIPT_NAME} modify tappaas-community --branch stable
    ${SCRIPT_NAME} modify tappaas-community --url github.com/other/repo --branch main
    ${SCRIPT_NAME} list
EOF
}

# ── Helpers ──────────────────────────────────────────────────────────

# Derive repository name from URL (last path segment, strip .git suffix)
# Arguments: <url>
# Outputs: repository name
derive_repo_name() {
    local url="$1"
    local name
    name="${url##*/}"
    name="${name%.git}"
    echo "${name}"
}

# Check that site.json exists and is valid (the canonical repository store).
validate_config() {
    if [[ ! -f "${SITE_FILE}" ]]; then
        die "Site configuration file not found: ${SITE_FILE}"
    fi
    if ! jq empty "${SITE_FILE}" 2>/dev/null; then
        die "Invalid JSON in site configuration file: ${SITE_FILE}"
    fi
}

# Echo the repositories JSON array. Reads site.json .repositories if present and
# a non-empty array; otherwise falls back to configuration.json
# .tappaas.repositories; otherwise []. Read-only dual-state helper for list/get.
get_repositories() {
    local arr=""
    if [[ -f "${SITE_FILE}" ]]; then
        arr=$(jq -c '.repositories | select(type == "array" and length > 0)' "${SITE_FILE}" 2>/dev/null) || arr=""
    fi
    if [[ -z "${arr}" && -f "${CONFIG_FILE}" ]]; then
        arr=$(jq -c '.tappaas.repositories | select(type == "array" and length > 0)' "${CONFIG_FILE}" 2>/dev/null) || arr=""
    fi
    [[ -n "${arr}" ]] || arr="[]"
    printf '%s\n' "${arr}"
}

# Get a repository entry by name (reads site.json, falls back to config).
# Arguments: <name>
# Outputs: JSON object or "null"
get_repo_by_name() {
    local name="$1"
    get_repositories | jq -r --arg n "${name}" \
        'map(select(.name == $n)) | .[0] // "null"' 2>/dev/null
}

# Get all installed modules whose location is under a given path
# Arguments: <repo-path>
# Outputs: module names (one per line)
get_modules_in_repo() {
    local repo_path="$1"
    for config_file in "${CONFIG_DIR}"/*.json; do
        [[ -f "${config_file}" ]] || continue
        local module_name
        module_name=$(basename "${config_file}" .json)

        # Skip non-module files
        case "${module_name}" in
            configuration|site|zones|module-fields) continue ;;
        esac
        # Skip .orig backup files
        [[ "${config_file}" == *.orig ]] && continue

        local location
        location=$(jq -r '.location // empty' "${config_file}" 2>/dev/null)
        if [[ -n "${location}" && "${location}" == "${repo_path}"* ]]; then
            echo "${module_name}"
        fi
    done
}

# Validate a remote git URL is reachable
# Arguments: <url> (without https:// prefix)
# Returns: 0 if reachable, 1 otherwise
validate_git_url() {
    local url="$1"
    if git ls-remote --exit-code "https://${url}" HEAD >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Resolve a repository's module-catalog file path (issue #305).
# Prefers the current name (src/module-catalog.json) and falls back to the legacy
# name (src/modules.json) so external module repos that have not migrated yet
# keep working. Echoes the path of whichever exists, else the preferred (new)
# path so callers can emit a clear "not found" message.
# Arguments: <repo-path>
repo_catalog_file() {
    local repo_path="$1"
    if [[ -f "${repo_path}/src/module-catalog.json" ]]; then
        echo "${repo_path}/src/module-catalog.json"
    elif [[ -f "${repo_path}/src/modules.json" ]]; then
        echo "${repo_path}/src/modules.json"
    else
        echo "${repo_path}/src/module-catalog.json"
    fi
}

# Count modules in a repository's module catalog
# Arguments: <repo-path>
# Outputs: module count
count_repo_modules() {
    local repo_path="$1"
    local modules_json; modules_json="$(repo_catalog_file "${repo_path}")"
    if [[ -f "${modules_json}" ]]; then
        jq '[
            (.foundationModules // []),
            (.applicationModules // []),
            (.proxmoxTemplates // []),
            (.testModules // [])
        ] | add | length' "${modules_json}" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# List module names from a repository's module catalog
# Arguments: <repo-path>
# Outputs: module names (one per line)
list_repo_modules() {
    local repo_path="$1"
    local modules_json; modules_json="$(repo_catalog_file "${repo_path}")"
    if [[ -f "${modules_json}" ]]; then
        jq -r '[
            (.foundationModules // []),
            (.applicationModules // []),
            (.proxmoxTemplates // []),
            (.testModules // [])
        ] | add | .[].moduleName' "${modules_json}" 2>/dev/null
    fi
}

# Get all VMIDs from a repository's module catalog
# Arguments: <repo-path>
# Outputs: VMIDs (one per line)
get_repo_vmids() {
    local repo_path="$1"
    local modules_json; modules_json="$(repo_catalog_file "${repo_path}")"
    if [[ -f "${modules_json}" ]]; then
        jq -r '[
            (.foundationModules // []),
            (.applicationModules // []),
            (.proxmoxTemplates // []),
            (.testModules // [])
        ] | add | .[].vmid' "${modules_json}" 2>/dev/null
    fi
}

# Update site.json atomically using jq (canonical repository store).
# Arguments: <jq-filter> [jq-args...]
update_config() {
    local filter="$1"
    shift
    local tmp_file
    tmp_file=$(mktemp)
    if jq "$@" "${filter}" "${SITE_FILE}" > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${SITE_FILE}"
    else
        rm -f "${tmp_file}"
        die "Failed to update site.json"
    fi
}

# ── Commands ─────────────────────────────────────────────────────────

# Add a new repository
cmd_add() {
    local url=""
    local branch="stable"
    local managed="full"          # ADR-004: full | tracked
    local catalog=""              # ADR-004: catalog path; defaults per managed type

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --branch)
                if [[ -z "${2:-}" ]]; then
                    die "Option --branch requires a value"
                fi
                branch="$2"
                shift 2
                ;;
            --managed)
                if [[ -z "${2:-}" ]]; then
                    die "Option --managed requires a value (full|tracked)"
                fi
                case "$2" in
                    full|tracked) managed="$2" ;;
                    *) die "Invalid --managed value '$2' (expected: full | tracked)" ;;
                esac
                shift 2
                ;;
            --catalog)
                if [[ -z "${2:-}" ]]; then
                    die "Option --catalog requires a value"
                fi
                catalog="$2"
                shift 2
                ;;
            --*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -n "${url}" ]]; then
                    die "Unexpected argument: $1 (URL already set to '${url}')"
                fi
                url="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${url}" ]]; then
        die "Repository URL is required. Usage: ${SCRIPT_NAME} add <url> [--branch <branch>] [--managed full|tracked] [--catalog <path>]"
    fi

    # ADR-004 defaults: a 'full' repo carries a catalog (default src/module-catalog.json);
    # a 'tracked' repo has no catalog requirement.
    if [[ "${managed}" == "full" && -z "${catalog}" ]]; then
        catalog="src/module-catalog.json"
    fi
    if [[ "${managed}" == "tracked" && -n "${catalog}" ]]; then
        die "--catalog is not valid with --managed tracked (tracked repos have no catalog)"
    fi

    local name
    name=$(derive_repo_name "${url}")
    local repo_path="${CLONE_DIR}/${name}"

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Repository Add: ${BL}${name}${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Validate prerequisites ───────────────────────────────
    info "\n${BOLD}Step 1: Validate prerequisites${CL}"
    validate_config

    # Check name doesn't conflict with existing repos
    local existing
    existing=$(get_repo_by_name "${name}")
    if [[ "${existing}" != "null" ]]; then
        die "Repository '${name}' already exists in configuration. Use 'modify' to change it."
    fi

    # Check clone directory doesn't already exist
    if [[ -d "${repo_path}" ]]; then
        die "Directory already exists: ${repo_path}"
    fi

    info "  ${GN}✓${CL} Prerequisites validated"

    # ── Step 2: Validate remote URL ──────────────────────────────────
    info "\n${BOLD}Step 2: Validate remote repository${CL}"

    info "  Checking URL: https://${url} ..."
    if ! validate_git_url "${url}"; then
        die "Cannot reach repository: https://${url}"
    fi
    info "  ${GN}✓${CL} Repository is reachable"

    # ── Step 3: Clone repository ─────────────────────────────────────
    info "\n${BOLD}Step 3: Clone repository${CL}"

    info "  Cloning to ${repo_path} ..."
    if ! git clone "https://${url}" "${repo_path}" 2>&1 | sed 's/^/  /'; then
        # Clean up partial clone
        rm -rf "${repo_path}"
        die "Failed to clone repository"
    fi

    info "  Checking out branch '${branch}' ..."
    if ! (cd "${repo_path}" && git checkout "${branch}" 2>&1 | sed 's/^/  /'); then
        rm -rf "${repo_path}"
        die "Failed to checkout branch '${branch}'"
    fi
    info "  ${GN}✓${CL} Repository cloned successfully"

    # ── Step 4: Validate repository structure ────────────────────────
    info "\n${BOLD}Step 4: Validate repository structure${CL}"

    if [[ "${managed}" == "tracked" ]]; then
        # ADR-004: a 'tracked' repo is registered without catalog requirements.
        info "  ${GN}✓${CL} managed=tracked — skipping module-catalog validation"
    else
        # 'full' repo: a valid module catalog is required. A custom --catalog path
        # overrides the default new/legacy lookup.
        local modules_json
        if [[ -n "${catalog}" && -f "${repo_path}/${catalog}" ]]; then
            modules_json="${repo_path}/${catalog}"
        else
            modules_json="$(repo_catalog_file "${repo_path}")"
        fi
        if [[ ! -f "${modules_json}" ]]; then
            rm -rf "${repo_path}"
            die "Repository does not contain ${catalog:-src/module-catalog.json (or legacy src/modules.json)} — not a valid TAPPaaS module repository (use --managed tracked for a non-module repo)"
        fi

        if ! jq empty "${modules_json}" 2>/dev/null; then
            rm -rf "${repo_path}"
            die "Invalid JSON in ${modules_json#"${repo_path}/"}"
        fi

        # Record the catalog path actually found (relative to repo root) so the
        # site.json entry points at the real file.
        catalog="${modules_json#"${repo_path}/"}"

        local module_count
        module_count=$(count_repo_modules "${repo_path}")
        info "  ${GN}✓${CL} Found ${module_count} module(s) in ${catalog}"
    fi

    # ── Step 5: Check for conflicts ──────────────────────────────────
    info "\n${BOLD}Step 5: Check for conflicts${CL}"

    # Check VMID conflicts
    local new_vmids
    new_vmids=$(get_repo_vmids "${repo_path}")
    local has_conflicts=false

    # Snapshot the existing repositories (site.json, config fallback) once.
    local repos_json
    repos_json=$(get_repositories)
    local repo_count
    repo_count=$(echo "${repos_json}" | jq 'length' 2>/dev/null || echo "0")

    # Get VMIDs from all existing repos
    for i in $(seq 0 $(( repo_count - 1 ))); do
        local existing_path
        existing_path=$(echo "${repos_json}" | jq -r ".[${i}].path")
        local existing_name
        existing_name=$(echo "${repos_json}" | jq -r ".[${i}].name")
        local existing_vmids
        existing_vmids=$(get_repo_vmids "${existing_path}")

        for vmid in ${new_vmids}; do
            if echo "${existing_vmids}" | grep -qx "${vmid}"; then
                warn "  VMID ${vmid} conflicts with repository '${existing_name}'"
                has_conflicts=true
            fi
        done
    done

    # Check module name conflicts
    local new_modules
    new_modules=$(list_repo_modules "${repo_path}")
    for i in $(seq 0 $(( repo_count - 1 ))); do
        local existing_path
        existing_path=$(echo "${repos_json}" | jq -r ".[${i}].path")
        local existing_name
        existing_name=$(echo "${repos_json}" | jq -r ".[${i}].name")
        local existing_modules
        existing_modules=$(list_repo_modules "${existing_path}")

        for mod in ${new_modules}; do
            if echo "${existing_modules}" | grep -qx "${mod}"; then
                warn "  Module '${mod}' conflicts with repository '${existing_name}'"
                has_conflicts=true
            fi
        done
    done

    if [[ "${has_conflicts}" == "true" ]]; then
        warn "  Conflicts detected (see warnings above). Proceeding anyway."
    else
        info "  ${GN}✓${CL} No conflicts detected"
    fi

    # ── Step 6: Update configuration ─────────────────────────────────
    info "\n${BOLD}Step 6: Update configuration${CL}"

    # Build the entry (ADR-004): always include managed; include catalog only
    # for 'full' repos (tracked repos carry no catalog).
    local tmp_file
    tmp_file=$(mktemp)
    if jq --arg name "${name}" --arg url "${url}" --arg branch "${branch}" \
          --arg path "${repo_path}" --arg managed "${managed}" --arg catalog "${catalog}" \
        '.repositories = (.repositories // []) + [
            ({"name": $name, "url": $url, "branch": $branch, "path": $path, "managed": $managed})
            + (if $managed == "full" then {"catalog": $catalog} else {} end)
         ]' \
        "${SITE_FILE}" > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${SITE_FILE}"
    else
        rm -f "${tmp_file}"
        die "Failed to update site.json"
    fi

    info "  ${GN}✓${CL} Repository added to site.json"

    # ── Done ─────────────────────────────────────────────────────────
    echo ""
    info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${GN}${BOLD}║  Repository '${name}' added successfully        ${CL}"
    info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
    echo ""
    info "Available modules:"
    list_repo_modules "${repo_path}" | sed 's/^/  - /'
}

# Remove a repository
cmd_remove() {
    local name=""
    local force=false

    # Parse arguments
    for arg in "$@"; do
        case "${arg}" in
            --force) force=true ;;
            --*)     die "Unknown option: ${arg}" ;;
            *)
                if [[ -n "${name}" ]]; then
                    die "Unexpected argument: ${arg} (name already set to '${name}')"
                fi
                name="${arg}"
                ;;
        esac
    done

    if [[ -z "${name}" ]]; then
        die "Repository name is required. Usage: ${SCRIPT_NAME} remove <name> [--force]"
    fi

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Repository Remove: ${BL}${name}${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Validate prerequisites ───────────────────────────────
    info "\n${BOLD}Step 1: Validate prerequisites${CL}"
    validate_config

    local repo_entry
    repo_entry=$(get_repo_by_name "${name}")
    if [[ "${repo_entry}" == "null" ]]; then
        die "Repository '${name}' not found in configuration"
    fi

    local repo_path
    repo_path=$(echo "${repo_entry}" | jq -r '.path')
    info "  Repository path: ${repo_path}"
    info "  ${GN}✓${CL} Repository found in configuration"

    # ── Step 2: Check for installed modules ──────────────────────────
    info "\n${BOLD}Step 2: Check for installed modules${CL}"

    local installed_modules
    installed_modules=$(get_modules_in_repo "${repo_path}")
    local module_count=0

    if [[ -n "${installed_modules}" ]]; then
        module_count=$(echo "${installed_modules}" | wc -l)
    fi

    if [[ "${module_count}" -gt 0 ]]; then
        error "  ${module_count} installed module(s) depend on this repository:"
        echo "${installed_modules}" | sed 's/^/    - /'
        if [[ "${force}" == "true" ]]; then
            warn "  Proceeding with removal despite installed modules (--force)"
        else
            die "Cannot remove repository with installed modules. Use --force to override."
        fi
    else
        info "  ${GN}✓${CL} No installed modules depend on this repository"
    fi

    # ── Step 3: Remove repository directory ──────────────────────────
    info "\n${BOLD}Step 3: Remove repository directory${CL}"

    if [[ -d "${repo_path}" ]]; then
        rm -rf "${repo_path}"
        info "  ${GN}✓${CL} Removed ${repo_path}"
    else
        warn "  Directory not found: ${repo_path} (already removed?)"
    fi

    # ── Step 4: Update configuration ─────────────────────────────────
    info "\n${BOLD}Step 4: Update configuration${CL}"

    local tmp_file
    tmp_file=$(mktemp)
    if jq --arg name "${name}" \
        '.repositories = [(.repositories // [])[] | select(.name != $name)]' \
        "${SITE_FILE}" > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${SITE_FILE}"
    else
        rm -f "${tmp_file}"
        die "Failed to update site.json"
    fi

    info "  ${GN}✓${CL} Repository removed from site.json"

    # ── Done ─────────────────────────────────────────────────────────
    echo ""
    info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${GN}${BOLD}║  Repository '${name}' removed successfully      ${CL}"
    info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
}

# Modify a repository
cmd_modify() {
    local name=""
    local new_url=""
    local new_branch=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                if [[ -z "${2:-}" ]]; then
                    die "Option --url requires a value"
                fi
                new_url="$2"
                shift 2
                ;;
            --branch)
                if [[ -z "${2:-}" ]]; then
                    die "Option --branch requires a value"
                fi
                new_branch="$2"
                shift 2
                ;;
            --*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -n "${name}" ]]; then
                    die "Unexpected argument: $1 (name already set to '${name}')"
                fi
                name="$1"
                shift
                ;;
        esac
    done

    if [[ -z "${name}" ]]; then
        die "Repository name is required. Usage: ${SCRIPT_NAME} modify <name> [--url <url>] [--branch <branch>]"
    fi

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Repository Modify: ${BL}${name}${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"

    # ── Step 1: Validate prerequisites ───────────────────────────────
    info "\n${BOLD}Step 1: Validate prerequisites${CL}"
    validate_config

    local repo_entry
    repo_entry=$(get_repo_by_name "${name}")
    if [[ "${repo_entry}" == "null" ]]; then
        die "Repository '${name}' not found in configuration"
    fi

    local current_url current_branch current_path
    current_url=$(echo "${repo_entry}" | jq -r '.url')
    current_branch=$(echo "${repo_entry}" | jq -r '.branch')
    current_path=$(echo "${repo_entry}" | jq -r '.path')

    info "  Current URL:    ${current_url}"
    info "  Current branch: ${current_branch}"
    info "  Current path:   ${current_path}"

    # If no changes requested, just show info
    if [[ -z "${new_url}" && -z "${new_branch}" ]]; then
        info "\n  No changes requested. Use --url and/or --branch to modify."
        return 0
    fi

    info "  ${GN}✓${CL} Repository found in configuration"

    # ── Branch-only change ───────────────────────────────────────────
    if [[ -z "${new_url}" && -n "${new_branch}" ]]; then
        info "\n${BOLD}Step 2: Switch branch${CL}"

        if [[ "${new_branch}" == "${current_branch}" ]]; then
            info "  Already on branch '${new_branch}' — nothing to do"
            return 0
        fi

        if [[ ! -d "${current_path}" ]]; then
            die "Repository directory not found: ${current_path}"
        fi

        info "  Fetching from origin..."
        if ! (cd "${current_path}" && git fetch origin 2>&1 | sed 's/^/  /'); then
            die "Failed to fetch from origin"
        fi

        info "  Checking out branch '${new_branch}'..."
        if ! (cd "${current_path}" && git checkout "${new_branch}" 2>&1 | sed 's/^/  /'); then
            die "Failed to checkout branch '${new_branch}'"
        fi

        info "  Pulling latest changes..."
        if ! (cd "${current_path}" && git pull origin "${new_branch}" 2>&1 | sed 's/^/  /'); then
            warn "  Failed to pull — branch may be checked out but not up-to-date"
        fi

        # Update config
        info "\n${BOLD}Step 3: Update configuration${CL}"
        local tmp_file
        tmp_file=$(mktemp)
        if jq --arg name "${name}" --arg branch "${new_branch}" \
            '.repositories = [(.repositories // [])[] | if .name == $name then .branch = $branch else . end]' \
            "${SITE_FILE}" > "${tmp_file}" 2>/dev/null; then
            mv "${tmp_file}" "${SITE_FILE}"
        else
            rm -f "${tmp_file}"
            die "Failed to update site.json"
        fi

        info "  ${GN}✓${CL} Configuration updated"

        echo ""
        info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
        info "${GN}${BOLD}║  Repository '${name}' branch changed to '${new_branch}'  ${CL}"
        info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
        return 0
    fi

    # ── URL change (with optional branch change) ─────────────────────
    local target_branch="${new_branch:-${current_branch}}"

    info "\n${BOLD}Step 2: Validate new repository${CL}"

    info "  Checking URL: https://${new_url} ..."
    if ! validate_git_url "${new_url}"; then
        die "Cannot reach repository: https://${new_url}"
    fi
    info "  ${GN}✓${CL} New repository is reachable"

    # ── Step 3: Check installed modules ──────────────────────────────
    info "\n${BOLD}Step 3: Check installed modules${CL}"

    local installed_modules
    installed_modules=$(get_modules_in_repo "${current_path}")

    if [[ -n "${installed_modules}" ]]; then
        info "  Installed modules from this repository:"
        echo "${installed_modules}" | sed 's/^/    - /'

        # Clone new repo to temp dir and validate it has the same modules
        info "  Validating new repository has all installed modules..."
        local tmp_clone
        tmp_clone=$(mktemp -d)
        if ! git clone "https://${new_url}" "${tmp_clone}/repo" >/dev/null 2>&1; then
            rm -rf "${tmp_clone}"
            die "Failed to clone new repository for validation"
        fi
        if ! (cd "${tmp_clone}/repo" && git checkout "${target_branch}" >/dev/null 2>&1); then
            rm -rf "${tmp_clone}"
            die "Failed to checkout branch '${target_branch}' in new repository"
        fi

        local new_repo_modules
        new_repo_modules=$(list_repo_modules "${tmp_clone}/repo")
        local missing_modules=false

        for mod in ${installed_modules}; do
            if ! echo "${new_repo_modules}" | grep -qx "${mod}"; then
                error "  Module '${mod}' not found in new repository"
                missing_modules=true
            fi
        done

        rm -rf "${tmp_clone}"

        if [[ "${missing_modules}" == "true" ]]; then
            die "New repository is missing installed modules — cannot proceed"
        fi
        info "  ${GN}✓${CL} All installed modules found in new repository"
    else
        info "  No installed modules from this repository"
    fi

    # ── Step 4: Replace repository ───────────────────────────────────
    info "\n${BOLD}Step 4: Replace repository${CL}"

    local new_name
    new_name=$(derive_repo_name "${new_url}")
    local new_path="${CLONE_DIR}/${new_name}"

    # Remove old clone
    if [[ -d "${current_path}" ]]; then
        info "  Removing old clone: ${current_path}"
        rm -rf "${current_path}"
    fi

    # Clone new repo
    info "  Cloning new repository to ${new_path} ..."
    if ! git clone "https://${new_url}" "${new_path}" 2>&1 | sed 's/^/  /'; then
        die "Failed to clone new repository"
    fi

    info "  Checking out branch '${target_branch}'..."
    if ! (cd "${new_path}" && git checkout "${target_branch}" 2>&1 | sed 's/^/  /'); then
        die "Failed to checkout branch '${target_branch}'"
    fi

    info "  ${GN}✓${CL} New repository cloned"

    # ── Step 5: Update module locations ──────────────────────────────
    if [[ -n "${installed_modules}" ]]; then
        info "\n${BOLD}Step 5: Update module locations${CL}"

        for mod in ${installed_modules}; do
            local mod_config="${CONFIG_DIR}/${mod}.json"
            if [[ -f "${mod_config}" ]]; then
                local old_location
                old_location=$(jq -r '.location // empty' "${mod_config}")
                if [[ -n "${old_location}" ]]; then
                    # Replace old repo path prefix with new repo path
                    local relative_path="${old_location#"${current_path}"}"
                    local new_location="${new_path}${relative_path}"
                    local tmp_file
                    tmp_file=$(mktemp)
                    if jq --arg loc "${new_location}" '.location = $loc' "${mod_config}" > "${tmp_file}" 2>/dev/null; then
                        mv "${tmp_file}" "${mod_config}"
                        info "  ${GN}✓${CL} Updated location for '${mod}'"
                    else
                        rm -f "${tmp_file}"
                        warn "  Failed to update location for '${mod}'"
                    fi
                fi
            fi
        done
    fi

    # ── Step 6: Update configuration ─────────────────────────────────
    info "\n${BOLD}Step 6: Update configuration${CL}"

    local tmp_file
    tmp_file=$(mktemp)
    if jq --arg name "${name}" --arg new_url "${new_url}" --arg branch "${target_branch}" \
        --arg new_name "${new_name}" --arg new_path "${new_path}" \
        '.repositories = [(.repositories // [])[] | if .name == $name then .name = $new_name | .url = $new_url | .branch = $branch | .path = $new_path else . end]' \
        "${SITE_FILE}" > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${SITE_FILE}"
    else
        rm -f "${tmp_file}"
        die "Failed to update site.json"
    fi

    info "  ${GN}✓${CL} Configuration updated"

    echo ""
    info "${GN}${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${GN}${BOLD}║  Repository '${name}' modified successfully     ${CL}"
    info "${GN}${BOLD}╚══════════════════════════════════════════════╝${CL}"
}

# List all repositories
cmd_list() {
    validate_config

    info "${BOLD}╔══════════════════════════════════════════════╗${CL}"
    info "${BOLD}║  TAPPaaS Repositories                        ${CL}"
    info "${BOLD}╚══════════════════════════════════════════════╝${CL}"
    echo ""

    local repos_json
    repos_json=$(get_repositories)
    local repo_count
    repo_count=$(echo "${repos_json}" | jq 'length' 2>/dev/null || echo "0")

    if [[ "${repo_count}" -eq 0 ]]; then
        info "  No repositories configured."
        return 0
    fi

    printf "  ${BOLD}%-20s %-45s %-12s %-8s${CL}\n" "Name" "URL" "Branch" "Modules"
    printf "  %-20s %-45s %-12s %-8s\n" "----" "---" "------" "-------"

    for i in $(seq 0 $(( repo_count - 1 ))); do
        local r_name r_url r_branch r_path r_modules
        r_name=$(echo "${repos_json}" | jq -r ".[${i}].name")
        r_url=$(echo "${repos_json}" | jq -r ".[${i}].url")
        r_branch=$(echo "${repos_json}" | jq -r ".[${i}].branch")
        r_path=$(echo "${repos_json}" | jq -r ".[${i}].path")

        if [[ -d "${r_path}" ]]; then
            r_modules=$(count_repo_modules "${r_path}")
        else
            r_modules="N/A"
        fi

        printf "  %-20s %-45s %-12s %-8s\n" "${r_name}" "${r_url}" "${r_branch}" "${r_modules}"
    done

    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
    # Handle help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    # Validate command
    if [[ -z "${1:-}" ]]; then
        error "Command is required"
        usage
        exit 1
    fi

    local command="$1"
    shift

    # Check for required commands
    if ! command -v jq &>/dev/null; then
        die "Required command 'jq' not found. Please install it."
    fi
    if ! command -v git &>/dev/null; then
        die "Required command 'git' not found. Please install it."
    fi

    case "${command}" in
        add)    cmd_add "$@" ;;
        remove) cmd_remove "$@" ;;
        modify) cmd_modify "$@" ;;
        list)   cmd_list ;;
        -h|--help) usage; exit 0 ;;
        *)
            error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
