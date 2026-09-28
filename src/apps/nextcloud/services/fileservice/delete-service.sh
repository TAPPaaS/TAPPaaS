#!/usr/bin/env bash
#
# nextcloud:fileservice delete-service — NOT IMPLEMENTED YET (ADR-027 D6 stub)
#
# ── REPLACE THE WARNING BELOW WITH THE REAL TEARDOWN ─────────────────────
# What a consumer leaves behind in Nextcloud when it is deleted:
#   onlyoffice  /etc/secrets/onlyoffice.env on the Nextcloud VM, and the
#               document-server settings nextcloud-configure-eurooffice.service
#               applied through occ
#   talk        the TURN/STUN servers written into Talk
#   hpb         the signaling server written into Talk
# The teardown removes the env file for the consumer's connector and unsets
# what occ applied, so Nextcloud stops pointing at a server that is gone.
# Delete the warning when you write it.
# ─────────────────────────────────────────────────────────────────────────
#
# Usage: delete-service.sh <module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

warn "nextcloud:fileservice delete-service has not been implemented — ${1:-the module}'s connector settings stay in Nextcloud until removed by hand. Please contact the module's developer."
exit 0
