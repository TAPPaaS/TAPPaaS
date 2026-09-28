#!/usr/bin/env bash
#
# identity:accessControl test-service — NOT IMPLEMENTED YET (ADR-027 D6 stub)
#
# ── REPLACE THE WARNING BELOW WITH THE REAL TEST ─────────────────────────
# What "this consumer's access control works" means, and should check:
#   - Authentik has the consumer's Proxy Provider and Application, and the
#     provider is attached to the embedded outpost
#   - the consumer's Caddy handler has ForwardAuth on
#   - an unauthenticated request to the consumer's public URL is redirected
#     to Authentik rather than served
# Delete the warning when you write it.
# ─────────────────────────────────────────────────────────────────────────
#
# Usage: test-service.sh <module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

warn "identity:accessControl test-service has not been implemented — ${1:-the module}'s single sign-on is not tested. Please contact the module's developer."
exit 0
