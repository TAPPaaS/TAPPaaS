#!/usr/bin/env bash
#
# install tappass-cicd foundation in a barebone nixos vm
#
# Usage:
#   install.sh [--name SITE-CODE] [--organization ORG] [--branch NAME] [--domain DOMAIN]
#
# Site-native install (ADR-007): writes site.json (create-site.sh) + transforms
# zones.json (network-manager init) + creates the mgmt/default environments
# (environment-manager add). No configuration.json.
# --name is the SITE CODE (site.json .name = Proxmox cluster name). --organization
# is the default org/environment/zone name (site.json .defaultEnvironment),
# decoupled from the site code (#426); it defaults to the site code. The site code
# is derived from --domain's first label when --name is omitted.

# Strict mode: exit on error, undefined vars, pipe failures
set -euo pipefail

# Minimal logging before common-install-routines.sh is available
_info()  { echo -e "\033[1;92m[Info]\033[m $*"; }
_warn()  { echo -e "\033[1;33m[Warning]\033[m $*"; }
_error() { echo -e "\033[01;31m[Error]\033[m $*" >&2; }
_debug() { [[ "${TAPPAAS_DEBUG:-0}" == 1 ]] || return 0; echo -e "\033[36m[Debug]\033[m $*"; }

# The TS managers print their results without a level (CLI output); in the
# install's log every line carries one. _tagged runs a command and tags its
# untagged stdout lines [Info]; tagged lines pass as they are, blank ones are
# dropped. stderr is left alone, so an error is never relabelled.
_tagged() {
  "$@" | awk '{ p = $0; gsub(/\033\[[0-9;]*m/, "", p)
    if (p ~ /^[[:space:]]*$/) next
    if (p ~ /^\[/) print; else print "\033[1;92m[Info]\033[m " $0
    fflush() }'
  return "${PIPESTATUS[0]}"
}

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  _error "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi

# ── Argument parsing ─────────────────────────────────────────────────
# --domain/--branch pass through to create-site.sh; --name is the SITE CODE
# (site.json .name = cluster name); --organization is the default org/environment/
# zone name (site.json .defaultEnvironment), decoupled from the site code (#426).
DOMAIN=""
BRANCH=""
SITE_CODE=""
ORG=""
SIZE=""   # small|medium|large -> site.json .size (ADR-044)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)               SITE_CODE="${2:-}"; shift 2 ;;
    --organization|--org) ORG="${2:-}"; shift 2 ;;
    --size)               SIZE="${2:-}"; shift 2 ;;
    --domain)             DOMAIN="${2:-}"; shift 2 ;;
    --branch)             BRANCH="${2:-}"; shift 2 ;;
    *)                    shift ;;  # Ignore unknown args
  esac
done

# Resolve the SITE CODE (site.json .name = Proxmox cluster name). Derive from
# --domain's first label when --name is omitted. Must match the site .name pattern.
if [[ -z "$SITE_CODE" ]]; then
  if [[ -n "$DOMAIN" ]]; then
    SITE_CODE="${DOMAIN%%.*}"
    _info "No --name given; deriving site code '$SITE_CODE' from domain '$DOMAIN'."
  else
    SITE_CODE="tappaas"
    _warn "No --name or --domain given; defaulting site code to '$SITE_CODE' (override with --name)."
  fi
fi
[[ "$SITE_CODE" =~ ^[A-Za-z0-9_.-]+$ ]] \
  || { _error "Site code '$SITE_CODE' invalid (must match ^[A-Za-z0-9_.-]+\$). Pass --name explicitly."; exit 1; }

# Resolve the ORGANIZATION (default env/zone/org name). Defaults to the site code
# (single-name install). It becomes the default zone + environment via
# network-manager init / environment-manager add, so it must be a valid zone/env
# slug (^[a-z][a-z0-9-]*$ — lowercase, digits, hyphens; start with a letter).
[[ -n "$ORG" ]] || ORG="$SITE_CODE"

# The site's domain (ADR-043 D4): with none given, <site>.home.arpa — the name
# space RFC 8375 keeps for homes, and one a site CA may sign. Every site starts
# in dnsMode local; going public is Day 1's "Make it public".
if [[ -z "$DOMAIN" ]]; then
  DOMAIN="$(printf '%s' "$SITE_CODE" | tr '[:upper:]_' '[:lower:]-').home.arpa"
  _info "No --domain given; the site's domain is ${DOMAIN} (local: no public DNS needed)."
fi
[[ "$ORG" =~ ^[a-z][a-z0-9-]*$ ]] \
  || { _error "Organization '$ORG' invalid (^[a-z][a-z0-9-]*\$). Pass --organization explicitly."; exit 1; }
_info "Site code: ${SITE_CODE}; default org/environment: ${ORG}"

#
# Bootstrap default: use tappaas1 as the primary node for initial cluster discovery.
# Once configuration.json exists, scripts use get_primary_node_fqdn() instead.
# For legacy systems with different hostnames, pass --primary-node to create-site.sh.
MGMTVLAN="mgmt"
NODE1_FQDN="${TAPPAAS_PRIMARY_NODE:-tappaas1}.$MGMTVLAN.internal"
export FIREWALL_FQDN="firewall.$MGMTVLAN.internal"  # Used by sourced scripts

# Accept SSH host keys on first connection (but still reject changed keys);
# LogLevel=ERROR keeps ssh's "Permanently added ..." notice out of the output.
SSH_ACCEPT="-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"

# copy the public keys to the root account of every proxmox host
while read -r node; do
  NODE_FQDN="$node.$MGMTVLAN.internal"
  if _copy_out="$(ssh-copy-id $SSH_ACCEPT -i /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN" < /dev/null 2>&1)"; then
    _debug "  ${node}: ${_copy_out##*$'\n'}"
  else
    _warn "  ${node}: ssh-copy-id failed: ${_copy_out##*$'\n'}"
  fi
  # also make the key available for the tappaas script that configure cloud-init on the vms
  ssh -n $SSH_ACCEPT root@"$NODE_FQDN" "mkdir -p /root/tappaas" 2>/dev/null
  scp $SSH_ACCEPT /home/tappaas/.ssh/id_ed25519.pub root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.pub < /dev/null 2>/dev/null
  # The PRIVATE key too — deliberately. It is the console debug path: from a node's
  # console or web-GUI Shell, `ssh -i /root/tappaas/tappaas-cicd.key tappaas@tappaas-cicd.mgmt.internal`
  # reaches the mothership (and from there every VM) when nothing else does. No script
  # reads it. cicd-key.sh rotate/recover refresh it, never delete it (#122).
  scp $SSH_ACCEPT /home/tappaas/.ssh/id_ed25519 root@"$NODE_FQDN":/root/tappaas/tappaas-cicd.key < /dev/null 2>/dev/null
  _info "  \033[1;92m✓\033[m ${node}: the mothership's SSH key installed"
done < <(ssh -n $SSH_ACCEPT root@"$NODE1_FQDN" pvesh get /cluster/resources --type node --output-format json | jq --raw-output ".[].node" )

# create tappaas binary director and config directory
mkdir -p /home/tappaas/config
mkdir -p /home/tappaas/bin

# Add /home/tappaas/bin to PATH
# On NixOS, .profile is sourced for login shells, and we also add to .bashrc
# for interactive non-login shells that explicitly source it
TAPPAAS_PATH_EXPORT='export PATH="/home/tappaas/bin:$PATH"'

# Export PATH for the current script execution
export PATH="/home/tappaas/bin:$PATH"

for rcfile in /home/tappaas/.profile /home/tappaas/.bashrc; do
    if ! grep -q '/home/tappaas/bin' "$rcfile" 2>/dev/null; then
        echo -e '\n# TAPPaaS bin directory' >> "$rcfile"
        echo "$TAPPAAS_PATH_EXPORT" >> "$rcfile"
        _debug "Added /home/tappaas/bin to PATH in $rcfile"
    fi
done

# create site.json (site-native — no configuration.json). create-site.sh
# discovers the cluster and writes site.json; it validates via its sibling
# validate-site.sh, so it works here before the ~/bin symlinks exist.
CREATE_SITE_ARGS=(--name "$SITE_CODE" --organization "$ORG")
[[ -n "$DOMAIN" ]] && CREATE_SITE_ARGS+=(--domain "$DOMAIN")
[[ -n "$BRANCH" ]] && CREATE_SITE_ARGS+=(--branch "$BRANCH")
[[ -n "$SIZE" ]] && CREATE_SITE_ARGS+=(--size "$SIZE")
# Idempotent resume: create-site.sh refuses to overwrite an existing site.json
# without --force. A --force re-run PRESERVES operator-set fields (owner,
# repositories, email, reboot/snapshot policy — see create-site.sh),
# so it is the supported way to resume a partially-completed install without
# clobbering anything. On a true first install site.json is absent → no --force.
[[ -f /home/tappaas/config/site.json ]] && CREATE_SITE_ARGS+=(--force)

if [ -f ./manager/site-manager/create-site.sh ]; then
  ./manager/site-manager/create-site.sh "${CREATE_SITE_ARGS[@]}"
else
  _error "./manager/site-manager/create-site.sh not found"
  exit 1
fi

# zones.json is NOT raw-copied here (ADR-014 D7). `network-manager init core`
# further below CREATES it from the core profile — a raw copy would plant every
# zone the template carries (including the opt-in IoT set), and since profiles are
# additive and existing-wins, those zones would then be preserved forever as if
# the operator had chosen them. An existing zones.json is left untouched: it may
# hold operator customizations, and release drift is reconciled by
# `network-manager merge` on every update-tappaas (#209 / ADR-007 Design A).
if [ -f /home/tappaas/config/zones.json ]; then
  _debug "Preserving existing /home/tappaas/config/zones.json (not overwriting)"
else
  _debug "zones.json will be created by 'network-manager init core' below"
fi
# zones.json.orig (the 3-way merge baseline) and zones.rename.json are ALSO
# seeded by init, from the FULL renamed template — the merge source must contain
# every zone the release ships, whichever profiles are installed, or a field fix
# to an uninstalled zone could never be adopted later.

# --- Install scripts as symlinks into /home/tappaas/bin/ ---
_debug "Installing scripts to /home/tappaas/bin/..."
cd
cd TAPPaaS || { _error "TAPPaaS directory not found!"; exit 1; }
# get to the right directory
cd src/foundation/tappaas-cicd || { _error "TAPPaaS-CICD directory not found!"; exit 1; }
# scripts/*.sh = not-yet-relocated CLIs; lib/*.sh = shared sourced libraries
# (ADR-007 S0: common-install-routines.sh et al. moved scripts/ -> lib/). Both
# keep their /home/tappaas/bin/<name> symlink so the ~160 `. bin/...` sourcers
# and operator CLIs resolve unchanged — bin/ is the move-safe indirection layer.
for script in scripts/*.sh lib/*.sh; do
  if [ -f "$script" ]; then
    script_name=$(basename "$script")
    target="/home/tappaas/bin/$script_name"
    # Remove the existing entry first — on NixOS it may be a symlink into a
    # read-only /etc/static/ path (issue #184), which would otherwise make
    # the subsequent chmod fail with EROFS.
    rm -f "$target" 2>/dev/null || true
    src="$(realpath "$script")"
    # chmod the resolved source, not the symlink: chmod follows symlinks,
    # so chmod'ing a /home/tappaas/bin/*.sh symlink that points into
    # /etc/static would still fail. The source lives in the writable repo.
    # #565: only chmod files the repo tracks executable — a sourced lib stays
    # 100644. (common-install-routines.sh isn't sourced yet here, so the
    # tracked-mode check is inline; it mirrors tappaas_should_be_executable.)
    if git -C "$(dirname "$src")" ls-files -s --error-unmatch -- "$(basename "$src")" 2>/dev/null | grep -q '^100755'; then
      chmod +x "$src"
    fi
    ln -s "$src" "$target"
  fi
done

# --- ADR-007 S0: two-level dispatch links relocated components' bins ---
# scripts/*.sh above only covers not-yet-relocated scripts; components moved into
# manager/<x>/ + controller/<x>/ link their own bins via their install.sh;
# ui/ is one component, the console (ADR-034), whose install.sh builds and links it.
for _disp in manager controller ui; do
  if [ -x "${_disp}/install.sh" ]; then
    _debug "  linking ${_disp}/ components..."
    "./${_disp}/install.sh" || _error "  ${_disp}/install.sh reported non-zero rc"
  fi
done
# The control plane's registry (ADR-035 D5), read by the self-check and the console.
[ -f scripts/control-plane-registry.sh ] && { bash scripts/control-plane-registry.sh || _error "  could not write config/control-plane.json"; }

# (The legacy zone-controller/zone-state bash scripts are retired — their verbs
# are native in the network-manager TS bin linked by the dispatcher above:
# `network-manager add/delete/enable/disable/manual`; ADR-007 Phase 7.5.)

# ── Site-native zones + environments (ADR-007 S6) ────────────────────
# The managers are built+linked now (above), so transform zones.json for THIS
# installation — network-manager init renames the distributed 'srv' zone to
# the ORG name, inactivates the unused legacy zones, and rewrites references —
# and create the always-required mgmt + default (<ORG>) environments. The default
# zone/environment are named after the ORGANIZATION, not the site code (#426).
#
# ADR-007 "Design A": init now seeds ALL THREE files in the renamed
# namespace — zones.json (current), zones.json.orig (merge baseline), and
# zones.rename.json (the renamed source). So the raw zones.json/zones.json.orig
# seeded above are BOTH overwritten with the renamed version, giving
# current == orig == rename on a fresh install. This is what stops the daily
# `merge` from re-introducing srv (the old duplicate-VLAN corruption). Guarded on
# the default environment file so a re-run does not clobber a customised zones.json.
if [ ! -f "/home/tappaas/config/environments/${ORG}.json" ]; then
  _info "Initialising zones for '${ORG}' (network-manager init core)..."
  # ADR-014 D7: `core` is the minimal coherent install — mgmt, wan, the three
  # overlays, the renamed <ORG> service zone, home, guest and dmz. The IoT
  # segment set is OPT-IN: run `network-manager init iot --name <ORG>` on a site
  # that has smart-home/IoT devices. init also seeds zones.rename.json and
  # zones.json.orig from the full renamed template (Design A).
  _tagged /home/tappaas/bin/network-manager init core --name "$ORG" --force \
    || _error "  init reported a non-zero rc"
  _info "Creating the mgmt + ${ORG} environments..."
  # `environment-manager add` with no positional <env> seeds the minimal set
  # (mgmt + <ORG>) — the retired create-minimal-environments.sh, native since
  # the ADR-007 refactor (Phase 8.1). The TS bin IS on PATH at this point: the
  # manager/install.sh dispatch loop above already nix-built + linked the
  # managers ("linking manager/ components...").
  CME_ARGS=(--name "$ORG" --dns-mode local)
  [[ -n "$DOMAIN" ]] && CME_ARGS+=(--domain "$DOMAIN")
  _tagged /home/tappaas/bin/environment-manager add "${CME_ARGS[@]}" \
    || _error "  environment bootstrap (environment-manager add) reported a non-zero rc"
else
  _info "Environments already initialised (config/environments/${ORG}.json exists) — skipping init/environments."
fi

# The site's internal CA (ADR-043 D1): before any guest but the firewall and this
# one is built, so every guest trusts it from its first build.
_tagged /home/tappaas/bin/ca-manager init --no-rebuild || _error "  ca-manager init failed: no internal CA, so guests get no site trust"

# Both environments start in dnsMode local: their wildcard from the site's CA, on
# the firewall, and the Unbound wildcard. The network reconcile follows later.
for _env in mgmt "$ORG"; do
  _tagged /home/tappaas/bin/environment-manager reconcile "$_env" --apply --skip-network \
    || _warn "  the ${_env} environment's certificate is not in place yet — environment-manager reconcile ${_env} --apply"
done

# Install the cluster and network jsons
cd ../cluster || { _error "Cluster directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh cluster
cd ../templates || { _error "Templates directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh templates
# ADR-029 v0.9 D1: storage is virtual like cluster — registered so storage:nfs resolves.
cd ../storage || { _error "Storage directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh storage
# ADR-007 P8: the firewall module is renamed to "network" (deploys config/network.json).
# The OPNsense HOST is still reached as FIREWALL_FQDN (firewall.mgmt.internal) — the
# host rename is the deferred supervised migration, so that lifeline is unchanged here.
cd ../network || { _error "Network directory not found!"; exit 1; }
FIREWALL_AVAILABLE=true
if ! ping -c 1 -W 2 "$FIREWALL_FQDN" >/dev/null 2>&1; then
    FIREWALL_AVAILABLE=false
    _warn "OPNsense firewall ($FIREWALL_FQDN) is not reachable."
    _warn "Deploying network module with firewallType=NONE."
    _warn "You will need to configure reverse proxy and firewall rules manually."
fi
/home/tappaas/bin/copy-update-json.sh network
if [[ "$FIREWALL_AVAILABLE" == "false" ]]; then
    # Override: remove VM dependencies and mark as non-OPNsense deployment
    tmp_fw=$(mktemp)
    jq '.dependsOn = [] | .firewallType = "NONE"' /home/tappaas/config/network.json > "$tmp_fw" \
        && mv "$tmp_fw" /home/tappaas/config/network.json
fi
cd ../tappaas-cicd || { _error "TAPPaaS-CICD directory not found!"; exit 1; }
/home/tappaas/bin/copy-update-json.sh tappaas-cicd

# run the full tappaas-cicd update scripts with all dependencies and checks
/home/tappaas/bin/update-module.sh tappaas-cicd --no-snapshot
/home/tappaas/bin/update-module.sh cluster

# ── Node-provisioning latency (design N3): stage the PVE netboot assets ──
# so `site-manager node add <name>` works on EVERY TAPPaaS system with
# zero prep. Non-fatal: a failed download only costs the latent capability
# (re-run prepare-netboot.sh later); ~1.5 GB ISO fetched on tappaas1.
_info "Staging PVE netboot assets for node provisioning (prepare-netboot.sh)..."
/home/tappaas/bin/prepare-netboot.sh \
  || _warn "netboot staging failed — 'node add' needs a later 'prepare-netboot.sh' run"

# Source common-install-routines.sh to replace the minimal _info/_warn/_error with full versions
# shellcheck source=/home/tappaas/bin/common-install-routines.sh
. "${TAPPAAS_BIN:-/home/tappaas/bin}/common-install-routines.sh"

# Run a command with its (noisy) output routed to [Debug] — shown only when
# TAPPAAS_DEBUG=1; on failure the captured output is surfaced so errors stay
# visible. Returns the command's rc (so `run_quiet … || …` still works).
run_quiet() {
  local _out _rc _l
  _out="$("$@" 2>&1)" && _rc=0 || _rc=$?
  if [[ ${_rc} -ne 0 ]]; then
    if [[ -n "${_out}" ]]; then printf '%s\n' "${_out}" >&2; fi
    return "${_rc}"
  fi
  if [[ -n "${_out}" ]]; then
    while IFS= read -r _l; do debug "  ${_l}"; done <<<"${_out}"
  fi
  return 0
}

if [[ "$FIREWALL_AVAILABLE" == "true" ]]; then
    # Install and enable QEMU guest agent on OPNsense (FreeBSD)
    # This allows Proxmox to communicate with the firewall VM via the guest agent
    info "Installing QEMU guest agent on OPNsense..."
    if ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg info os-qemu-guest-agent'" &>/dev/null; then
        info "  QEMU guest agent already installed"
    else
        run_quiet ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg install -y os-qemu-guest-agent'" || {
            warn "QEMU guest agent installation failed. Install manually via OPNsense UI."
        }
    fi
    info "Enabling QEMU guest agent service..."
    run_quiet ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'sysrc qemu_guest_agent_enable=YES'" || true
    if ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'service qemu-guest-agent status'" &>/dev/null; then
        info "  QEMU guest agent service is already running"
    else
        run_quiet ssh $SSH_ACCEPT root@"$FIREWALL_FQDN" "/bin/sh -c 'service qemu-guest-agent start'" || {
            warn "QEMU guest agent service could not be started. Enable manually in OPNsense."
        }
    fi

    # Set up Caddy on the firewall BEFORE updating the network module. The
    # network module's network:proxy update-service calls the OPNsense Caddy
    # API (/api/caddy/...), which 404s until the os-caddy plugin is installed —
    # and installing it is setup-caddy.sh's job. (It relies on opnsense-controller,
    # which the tappaas-cicd update above already installed.) On a long-lived
    # firewall os-caddy was already present, masking the ordering; the prebuilt
    # image has no plugins, so it must run first.
    debug "Setting up Caddy reverse proxy (installs os-caddy)..."
    chmod +x /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh
    /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/setup-caddy.sh || {
        warn "Caddy setup encountered issues. Please review and complete manually."
    }

    # Update the network module (now that os-caddy/the Caddy API is available).
    /home/tappaas/bin/update-module.sh network --no-snapshot

    # Bring up the admin-vpn (mgmt tunnel) OPNsense termination as part of the
    # bootstrap (ADR-010 §6). This is topology-agnostic and needs NO satellite:
    # it ensures the tappaas-admin WireGuard server, the admin->mgmt pass rule,
    # and a WAN pass for UDP :51821. WireGuard is in the OPNsense base and
    # silently drops any packet without a registered peer, so opening :51821 on
    # WAN is inert until a device is enrolled — and it hands sites with a public
    # IP direct (Topology-B) reach with no manual firewall step. Enrolling a
    # device later is just `network-manager wgvpn add-peer` (see
    # manager/network-manager/ADMIN-VPN.md).
    # Runs AFTER the network update so its rules are not reconciled away; kept
    # non-fatal like Caddy — admin-vpn is an operator convenience, not required.
    debug "Setting up admin-vpn OPNsense termination (network-manager wgvpn setup)..."
    _tagged /home/tappaas/bin/network-manager wgvpn setup || {
        warn "admin-vpn setup encountered issues. Run 'network-manager wgvpn setup' manually (see manager/network-manager/ADMIN-VPN.md)."
    }
else
    warn "Skipping firewall update (no OPNsense firewall)."
    warn "Skipping Caddy reverse proxy setup (no OPNsense firewall)."
    warn "When modules with network:proxy dependency are installed,"
    warn "you will see manual configuration instructions for your firewall."
fi

# A fresh site is STAMPED at the current migration level, not migrated (ADR-025
# D4): create-site.sh has just written a config/ with today's shapes, so every
# shipped migration is already true of it. Recording them says so; running them
# would be merely wasteful, and silence would leave the first sweep replaying
# the whole history.
_MIGRATE=/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/scripts/run-migrations.sh
if [ -f "${_MIGRATE}" ]; then
    bash "${_MIGRATE}" --baseline || \
        _warn "could not stamp the migration baseline — the first update will run every shipped migration (they are idempotent)"
fi

# Completion marker. Written ONLY here, at the very end, so a re-run can tell a
# finished install from one that wrote configuration.json early then failed later
# (install-platform.sh Phase B keys its idempotent skip off this file).
mkdir -p /home/tappaas/config
touch /home/tappaas/config/.tappaas-cicd-installed

# The update timer (ADR-017 D2): its renderer is skipped until site.json and the
# ~/bin links exist, which they do now — render it, rather than at the next boot.
systemctl start update-tappaas-schedule.service 2>/dev/null \
    || _warn "could not render the update timer — it is rendered at the next boot (systemctl start update-tappaas-schedule.service)"

info "${GN}✓${CL} TAPPaaS-CICD installation completed successfully."

# The console (ADR-034 D10): reachable now, from mgmt or the admin VPN, with the
# setup token bootstrap.sh wrote — until the first sign-in through the Authentik
# gate at console.<domain>. The token itself is never printed: this
# summary goes to the terminal, to logs and to the journal, and a secret in a
# log is a secret in every log reader. The operator reads the file.
_CONSOLE_TOKEN=/home/tappaas/config/console-setup-token
if [ -s "${_CONSOLE_TOKEN}" ] && [ ! -f /home/tappaas/config/identity.json ]; then
    _cicd_addr="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')"
    # The operator's note is the platform install's (install-platform.sh, B.5):
    # one way in. These are the mothership's own details.
    debug "console setup token: ${_CONSOLE_TOKEN} (on the mothership)"
    # The ways in for the operator who ran the bootstrap (on neither mgmt nor
    # the admin VPN): the first admin-VPN peer, and the install LAN when the
    # WAN is private. Non-fatal: mgmt reaches the console in any case.
    /home/tappaas/bin/install-access.sh open \
        || _warn "could not open the install access — from mgmt, the console is at http://${_cicd_addr:-tappaas-cicd.mgmt.internal}:9097/"
    debug "console from mgmt or the admin VPN: http://${_cicd_addr:-tappaas-cicd.mgmt.internal}:9097/ (until the first sign-in through the gate)"
fi
