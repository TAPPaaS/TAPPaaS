#!/usr/bin/env bash
#
# TAPPaaS Repository Manager
#
# Manages module repositories for the TAPPaaS platform. Supports adding,
# removing, modifying, and listing external module repositories that
# contain TAPPaaS modules alongside the main TAPPaaS repository.
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
readonly CONFIG_DIR="/home/tappaas/config"
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
    add <url> [--branch <branch>]
        Add a new module repository. The repository is cloned into
        ${CLONE_DIR}/<name>/ where <name> is derived from the URL.
        Default branch: main.

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

# Check that configuration.json exists and is valid
validate_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        die "Configuration file not found: ${CONFIG_FILE}"
    fi
    if ! jq empty "${CONFIG_FILE}" 2>/dev/null; then
        die "Invalid JSON in configuration file: ${CONFIG_FILE}"
    fi
}

# Get a repository entry from configuration.json by name
# Arguments: <name>
# Outputs: JSON object or "null"
get_repo_by_name() {
    local name="$1"
    jq -r --arg n "${name}" \
        '.tappaas.repositories // [] | map(select(.name == $n)) | .[0] // "null"' \
        "${CONFIG_FILE}" 2>/dev/null
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
            configuration|zones|module-fields) continue ;;
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

# Count modules in a repository's src/modules.json
# Arguments: <repo-path>
# Outputs: module count
count_repo_modules() {
    local repo_path="$1"
    local modules_json="${repo_path}/src/modules.json"
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

# List module names from a repository's src/modules.json
# Arguments: <repo-path>
# Outputs: module names (one per line)
list_repo_modules() {
    local repo_path="$1"
    local modules_json="${repo_path}/src/modules.json"
    if [[ -f "${modules_json}" ]]; then
        jq -r '[
            (.foundationModules // []),
            (.applicationModules // []),
            (.proxmoxTemplates // []),
            (.testModules // [])
        ] | add | .[].moduleName' "${modules_json}" 2>/dev/null
    fi
}

# Get all VMIDs from a repository's src/modules.json
# Arguments: <repo-path>
# Outputs: VMIDs (one per line)
get_repo_vmids() {
    local repo_path="$1"
    local modules_json="${repo_path}/src/modules.json"
    if [[ -f "${modules_json}" ]]; then
        jq -r '[
            (.foundationModules // []),
            (.applicationModules // []),
            (.proxmoxTemplates // []),
            (.testModules // [])
        ] | add | .[].vmid' "${modules_json}" 2>/dev/null
    fi
}

# Update configuration.json atomically using jq
# Arguments: <jq-filter> [jq-args...]
update_config() {
    local filter="$1"
    shift
    local tmp_file
    tmp_file=$(mktemp)
    if jq "$@" "${filter}" "${CONFIG_FILE}" > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${CONFIG_FILE}"
    else
        rm -f "${tmp_file}"
        die "Failed to update configuration.json"
    fi
}

# ── Commands ─────────────────────────────────────────────────────────

# Add a new repository
cmd_add() {
    local url=""
    local branch="main"

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
        die "Repository URL is required. Usage: ${SCRIPT_NAME} add <url> [--branch <branch>]"
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

    local modules_json="${repo_path}/src/modules.json"
    if [[ ! -f "${modules_json}" ]]; then
        rm -rf "${repo_path}"
        die "Repository does not contain src/modules.json — not a valid TAPPaaS module repository"
    fi

    if ! jq empty "${modules_json}" 2>/dev/null; then
        rm -rf "${repo_path}"
        die "Invalid JSON in src/modules.json"
    fi

    local module_count
    module_count=$(count_repo_modules "${repo_path}")
    info "  ${GN}✓${CL} Found ${module_count} module(s) in src/modules.json"

    # ── Step 5: Check for conflicts ──────────────────────────────────
    info "\n${BOLD}Step 5: Check for conflicts${CL}"

    # Check VMID conflicts
    local new_vmids
    new_vmids=$(get_repo_vmids "${repo_path}")
    local has_conflicts=false

    # Get VMIDs from all existing repos
    local repo_count
    repo_count=$(jq '.tappaas.repositories // [] | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
    for i in $(seq 0 $(( repo_count - 1 ))); do
        local existing_path
        existing_path=$(jq -r ".tappaas.repositories[${i}].path" "${CONFIG_FILE}")
        local existing_name
        existing_name=$(jq -r ".tappaas.repositories[${i}].name" "${CONFIG_FILE}")
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
        existing_path=$(jq -r ".tappaas.repositories[${i}].path" "${CONFIG_FILE}")
        local existing_name
        existing_name=$(jq -r ".tappaas.repositories[${i}].name" "${CONFIG_FILE}")
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

    local tmp_file
    tmp_file=$(mktemp)
    if jq --arg name "${name}" --arg url "${url}" --arg branch "${branch}" --arg path "${repo_path}" \
        '.tappaas.repositories = (.tappaas.repositories // []) + [{"name": $name, "url": $url, "branch": $branch, "path": $path}]' \
        "${CONFIG_FILE}" > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${CONFIG_FILE}"
    else
        rm -f "${tmp_file}"
        die "Failed to update configuration.json"
    fi

    info "  ${GN}✓${CL} Repository added to configuration.json"

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
        '.tappaas.repositories = [.tappaas.repositories[] | select(.name != $name)]' \
        "${CONFIG_FILE}" > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${CONFIG_FILE}"
    else
        rm -f "${tmp_file}"
        die "Failed to update configuration.json"
    fi

    info "  ${GN}✓${CL} Repository removed from configuration.json"

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
            '.tappaas.repositories = [.tappaas.repositories[] | if .name == $name then .branch = $branch else . end]' \
            "${CONFIG_FILE}" > "${tmp_file}" 2>/dev/null; then
            mv "${tmp_file}" "${CONFIG_FILE}"
        else
            rm -f "${tmp_file}"
            die "Failed to update configuration.json"
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
        '.tappaas.repositories = [.tappaas.repositories[] | if .name == $name then .name = $new_name | .url = $new_url | .branch = $branch | .path = $new_path else . end]' \
        "${CONFIG_FILE}" > "${tmp_file}" 2>/dev/null; then
        mv "${tmp_file}" "${CONFIG_FILE}"
    else
        rm -f "${tmp_file}"
        die "Failed to update configuration.json"
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

    local repo_count
    repo_count=$(jq '.tappaas.repositories // [] | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")

    if [[ "${repo_count}" -eq 0 ]]; then
        info "  No repositories configured."
        return 0
    fi

    printf "  ${BOLD}%-20s %-45s %-12s %-8s${CL}\n" "Name" "URL" "Branch" "Modules"
    printf "  %-20s %-45s %-12s %-8s\n" "----" "---" "------" "-------"

    for i in $(seq 0 $(( repo_count - 1 ))); do
        local r_name r_url r_branch r_path r_modules
        r_name=$(jq -r ".tappaas.repositories[${i}].name" "${CONFIG_FILE}")
        r_url=$(jq -r ".tappaas.repositories[${i}].url" "${CONFIG_FILE}")
        r_branch=$(jq -r ".tappaas.repositories[${i}].branch" "${CONFIG_FILE}")
        r_path=$(jq -r ".tappaas.repositories[${i}].path" "${CONFIG_FILE}")

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
