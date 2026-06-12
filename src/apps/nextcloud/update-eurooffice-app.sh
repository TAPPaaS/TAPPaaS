#!/usr/bin/env bash
# Update eurooffice-nextcloud.nix to the latest release tag.
#
# Automatically computes the source and npm dependency hashes.
# After running, a single nix build is required to capture the PHP vendor hash.
#
# Usage: ./update-eurooffice-app.sh
#
# Must be run on tappaas-cicd as the tappaas user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX_FILE="${SCRIPT_DIR}/eurooffice-nextcloud.nix"
REPO="Euro-Office/eurooffice-nextcloud"
FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

YW='\033[33m'
GN='\033[32m'
RD='\033[01;31m'
BL='\033[34m'
CL='\033[m'
BOLD='\033[1m'

info()  { echo -e "${BL}[INFO]${CL}  $*"; }
pass()  { echo -e "${GN}[OK]${CL}    $*"; }
warn()  { echo -e "${YW}[WARN]${CL}  $*"; }
error() { echo -e "${RD}[ERROR]${CL} $*" >&2; exit 1; }

echo -e ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${CL}"
echo -e "${BOLD}  Euro-Office Nextcloud App — Update Script${CL}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${CL}"
echo -e ""

# Verify required tools
for tool in curl jq; do
    command -v "$tool" &>/dev/null || error "Required tool not found: $tool"
done

[ -f "$NIX_FILE" ] || error "Derivation file not found: $NIX_FILE"

# Extract current version from the .nix file
CURRENT_VERSION=$(grep -oP 'version = "\K[^"]+' "$NIX_FILE" | head -1)
info "Current version: ${CURRENT_VERSION}"

# Fetch latest tag from GitHub
info "Fetching latest tag from GitHub..."
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/tags" \
    | jq -r '.[0].name')
LATEST_VERSION="${LATEST_TAG#v}"
info "Latest version:  ${LATEST_VERSION}"

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
    pass "Already at latest version (${CURRENT_VERSION}). Nothing to do."
    exit 0
fi

echo -e ""
info "Updating ${CURRENT_VERSION} → ${LATEST_VERSION}"

# Compute source hash (downloads source + submodules into Nix store)
info "Computing source hash (downloads repo + submodules — may take a moment)..."
PREFETCH_JSON=$(nix-shell -p nix-prefetch-git --run \
    "nix-prefetch-git \
     --fetch-submodules \
     --rev '${LATEST_TAG}' \
     https://github.com/${REPO}" 2>/dev/null)

SRC_HASH=$(echo "$PREFETCH_JSON" | jq -r '.hash')
SRC_PATH=$(echo "$PREFETCH_JSON" | jq -r '.path')
pass "Source hash: ${SRC_HASH}"

# Locate npm lockfile in fetched source
if [ -f "${SRC_PATH}/npm-shrinkwrap.json" ]; then
    NPM_LOCKFILE="${SRC_PATH}/npm-shrinkwrap.json"
elif [ -f "${SRC_PATH}/package-lock.json" ]; then
    NPM_LOCKFILE="${SRC_PATH}/package-lock.json"
else
    warn "No npm lockfile found in fetched source — keeping existing npmDepsHash."
    NPM_LOCKFILE=""
fi

# Compute npm dependencies hash
NPM_HASH=""
if [ -n "$NPM_LOCKFILE" ]; then
    info "Computing npm dependencies hash..."
    NPM_HASH=$(nix-shell -p prefetch-npm-deps --run \
        "prefetch-npm-deps '${NPM_LOCKFILE}'" 2>/dev/null)
    pass "npm deps hash: ${NPM_HASH}"
fi

# Update eurooffice-nextcloud.nix
info "Writing updated hashes to ${NIX_FILE}..."

sed -i "s|version = \"${CURRENT_VERSION}\"|version = \"${LATEST_VERSION}\"|g" "$NIX_FILE"

# Source hash — the fetchgit `hash =` line (4-space indent, unique in file)
sed -i "s|    hash = \"sha256-[A-Za-z0-9+/=]*\";|    hash = \"${SRC_HASH}\";|" "$NIX_FILE"

if [ -n "$NPM_HASH" ]; then
    sed -i "s|npmDepsHash = \"sha256-[A-Za-z0-9+/=]*\";|npmDepsHash = \"${NPM_HASH}\";|" "$NIX_FILE"
fi

# Reset vendor hash to placeholder so the next build reveals the correct value
sed -i "s|outputHash = \"sha256-[A-Za-z0-9+/=]*\";|outputHash = \"${FAKE_HASH}\";|" "$NIX_FILE"

echo -e ""
echo -e "${GN}${BOLD}Update applied: ${CURRENT_VERSION} → ${LATEST_VERSION}${CL}"
echo -e ""
echo -e "Source hash and npm deps hash have been updated."
echo -e ""
echo -e "${BOLD}NEXT STEP: update the PHP vendor hash${CL}"
echo -e "  1. Run:  update-module nextcloud"
echo -e "     The build will fail with:"
echo -e "       specified: sha256-AAAA..."
echo -e "       got:       sha256-<correct hash>"
echo -e ""
echo -e "  2. Open ${NIX_FILE}"
echo -e "     Replace the 'outputHash' placeholder with the 'got:' value."
echo -e ""
echo -e "  3. Run:  update-module nextcloud  (succeeds this time)"
echo -e ""
