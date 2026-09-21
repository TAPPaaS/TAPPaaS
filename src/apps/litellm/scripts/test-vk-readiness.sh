#!/usr/bin/env bash
# test-vk-readiness.sh — the models service must not act on an unknown provider (#690).
#
# A VM restored from a snapshot answers ssh long before LiteLLM serves its admin
# API. The service scripts used `curl -sf ... || echo '{}'`, so a provider that
# never answered read as a consumer whose virtual key was gone: the converge
# re-provisioned a key that was never lost, generate was refused too, and the
# consuming module was rolled back. `-f` also discarded the body, so the error
# it printed ended at "VK generation failed:" with nothing after the colon.
#
# These are source-tree guards, not live checks: each one fails if the specific
# habit that caused that comes back.
#
# Usage: test-vk-readiness.sh [<litellm-module-dir>]   (default: this module)
set -uo pipefail

DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SVC="${DIR}/services/models"
fail=0

ok()   { echo "PASS $*"; }
bad()  { echo "FAIL $*"; fail=1; }

# ── The readiness gate comes before the first call to the admin API ──────────
for f in install-service.sh update-service.sh; do
  path="${SVC}/${f}"
  if [[ ! -f "${path}" ]]; then bad "${f}: not found"; continue; fi

  gate=$(grep -n 'wait_for_module_ready' "${path}" | head -1 | cut -d: -f1)
  first_call=$(grep -n 'localhost:4000' "${path}" | head -1 | cut -d: -f1)
  if [[ -z "${gate}" ]]; then
    bad "${f}: no wait_for_module_ready before the admin API is used"
  elif [[ -n "${first_call}" && "${gate}" -gt "${first_call}" ]]; then
    bad "${f}: wait_for_module_ready (line ${gate}) comes after the first API call (line ${first_call})"
  else
    ok "${f}: readiness gate precedes the admin API"
  fi

  # ── An unreachable provider must not be reported as an empty key list ──────
  if grep -q "echo '{}'" "${path}"; then
    bad "${f}: /key/list still falls back to an empty object — 'down' reads as 'no keys'"
  else
    ok "${f}: /key/list keeps its HTTP status"
  fi
done

# ── Re-provisioning happens on a KNOWN-missing key, never on an unknown one ──
if grep -q 'die "could not read the VK state' "${SVC}/update-service.sh"; then
  ok "update-service.sh: an unreadable VK state stops the converge"
else
  bad "update-service.sh: an unreadable VK state still falls through to re-provisioning"
fi

# ── The generate path retries, and says what happened when it gives up ───────
gen="${SVC}/install-service.sh"
if grep -q 'key/generate' "${gen}" && grep -q 'curl -sf.*key/generate' "${gen}"; then
  bad "install-service.sh: /key/generate uses -f, which throws the error body away"
else
  ok "install-service.sh: /key/generate keeps the response body"
fi
if grep -qE 'for ATTEMPT in|ATTEMPT.*-lt' "${gen}"; then
  ok "install-service.sh: a refused /key/generate is retried"
else
  bad "install-service.sh: /key/generate has no retry — a starting provider fails it outright"
fi
# -F: the line lives in an unquoted heredoc, so the source holds a literal
# backslash before the ${CODE} the remote shell expands.
if grep -qF 'HTTP \${CODE}' "${gen}"; then
  ok "install-service.sh: the failure names the HTTP status"
else
  bad "install-service.sh: the failure does not record the HTTP status"
fi

# ── ready.sh gates on the endpoint the admin API actually needs ──────────────
rdy="${DIR}/ready.sh"
if grep -q '/health/readiness' "${rdy}"; then
  ok "ready.sh: probes /health/readiness"
else
  bad "ready.sh: probes /health, which answers 401 before the database is connected"
fi

exit "${fail}"
