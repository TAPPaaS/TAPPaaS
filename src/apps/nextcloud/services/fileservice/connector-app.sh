# shellcheck shell=bash
#
# connector-app.sh — which Nextcloud app carries the document-server connector.
#
# Connector v11 (#735) renamed the Nextcloud app ID from `onlyoffice` to
# `eurooffice`. The fileservice scripts ship with the repository, but the app on
# the guest changes only when Nextcloud itself is updated — so for a while (a
# manual `reconcile euro-office` first, or a Nextcloud update that rolled back)
# they meet a guest still on v10. Reading only `eurooffice` there reported a
# working connector as "not set up" (#743). Sourced by test-service.sh and
# update-service.sh; needs ssh access to the Nextcloud VM.

# fileservice_connector_app <nextcloud-host>
#   prints "eurooffice" (v11), "onlyoffice" (v10: Nextcloud not updated past it),
#   or nothing (no connector app enabled, or the VM could not be asked).
#   An app enabled for groups stores its group list instead of "yes", so any value
#   other than "no" counts as enabled.
fileservice_connector_app() {
    local rows
    rows=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "tappaas@$1" \
        "sudo -u postgres psql -d nextcloud -tAc \
        \"SELECT appid FROM oc_appconfig WHERE appid IN ('eurooffice','onlyoffice') AND configkey='enabled' AND configvalue <> 'no'\" \
        2>/dev/null" 2>/dev/null || true)
    if grep -qx 'eurooffice' <<< "${rows}"; then
        echo eurooffice
    elif grep -qx 'onlyoffice' <<< "${rows}"; then
        echo onlyoffice
    fi
}

# The operator's way out of the v10 state, said the same way by both scripts.
# shellcheck disable=SC2034  # read by test-service.sh and update-service.sh
FILESERVICE_V10_HINT="Nextcloud still runs the pre-v11 connector app 'onlyoffice': update Nextcloud first (module-manager module update nextcloud), then euro-office"
