# shellcheck shell=bash
#
# plugins/manual.sh — fallback vendor plugin for switch-controller / ap-manager.
#
# Used when no vendor-specific plugin (unifi.sh, mikrotik.sh) supports a device.
# It performs no automation: interrogate returns nothing (the actual config is
# maintained by hand / by `switch-controller confirm`), and apply prints the delta
# as human-readable instructions for the operator to apply manually.
#
# Plugin contract (every plugin sourced by switch-controller implements these):
#   plugin_supports <vendor> <model>       -> rc 0 if this plugin handles it
#   plugin_interrogate <name> <mgmt-ip>    -> JSON of live state on stdout ({} if none)
#   plugin_apply <name> <delta-json>       -> rc 0 applied, rc 1 = manual action required
#
# These functions are sourced into switch-controller's namespace; keep names
# prefixed `plugin_` and rely on switch-controller's logging helpers (info/warn).

# The manual plugin is the catch-all: it supports anything (it is selected last,
# only when no real plugin matched — see switch-controller's select_plugin).
plugin_supports() {
    return 0
}

plugin_interrogate() {
    # No automation: the actual config is operator-maintained. Emit empty object
    # so switch-controller keeps whatever is already in actual.json for this device.
    echo "{}"
}

# Render the delta as copy-pasteable manual steps and signal "manual action
# required" (rc 1) so switch-controller does NOT mark the device converged.
plugin_apply() {
    local name="$1" delta_json="$2"
    local changes
    changes=$(echo "${delta_json}" | jq -r '.changes // []' 2>/dev/null)
    if [[ -z "${changes}" || "${changes}" == "[]" ]]; then
        return 0
    fi
    echo "  ╔══════════════════════════════════════════════════════════════════"
    echo "  ║  MANUAL CONFIGURATION — tag these VLANs on switch '${name}' by hand"
    echo "  ╠══════════════════════════════════════════════════════════════════"
    echo "${delta_json}" | jq -r '.changes[] | "  ║  \(.action): \(.description)"' 2>/dev/null
    echo "  ╠══════════════════════════════════════════════════════════════════"
    # `reconcile --apply` records the intent automatically (SM_AUTOCONFIRM set);
    # only bare `apply` needs a follow-up `confirm`.
    if [[ -n "${SM_AUTOCONFIRM:-}" ]]; then
        echo "  ║  TAPPaaS has recorded this as the intended config — just apply it on the device."
    else
        echo "  ║  After applying on the device, run:  switch-controller confirm"
    fi
    echo "  ╚══════════════════════════════════════════════════════════════════"
    return 1
}

# ── AP fallback verbs (sourced by ap-manager) ───────────────────────
# Same catch-all semantics as the switch verbs above, for WiFi APs.
plugin_ap_interrogate() {
    echo "{}"
}

plugin_ap_apply() {
    local name="$1" delta_json="$2"
    local changes
    changes=$(echo "${delta_json}" | jq -r '.changes // []' 2>/dev/null)
    if [[ -z "${changes}" || "${changes}" == "[]" ]]; then
        return 0
    fi
    echo "  ╔══════════════════════════════════════════════════════════════════"
    echo "  ║  MANUAL WiFi CONFIGURATION REQUIRED — no automation plugin for '${name}'"
    echo "  ╠══════════════════════════════════════════════════════════════════"
    echo "${delta_json}" | jq -r '.changes[] | "  ║  \(.action): \(.description)"' 2>/dev/null
    echo "  ╠══════════════════════════════════════════════════════════════════"
    echo "  ║  After applying on the controller, run:  ap-manager confirm"
    echo "  ╚══════════════════════════════════════════════════════════════════"
    return 1
}
