#!/usr/bin/env bash
# TAPPaaS Module: nextcloud — Pre-installation
#
# Generates module secrets before dependency service installers run.
# Called automatically by install-module.sh before Step 4.

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

SECRETS_FILE="/home/tappaas/secrets/nextcloud.env"
if [[ ! -f "${SECRETS_FILE}" ]]; then
    info "Creating ${SECRETS_FILE}..."
    touch "${SECRETS_FILE}"
    chmod 600 "${SECRETS_FILE}"
    info "  ${GN}✓${CL} ${SECRETS_FILE} created"
else
    info "  ${GN}✓${CL} ${SECRETS_FILE} already exists — skipping"
fi
