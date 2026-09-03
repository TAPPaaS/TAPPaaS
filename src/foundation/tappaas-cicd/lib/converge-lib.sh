# shellcheck shell=bash
# converge-lib.sh — the shared drift-record runner (ADR-020 D7).
#
# ONE copy of the apply mechanics, sourced by every service's
# `update-service.sh`. The manager computes the drift (there is exactly one
# differ); this turns the record it produces into actions:
#
#   1. BATCH every `set` unit into a single provider-level call, because that is
#      what cluster:vm has always done and splitting it would multiply the
#      round-trips and the failure modes.
#   2. DISPATCH each `hook` unit to `services/<svc>/<hook>` over a uniform CLI,
#      so a hook is independently runnable and testable.
#   3. SEQUENCE the side effects ONCE across the whole record — two changed NICs
#      still produce exactly one reboot, one IP wait and one DNS pass.
#   4. AGGREGATE the exit codes into one verdict.
#
# What this file deliberately does NOT know: how to talk to a provider. It never
# runs `qm`, never ssh's, never touches DNS. The sourcing service supplies those
# as callbacks (see "the provider contract" below), which is what lets the same
# runner serve cluster:vm, cluster:lxc and — from ADR-020 P5 — the other 23.
#
# Requires: jq, and common-install-routines.sh sourced first (log helpers).
#
# ── the provider contract ────────────────────────────────────────────────
#
# The sourcing script defines whichever of these it needs; an undefined callback
# for work the record asks for is reported, never silently skipped.
#
#   converge_apply_set "<flag>" "<value>" ...   apply every batched `set` field
#                                               in ONE call. Return non-zero to
#                                               fail the converge.
#   converge_side_effect_<name>                 perform one side effect
#                                               (reboot / wait-ip / dns /
#                                               ha-repoint). Return non-zero to
#                                               fail the converge.
#
# ── the hook CLI ─────────────────────────────────────────────────────────
#
#   update-<name>.sh <module> --unit <file> [--check] [--force]
#                            [--field <f> --desired <v> --actual <v>]
#
# <file> holds the unit as JSON and is AUTHORITATIVE — a composite (net0) needs
# more than one field's values, and the live-only components (a preserved MAC,
# the queues that must never be hot-changed, #194) are in there too. The
# --field/--desired/--actual trio is passed as well when the unit has exactly
# one field, so a hook can be driven by hand without hand-writing JSON.
#
#   exit 0   applied, or already in sync
#   exit 10  would change, but the change needs disruption authorization
#   exit 20  refused (a shrink, an immutable value) — will never apply
#   exit 1   error
#
# ── the runner's own verdict ─────────────────────────────────────────────
#
#   0  everything applied (or nothing to do), possibly with deferrals
#   1  something failed, or drift was found that can never be reconciled here
#
# A DEFERRED disruptive change is NOT a failure (ADR-020 D8, resolved): the
# converge applies everything else, prints a machine-parseable `DEFERRED:` line
# for update-tappaas to collect, and still exits 0.

# Field separator for the jq→read loops below. NOT a tab: tab is IFS
# WHITESPACE, so `read` collapses runs of it and drops leading/trailing empties
# — a row like "cores<TAB>in-place<TAB>set<TAB><TAB>--cores<TAB>false" (no hook)
# then shifts every field left and the setFlag becomes the disruptive flag.
# ASCII US (0x1f) is not whitespace, so every field lands where it belongs.
readonly CONVERGE_FS=$'\x1f'

CONVERGE_DEFERRED=0   # count of units held back for want of authorization
CONVERGE_APPLIED=0    # count of units actually applied

# Side effects run in THIS order, once each, after every unit has applied.
# Order is not arbitrary: a reboot must precede the wait for an address, which
# must precede registering that address in DNS.
readonly CONVERGE_SIDE_EFFECT_ORDER="reboot wait-ip dns ha-repoint"

# converge_apply <module> <service-dir> <drift-file> <check:0|1> <allow-disruption:0|1> [force:0|1]
#
# `allow-disruption` is the D8 authorization, decided by the CALLER: `modify
# --force` (an operator, now) or `rebootOk` in the scheduled pass. It is
# deliberately a parameter and not read from the environment here, so the policy
# stays visible at the call site.
converge_apply() {
    local module="$1" svc_dir="$2" drift_file="$3"
    local check="${4:-0}" allow_disruption="${5:-1}" force="${6:-0}"

    [[ -r "${drift_file}" ]] || { error "converge: cannot read drift record ${drift_file}"; return 1; }
    jq -e . >/dev/null 2>&1 < "${drift_file}" || { error "converge: drift record is not valid JSON"; return 1; }

    local rc=0
    CONVERGE_DEFERRED=0
    CONVERGE_APPLIED=0

    # ── unreconcilable drift ─────────────────────────────────────────
    # A `manual` field is reported and left alone (moving a disk is an operator
    # decision, not something to do implicitly mid-sweep). An `immutable` or
    # `recreate` one means config and reality can never agree without a
    # rebuild, so it FAILS the converge — the same verdict cluster:vm's bios
    # check has always returned.
    local field class desired actual
    while IFS="${CONVERGE_FS}" read -r field class desired actual; do
        [[ -n "${field}" ]] || continue
        case "${class}" in
            manual)
                warn "  ${field} drift (${actual:-none}→${desired}) is not auto-applied — an operator action is needed"
                ;;
            *)
                error "  ${field} drift (${actual:-none}→${desired}) cannot be applied in place [${class}] — requires delete + reinstall"
                rc=1
                ;;
        esac
    done < <(jq -r --arg fs "${CONVERGE_FS}" \
        '.unreconciled[]? | [.field, .class, .desired, .actual] | join($fs)' "${drift_file}")

    # ── adoption: config lags a completed grow ───────────────────────
    # A grow-only field whose ACTUAL already exceeds desired cannot be applied —
    # that direction is a shrink and update-disk.sh refuses it (exit 20). Before
    # ADR-020 D9 that refusal repeated on every converge with no way out, and on
    # main it was worse: `resize-disk.sh || die` aborted the whole update. The
    # guest is not wrong here; CONFIG is behind, because something grew the disk
    # outside the config path. So move config forward instead.
    #
    # This is the ONLY place the converge writes desired state, and it is safe
    # precisely because it touches nothing on the cluster: no guest call, no
    # data at risk, and the value written is the one the reporter just observed.
    local af aclass adesired aactual
    while IFS="${CONVERGE_FS}" read -r af aclass adesired aactual; do
        [[ -n "${af}" ]] || continue
        if [[ "${check}" == "1" ]]; then
            converge_report "  ${af}: config says ${adesired}, guest already has ${aactual} — would adopt ${aactual}"
            continue
        fi
        if jq_module_write "${module}" --arg f "${af}" --arg v "${aactual}" '.[$f] = $v'; then
            converge_report "  ${GN}✓${CL} ${af}: adopted ${aactual} into config (was ${adesired}; the guest was already larger)"
            CONVERGE_APPLIED=$((CONVERGE_APPLIED + 1))
        else
            error "  ${af}: could not adopt ${aactual} into config"
            rc=1
        fi
    done < <(jq -r --arg fs "${CONVERGE_FS}" \
        '.adopt[]? | [.field, .class, .desired, .actual] | join($fs)' "${drift_file}")

    if [[ "$(jq -r '.units | length' "${drift_file}")" -eq 0 ]]; then
        # In --check mode the verdict IS the output — reporting is the whole
        # point of check mode — so say it plainly rather than at debug level.
        [[ ${rc} -eq 0 ]] && converge_report "  ${GN}✓${CL} in sync with config — no changes needed"
        return ${rc}
    fi

    converge_report "  Detected drift:"

    # ── plan ─────────────────────────────────────────────────────────
    local -a set_args=() hook_units=() migrate_units=() deferred_names=()
    local -a side_effects=()
    local name unit_class apply hook setflag disruptive

    while IFS="${CONVERGE_FS}" read -r name unit_class apply hook setflag disruptive; do
        [[ -n "${name}" ]] || continue

        # REPORT FIRST, decide second. A change that will be deferred is still
        # drift, and a --check that stayed silent about it would say "in sync"
        # about a guest that is not — the same "we did not look" ≠ "clean"
        # confusion #458 had to fix on the dependency-service side.
        local summary
        summary="$(converge_change_summary "${drift_file}" "${name}")"

        # D8: a disruptive change without authorization is DEFERRED, not failed.
        # Everything else in the record still applies.
        if [[ "${disruptive}" == "true" && "${allow_disruption}" != "1" ]]; then
            converge_report "  ${name}: ${summary} [needs disruption authorization — deferred]"
            deferred_names+=("${name}")
            CONVERGE_DEFERRED=$((CONVERGE_DEFERRED + 1))
            continue
        fi

        case "${apply}" in
            set)
                local value
                value="$(jq -r --arg n "${name}" \
                    '.units[] | select(.name == $n) | .fields[0].desired' "${drift_file}")"
                set_args+=("${setflag}" "${value}")
                converge_report "  ${name}: ${summary}"
                ;;
            hook)
                # A `migrate` unit RELOCATES the guest, which invalidates the
                # node every other unit is about to act on — `qm set` is
                # node-local. So it is queued last, exactly as the imperative
                # script it replaces did (set → resize → migrate → reboot).
                if [[ "${unit_class}" == "migrate" ]]; then
                    migrate_units+=("${name}")
                else
                    hook_units+=("${name}")
                fi
                converge_report "  ${name}: ${summary} [${hook}]"
                ;;
            *)
                error "  ${name}: apply mode '${apply}' cannot be dispatched"
                rc=1
                ;;
        esac

        # Collect this unit's side effects for the single sequenced pass.
        local fx
        while read -r fx; do
            [[ -n "${fx}" ]] || continue
            converge_contains "${fx}" "${side_effects[@]:-}" || side_effects+=("${fx}")
        done < <(jq -r --arg n "${name}" '.units[] | select(.name == $n) | .sideEffects[]?' "${drift_file}")
        # `.disruptive` is carried BY the record, not re-derived here: the
        # change-class taxonomy has one home (lib/ts/src/service-fields.ts), and
        # a jq expression listing the disruptive classes would be a second one.
    done < <(jq -r --arg fs "${CONVERGE_FS}" '
        .units[]
        | [ .name, .class, .apply, (.hook // ""), (.setFlag // ""), (.disruptive | tostring) ]
        | join($fs)' "${drift_file}")

    for name in "${deferred_names[@]:-}"; do
        [[ -n "${name}" ]] || continue
        # Machine-parseable: update-tappaas greps DEFERRED: to build the
        # end-of-sweep "N modules have pending disruptive changes" summary.
        warn "DEFERRED: ${module} ${name} needs a disruptive change (reboot/offline migrate) that is not authorized"
        warn "  Apply in a maintenance window:  module-manager module modify ${module} --force"
    done

    if [[ "${check}" == "1" ]]; then
        debug "  CHECK MODE — no changes applied"
        return ${rc}
    fi

    # ── apply ────────────────────────────────────────────────────────
    if [[ ${#set_args[@]} -gt 0 ]]; then
        if ! declare -F converge_apply_set >/dev/null; then
            error "  ${#set_args[@]} batched field(s) to set, but this service defines no converge_apply_set"
            return 1
        fi
        if converge_apply_set "${set_args[@]}"; then
            CONVERGE_APPLIED=$((CONVERGE_APPLIED + ${#set_args[@]} / 2))
        else
            error "  batched set failed"
            rc=1
        fi
    fi

    # Relocations last — see the note where migrate_units is filled.
    local unit_file hook_rc
    for name in "${hook_units[@]:-}" "${migrate_units[@]:-}"; do
        [[ -n "${name}" ]] || continue
        hook="$(jq -r --arg n "${name}" '.units[] | select(.name == $n) | .hook' "${drift_file}")"
        local hook_path="${svc_dir}/${hook}"
        if [[ ! -x "${hook_path}" ]]; then
            error "  ${name}: hook ${hook_path} is missing or not executable"
            rc=1
            continue
        fi
        # The unit PLUS the record's actual state. A hook needs both: the
        # fields that drifted, and the live values no module field declares —
        # the MAC to preserve when none is pinned, the queues that must never be
        # hot-changed (#194), and the vmid/node that say where the guest is.
        # Handing over the unit alone leaves a hook unable to reach the guest at
        # all.
        unit_file="$(mktemp "${TMPDIR:-/tmp}/converge-unit.XXXXXX.json")"
        jq --arg n "${name}" '. as $r | $r.units[] | select(.name == $n) | . + {actual: $r.actual}' \
            "${drift_file}" > "${unit_file}"

        local -a hook_args=("${module}" --unit "${unit_file}")
        [[ "${force}" == "1" ]] && hook_args+=(--force)
        # A single-field unit also gets the plain trio, so the hook is runnable
        # by hand without composing JSON.
        if [[ "$(jq -r --arg n "${name}" '.units[] | select(.name == $n) | .fields | length' "${drift_file}")" == "1" ]]; then
            local f d a
            f="$(jq -r --arg n "${name}" '.units[] | select(.name == $n) | .fields[0].field'   "${drift_file}")"
            d="$(jq -r --arg n "${name}" '.units[] | select(.name == $n) | .fields[0].desired' "${drift_file}")"
            a="$(jq -r --arg n "${name}" '.units[] | select(.name == $n) | .fields[0].actual'  "${drift_file}")"
            hook_args+=(--field "${f}" --desired "${d}" --actual "${a}")
        fi

        "${hook_path}" "${hook_args[@]}"
        hook_rc=$?
        rm -f -- "${unit_file}"
        case ${hook_rc} in
            0)  CONVERGE_APPLIED=$((CONVERGE_APPLIED + 1)) ;;
            10) CONVERGE_DEFERRED=$((CONVERGE_DEFERRED + 1))
                warn "DEFERRED: ${module} ${name} needs disruption authorization — rerun with --force in a window" ;;
            20) error "  ${name}: refused by ${hook} — this change cannot be applied"
                rc=1 ;;
            *)  error "  ${name}: ${hook} failed (rc ${hook_rc})"
                rc=1 ;;
        esac
    done

    # ── side effects, once, in order ─────────────────────────────────
    # Only when something actually applied: deferring every change and then
    # rebooting anyway would be the worst of both.
    if [[ ${CONVERGE_APPLIED} -gt 0 && ${#side_effects[@]} -gt 0 ]]; then
        local want
        for want in ${CONVERGE_SIDE_EFFECT_ORDER}; do
            converge_contains "${want}" "${side_effects[@]}" || continue
            local fn="converge_side_effect_${want//-/_}"
            if ! declare -F "${fn}" >/dev/null; then
                warn "  side effect '${want}' is declared by the manifest but this service implements no ${fn}"
                continue
            fi
            debug "  side effect: ${want}"
            "${fn}" || { error "  side effect '${want}' failed"; rc=1; }
        done
    fi

    return ${rc}
}

# Is $1 present in the remaining arguments?
converge_contains() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "${x}" == "${needle}" ]] && return 0; done
    return 1
}

# "cores: 2→8" / "net0: bridge0 lan→iotbr, zone0 200→410" for the operator log.
# A single-field unit names the field ONCE — the unit and the field share a name
# there, and "cores: cores: 4→8" reads like a bug.
converge_change_summary() {
    jq -r --arg n "$2" '
        .units[] | select(.name == $n)
        | (.fields | length) as $count
        | .fields
        | map((if $count == 1 then "" else .field + " " end)
              + (if .actual == "" then "none" else .actual end) + "→" + .desired)
        | join(", ")' "$1"
}

# In --check mode the verdict IS the output, so it goes to info; in apply mode
# it stays at debug so a routine sweep's console stays compact. Set
# CONVERGE_CHECK=1 before calling converge_apply to switch.
converge_report() {
    if [[ "${CONVERGE_CHECK:-0}" == "1" ]]; then info "$@"; else debug "$@"; fi
}
