#!/usr/bin/env bash
# 0005-people-becomes-identities.sh — config/people/ becomes config/identities/
#
# Introduced: 2.1 (Wave 1, G1.1).  Required by: #628 (ADR-007a: one word, Identity).
# Touches: config/people/ (moved) and config/people (left as a symlink).
# Reversible: yes — remove the symlink and restore config/.migrations/backup/0005/people/.
#
# WHY. The domain is Identity everywhere else — the `identity` module, the
# identity-controller, and now identity-manager (was people-manager). What it
# holds are identities: organizations and groups as much as users, and a user
# may be a service account. The directory is `identities/`, not `identity/`
# (proposed on #628, for ADR-007a to confirm): config/identity.json is the
# Authentik module's own config, and one word for two things in one directory
# is the confusion #628 exists to remove.
#
#   only people/                       → moved to identities/; `people` left as a
#                                        symlink to it for ONE stable cycle, so a
#                                        script outside this repository that reads or
#                                        writes the old path keeps working
#   identities/ + people → identities  → already migrated; nothing to do
#   neither                            → nothing to do (no identity domain yet)
#
# WHAT IT REFUSES, rather than guessing (ADR-025 D3): both people/ and
# identities/ as real directories — two copies of the domain are a person's to
# reconcile, and picking one would silently drop the other — and a `people`
# symlink that points anywhere else.
#
# Usage: 0005-people-becomes-identities.sh [--check]
# Exit:  0 applied, or nothing to do · 1 a state it will not guess at

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-${TAPPAAS_CONFIG_DIR:-/home/tappaas/config}}"
BACKUP_DIR="${TAPPAAS_MIGRATION_BACKUP_DIR:-${CONFIG_DIR}/.migrations/backup/0005}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The update sweep's log levels (common-install-routines.sh), inlined: a
# migration is self-contained. `note` is detail, shown under TAPPAAS_DEBUG=1.
say()  { echo -e "\033[32m[Info]\033[m   0005: $*"; }
note() { [[ "${TAPPAAS_DEBUG:-0}" == "1" ]] || return 0; echo -e "\033[36m[Debug]\033[m   0005: $*"; }
stop() { echo -e "\033[01;31m[Error]\033[m 0005: $*" >&2; exit 1; }

OLD="${CONFIG_DIR}/people"
NEW="${CONFIG_DIR}/identities"

if [[ -L "${OLD}" ]]; then
    [[ "$(readlink "${OLD}")" == "identities" && -d "${NEW}" ]] \
        || stop "config/people is a symlink to '$(readlink "${OLD}")', not to identities/ — a person should look at it"
    say "config/people already points at config/identities — nothing to migrate"
    exit 0
fi

if [[ ! -e "${OLD}" ]]; then
    say "no config/people — nothing to migrate"
    exit 0
fi

[[ -d "${OLD}" ]] || stop "config/people exists but is not a directory — a person should look at it"
[[ ! -e "${NEW}" ]] \
    || stop "both config/people/ and config/identities/ exist — two copies of the identity domain; reconcile them by hand (keep one), then re-run"

n="$(find "${OLD}" -type f | wc -l | tr -d ' ')"
if [[ "${CHECK}" -eq 1 ]]; then
    say "would move config/people/ (${n} file(s)) to config/identities/ and leave people → identities"
    exit 0
fi

# Back up before the first write — that copy IS the rollback (ADR-025 D8).
mkdir -p "${BACKUP_DIR}" || stop "cannot create ${BACKUP_DIR} — refusing to write without a backup"
cp -Rp "${OLD}" "${BACKUP_DIR}/people" || stop "cannot back up config/people — nothing has been written"

# A rename within one directory is atomic, and keeps owner and modes; the
# symlink is relative so the config tree stays movable (and restorable elsewhere).
mv "${OLD}" "${NEW}" || stop "cannot move config/people — it is unchanged"
ln -s identities "${OLD}" || stop "moved to config/identities/, but could not leave the config/people symlink — create it by hand: ln -s identities ${OLD}"
say "config/people/ (${n} file(s)) → config/identities/"
note "people → identities symlink kept for one stable cycle; backup: ${BACKUP_DIR}/people"
