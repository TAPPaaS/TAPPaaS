#!/usr/bin/env bash
#
# TAPPaaS litellm — narrow the Authentik access gate to litellm-admins
#
# WHY THIS LIVES HERE AND NOT IN identity:identity
# ------------------------------------------------
# identity:identity binds `users` (every org member) to every application it
# wires, unconditionally. That is the right default for a general app and the
# wrong one for LiteLLM specifically, because LiteLLM's open-source SSO path is
# capped at FIVE seats: _raise_if_sso_exceeds_free_user_limit() counts rows in
# LiteLLM's own user table, and a row is created the first time someone logs in.
# With `users` bound, any of the org's members can spend one of those five seats
# merely by opening the UI once out of curiosity — and seats are not reclaimed.
#
# That constraint is LiteLLM's alone, so the fix belongs to the LiteLLM module
# rather than to the shared identity foundation. Devs who need models are not
# affected: OpenWebUI's SSO is uncapped, and virtual keys (which carry a
# team_id and no user_id) consume no seat at all.
#
# ORDERING MATTERS. app-bind-groups is additive and never prunes, so
# identity:identity re-adds `users` on every reconcile. This script must
# therefore run AFTER dependency services are re-applied — which is exactly
# where update.sh sits in update-module.sh's sequence (Step 2 re-applies
# dependencies, then the module's own update.sh runs). Running it earlier is
# useless: the binding comes straight back.
#
# Idempotent: a no-op when the binding is already absent.
set -euo pipefail

APP_SLUG="${1:-litellm}"
DROP_GROUP="${2:-users}"
CRED_FILE="${AUTHENTIK_CREDENTIAL_FILE:-${HOME}/.authentik-credentials.txt}"

if [[ ! -f "${CRED_FILE}" ]]; then
    echo "  narrow-access-gate: ${CRED_FILE} not found — skipped" >&2
    exit 0
fi

python3 - "${APP_SLUG}" "${DROP_GROUP}" "${CRED_FILE}" <<'PY'
import json, sys, urllib.request, urllib.error

app_slug, drop_group, cred_file = sys.argv[1], sys.argv[2], sys.argv[3]

url = token = ""
for line in open(cred_file):
    if line.startswith("url="):
        url = line.split("=", 1)[1].strip().rstrip("/")
    elif line.startswith("token="):
        token = line.split("=", 1)[1].strip()
if not url or not token:
    print("  narrow-access-gate: no url/token in credentials — skipped")
    sys.exit(0)

BASE = url + "/api/v3"


def req(path, method="GET"):
    r = urllib.request.Request(
        BASE + path, method=method,
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=30) as f:
        raw = f.read()
        return json.loads(raw) if raw else None


try:
    # superuser_full_list is REQUIRED: without it Authentik returns only the
    # applications the calling identity can itself see, which silently hides
    # the very app we are trying to reconcile.
    apps = req("/core/applications/?page_size=1000&superuser_full_list=true")["results"]
    groups = req("/core/groups/?page_size=1000")["results"]
    binds = req("/policies/bindings/?page_size=1000")["results"]
except urllib.error.URLError as e:
    print("  narrow-access-gate: Authentik unreachable (%s) — skipped" % e)
    sys.exit(0)

app = next((a for a in apps if a.get("slug") == app_slug), None)
if not app:
    print("  narrow-access-gate: application %r not found — skipped" % app_slug)
    sys.exit(0)

gid = {g["pk"]: g["name"] for g in groups}
mine = [b for b in binds if b.get("target") == app["pk"]]
victims = [b for b in mine if gid.get(b.get("group")) == drop_group]

if not victims:
    print("  narrow-access-gate: %r already not bound to %r — nothing to do"
          % (drop_group, app_slug))
    sys.exit(0)

# HARD SAFETY GUARD. An application with ZERO policy bindings is fail-OPEN in
# Authentik: it admits every authenticated user, the exact opposite of the
# intent here. Never remove the last binding — better to leave the gate too
# wide and say so loudly than to silently throw it open.
remaining = [b for b in mine if b not in victims]
if not remaining:
    print("  narrow-access-gate: REFUSING to remove the last binding on %r — "
          "an app with no bindings is fail-open in Authentik. Ensure "
          "litellm-admins is bound first (identity.providesAdminRole)."
          % app_slug)
    sys.exit(1)

for b in victims:
    req("/policies/bindings/%s/" % b["pk"], method="DELETE")
    print("  narrow-access-gate: removed %r binding from %r" % (drop_group, app_slug))

print("  narrow-access-gate: %r now gated on %s"
      % (app_slug, ", ".join(sorted(gid.get(b.get("group"), "?") for b in remaining))))
PY
