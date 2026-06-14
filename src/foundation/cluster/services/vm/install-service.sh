#!/usr/bin/env bash
#
# TAPPaaS Cluster VM Service - Install
#
# Creates a VM on the Proxmox cluster for a consuming module.
# Based on the install-vm.sh script.
#
# Usage: install-service.sh <module-name>
# Arguments:
#   module-name - Name of the module that depends on this service
#                 (must have a <module-name>.json in /home/tappaas/config)
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Creates a VM for the specified module."
    exit 1
fi

. /home/tappaas/bin/common-install-routines.sh
check_json "/home/tappaas/config/$1.json" || exit 1

VMNAME="$(get_config_value 'vmname' "$1")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
IMAGETYPE="$(get_config_value 'imageType' 'img')"
OSTYPE_VAL="$(get_config_value 'ostype' 'l26')"
CLOUDINIT="$(get_config_value 'cloudInit' 'true')"
MGMT="mgmt"

# ── Recreate-safe SSH (central stale host-key clear) ──────────────────────
# A redeployed VM reuses its hostname (vmname.zone.internal) but gets a NEW SSH
# host key. A stale known_hosts entry from the prior VM then makes every later ssh
# that connects by hostname fail with "host key changed" — silently breaking the
# framework + module install/wiring scripts that use StrictHostKeyChecking=accept-new
# (it adds unknown hosts but REJECTS changed keys). Clear the stale hostname key ONCE
# here, at (re)creation, so downstream scripts need no per-script `ssh-keygen -R`.
# (The framework already clears the IP key in update-os.sh; this covers the hostname
# path that modules actually connect on.)
for _z in "${ZONE0NAME}" "$(get_config_value 'zone1' '')" "$(get_config_value 'zone2' '')"; do
    [[ -n "${_z}" ]] || continue
    ssh-keygen -R "${VMNAME}.${_z}.internal" >/dev/null 2>&1 || true
done

# Read the VM's primary-NIC (net0) MAC from the Proxmox config. Used to turn a
# DNS pin into a static DHCP reservation (MAC -> IP) for guests that must be
# pinned (HAOS appliances, Windows clones) so the locked IP can never drift and
# leave the pin stale. Empty if it can't be read (caller falls back to a plain
# host override).
_vm_net0_mac() {
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${NODE}.${MGMT}.internal" \
        "qm config ${VMID} 2>/dev/null" 2>/dev/null \
        | sed -n 's/^net0:.*virtio=\([0-9A-Fa-f:]\{17\}\).*/\1/p' | head -1
}

# For Windows clone VMs, prepare the OOBE answer file on the target node before
# Create-TAPPaaS-VM.sh runs. The script deletes the file after building the per-VM
# ISO, so it must be present on each deployment — not just the first.
_is_windows=false
case "$OSTYPE_VAL" in
    win10|win11|win2k19|win2k22|win2k25) _is_windows=true ;;
esac

_templates_dir=""
if ! _templates_dir="$(get_module_dir 'templates')"; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _templates_dir="$(cd "${_SCRIPT_DIR}/../../../templates" 2>/dev/null && pwd)" || _templates_dir=""
fi

if [[ "$_is_windows" == "true" ]]; then
    if [[ "$IMAGETYPE" == "clone" ]]; then
        # Clone: generate (or read) the tappaas account password now.
        # The actual account setup is done via guest agent after VM creation (see below).
        _secrets_file="/home/tappaas/secrets/${1}.env"
        _tappaas_password=""
        if [[ -f "$_secrets_file" ]]; then
            _tappaas_password="$(grep '^TAPPAAS_PASSWORD=' "$_secrets_file" 2>/dev/null | cut -d= -f2- | head -1)"
        fi
        if [[ -z "$_tappaas_password" ]]; then
            # Generate a Windows-complexity-compliant password using Python 3.
            # openssl rand -hex 8 is not reliably in the PATH on NixOS and produces
            # hex-only output (lowercase + digits = 2 categories) which may fail
            # Windows complexity if the prefix/suffix heuristic ever changes.
            # Python secrets guarantees ≥1 upper, ≥1 lower, ≥1 digit, ≥1 special.
            _tappaas_password=$(python3 - <<'PYEOF'
import secrets, string
upper   = string.ascii_uppercase
lower   = string.ascii_lowercase
digits  = string.digits
special = '!@#$%^&*'
pool    = upper + lower + digits + special
pw      = [secrets.choice(upper), secrets.choice(lower),
           secrets.choice(digits), secrets.choice(special)]
pw     += [secrets.choice(pool) for _ in range(12)]
secrets.SystemRandom().shuffle(pw)
print(''.join(pw))
PYEOF
)
            mkdir -p /home/tappaas/secrets
            # Write via a temp file so the operation is atomic and idempotent.
            # grep -v strips any existing TAPPAAS_PASSWORD= line (e.g. a blank
            # value from a partial install) before appending the new one —
            # prevents duplicate keys while preserving any other keys in the file.
            _pw_tmp=$(mktemp)
            { grep -v '^TAPPAAS_PASSWORD=' "$_secrets_file" 2>/dev/null; \
              printf 'TAPPAAS_PASSWORD=%s\n' "$_tappaas_password"; } > "$_pw_tmp"
            mv "$_pw_tmp" "$_secrets_file"
            chmod 600 "$_secrets_file"
            info "Generated tappaas account password → ${_secrets_file}"
        fi

    elif [[ "$IMAGETYPE" == "iso" ]]; then
        # ISO: this is a Windows template build (e.g. tappaas-winserver).
        # Deploy autounattend.xml so Create-TAPPaaS-VM.sh can build the config ISO.
        _autounattend="${_templates_dir}/winserver/autounattend.xml"
        if [[ -n "$_templates_dir" && -f "$_autounattend" ]]; then
            scp "$_autounattend" "root@${NODE}.${MGMT}.internal:/root/tappaas/autounattend.xml"
            info "autounattend.xml deployed to ${NODE} — Windows install will run unattended"
        else
            warn "autounattend.xml not found — Windows template install will require manual input"
        fi
    fi
fi

# For clone VMs: verify the template exists. If missing, find a build config in the
# templates directory with a matching vmid and auto-build it before cloning.
if [[ "$IMAGETYPE" == "clone" ]]; then
    IMAGE="$(get_config_value 'image')"
    _template_found=false
    while IFS= read -r _cn; do
        if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@${_cn}.${MGMT}.internal" \
            "qm status ${IMAGE} 2>/dev/null" >/dev/null 2>&1; then
            _template_found=true; break
        fi
    done < <(get_all_node_hostnames)

    if [[ "$_template_found" == "false" ]]; then
        # Look for a template build JSON with this VMID in the templates directory
        _build_json="" _build_module=""
        if [[ -n "$_templates_dir" ]]; then
            for _j in "${_templates_dir}"/*.json; do
                if jq -e --argjson id "$IMAGE" '.vmid == $id' "$_j" >/dev/null 2>&1; then
                    _build_json="$_j"
                    _build_module="$(basename "${_build_json}" .json)"
                    break
                fi
            done
        fi

        if [[ -n "$_build_module" ]]; then
            # Check autoInstall flag — only proceed if the template supports unattended build.
            # Templates that require manual steps (e.g. NixOS graphical installer) set
            # "autoInstall": false and must be built by the operator before cloning.
            _auto_install=$(jq -r '.autoInstall // false' "$_build_json" 2>/dev/null)
            if [[ "$_auto_install" != "true" ]]; then
                die "Template VMID ${IMAGE} (${_build_module}) requires manual installation and cannot be built automatically.
  Build it first, then re-run this install:
    cd ${_templates_dir:-src/foundation/templates} && install-module.sh ${_build_module}
  See: src/foundation/templates/${_build_module}/README.md"
            fi
            info "Template ${IMAGE} not found — auto-building via ${_build_module} (this takes ~30 min)..."
            (cd "${_templates_dir}" && install-module.sh "${_build_module}")
            info "Template ${IMAGE} ready — continuing with VM clone"
        else
            die "Template ${IMAGE} not found on any cluster node.
  To build it manually: cd ${_templates_dir:-src/foundation/templates} && install-module.sh <template-module>"
        fi
    fi
fi

# Copy the VM config and create VM hardware
scp "/home/tappaas/config/$1.json" "root@${NODE}.${MGMT}.internal:/root/tappaas/$1.json"
ssh "root@${NODE}.${MGMT}.internal" "/root/tappaas/Create-TAPPaaS-VM.sh $1"
ssh "root@${NODE}.${MGMT}.internal" "rm /root/tappaas/$1.json"

# For Windows clone VMs: inject OOBE setup via the QEMU guest agent.
# Windows post-sysprep does NOT read answer files from CDROMs — only from
# C:\Windows\Panther\unattend.xml.  We bypass that entirely by running
# PowerShell commands via the guest agent while the VM is booting into OOBE,
# then reboot so the hostname rename and all settings take effect cleanly.
if [[ "$_is_windows" == "true" && "$IMAGETYPE" == "clone" ]]; then
    _pubkey=$(grep 'tappaas-cicd' /home/tappaas/.ssh/authorized_keys 2>/dev/null | head -1 || true)
    if [[ -z "$_pubkey" ]]; then
        _pubkey=$(cat /home/tappaas/.ssh/id_ed25519.pub 2>/dev/null || cat /home/tappaas/.ssh/id_rsa.pub 2>/dev/null || true)
    fi

    info "Injecting Windows OOBE setup via guest agent (hostname: ${VMNAME})..."

    info "Waiting for QEMU guest agent on ${VMNAME}..."
    _ga_elapsed=0; _ga_max=300
    while [[ $_ga_elapsed -lt $_ga_max ]]; do
        if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "root@${NODE}.${MGMT}.internal" \
            "qm guest cmd ${VMID} ping >/dev/null 2>&1"; then
            info "  Guest agent ready"
            break
        fi
        sleep 10; _ga_elapsed=$((_ga_elapsed + 10))
    done

    # Build a PowerShell here-string and encode it as UTF-16LE base64.
    # Using -EncodedCommand avoids ALL shell quoting issues with passwords/keys.
    #
    # NOTE on what can/cannot be done during the OOBE specialize phase:
    #   WORKS:   Registry writes, user creation, file writes, netsh, sshd startup
    #   BROKEN:  Set-NetFirewallRule, Set-NetConnectionProfile, Rename-Computer
    #            — all three get overridden when Windows completes oobeSystem.
    #   SOLUTION: Use netsh advfirewall (direct registry) for SSH port 22 access.
    #             Hostname rename is deferred to templates:windows install-service.sh
    #             (Step 0) which runs after Windows is fully booted via SSH.
    _win_setup_ps=$(printf '%s\n' \
        "\$ErrorActionPreference = 'Continue'" \
        "# Skip OOBE wizard" \
        "\$ok = 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE'" \
        "if (-not (Test-Path \$ok)) { New-Item -Path \$ok -Force | Out-Null }" \
        "New-ItemProperty -Path \$ok -Name SkipMachineOOBE -Value 1 -PropertyType DWord -Force | Out-Null" \
        "New-ItemProperty -Path \$ok -Name SkipUserOOBE   -Value 1 -PropertyType DWord -Force | Out-Null" \
        "# tappaas local admin account" \
        "\$pw = ConvertTo-SecureString '${_tappaas_password}' -AsPlainText -Force" \
        "if (-not (Get-LocalUser tappaas -ErrorAction SilentlyContinue)) {" \
        "    New-LocalUser -Name tappaas -Password \$pw -FullName TAPPaaS -PasswordNeverExpires | Out-Null" \
        "}" \
        "Add-LocalGroupMember -Group Administrators -Member tappaas -ErrorAction SilentlyContinue" \
        "# SSH authorised key (admin users → administrators_authorized_keys)" \
        "\$sd = 'C:\\ProgramData\\ssh'" \
        "New-Item -ItemType Directory -Force -Path \$sd | Out-Null" \
        "[System.IO.File]::WriteAllText(\"\$sd\\administrators_authorized_keys\", \"${_pubkey}\`n\")" \
        "& icacls \"\$sd\\administrators_authorized_keys\" /inheritance:r '/grant' 'NT AUTHORITY\\SYSTEM:(F)' '/grant' 'BUILTIN\\Administrators:(F)' | Out-Null" \
        "# sshd: start and set automatic" \
        "Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue" \
        "Start-Service sshd -ErrorAction SilentlyContinue" \
        "# Firewall: allow port 22 from any network profile." \
        "# netsh advfirewall writes directly to the registry — survives OOBE oobeSystem reset." \
        "# Set-NetFirewallRule and Set-NetConnectionProfile do NOT persist through OOBE." \
        "& netsh advfirewall firewall add rule name='TAPPaaS-SSH' dir=in action=allow protocol=TCP localport=22 profile=any | Out-Null" \
        "# Set Administrator password to the module password and clear the 'must change' flag." \
        "# Without this, Administrator keeps TAPPaaSTemp! (same for all VMs — security risk)." \
        "try { \$a=[ADSI]'WinNT://./Administrator,user'; \$a.SetPassword('${_tappaas_password}'); \$a.PasswordExpired=0; \$a.SetInfo() } catch {}" \
        "Write-Output 'TAPPaaS OOBE setup complete — rebooting'" \
        "Restart-Computer -Force" \
    )
    _win_encoded=$(printf '%s' "$_win_setup_ps" | iconv -t UTF-16LE | base64 -w0)

    ssh "root@${NODE}.${MGMT}.internal" \
        "qm guest exec ${VMID} -- powershell -EncodedCommand ${_win_encoded}" >/dev/null 2>&1 || true

    # Wait for the VM to come back up (reboot: running → stopped → running)
    info "Waiting for VM ${VMNAME} to reboot after OOBE setup..."
    _rb_elapsed=0; _rb_max=180
    # Wait for stopped first (VM shutting down for reboot)
    while [[ $_rb_elapsed -lt $_rb_max ]]; do
        _rb_state=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
            "root@${NODE}.${MGMT}.internal" \
            "qm status ${VMID} 2>/dev/null | awk '{print \$2}'" 2>/dev/null) || _rb_state=""
        [[ "$_rb_state" == "stopped" ]] && break
        sleep 5; _rb_elapsed=$((_rb_elapsed + 5))
    done
    # Then wait for running again
    _rb_elapsed=0
    while [[ $_rb_elapsed -lt $_rb_max ]]; do
        _rb_state=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 \
            "root@${NODE}.${MGMT}.internal" \
            "qm status ${VMID} 2>/dev/null | awk '{print \$2}'" 2>/dev/null) || _rb_state=""
        [[ "$_rb_state" == "running" ]] && break
        sleep 5; _rb_elapsed=$((_rb_elapsed + 5))
    done
    info "  VM ${VMNAME} is back up — SSH will be available once Windows finishes booting"

    # Register DNS: get current IP from guest agent and update the DNS entry.
    # Without this, the hostname resolves to a stale IP after re-installs with a new MAC.
    _vm_ip=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${NODE}.${MGMT}.internal" \
        "qm guest cmd ${VMID} network-get-interfaces 2>/dev/null" \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    # qm guest cmd returns a list directly; qm guest exec wraps in {'result': [...]}
    ifaces = d if isinstance(d, list) else d.get('result', [])
    for iface in ifaces:
        for addr in iface.get('ip-addresses', []):
            ip = addr.get('ip-address', '')
            if addr.get('ip-address-type') == 'ipv4' and not ip.startswith('127.'):
                print(ip); sys.exit(0)
except Exception:
    pass
" 2>/dev/null) || _vm_ip=""

    if [[ -n "$_vm_ip" && -x "$(command -v dns-manager)" ]]; then
        # Pin as a static DHCP reservation (MAC -> IP) so Windows always gets
        # this IP and the record can't drift (#303 sibling). Falls back to a
        # plain host override if the MAC can't be read.
        _mac="$(_vm_net0_mac)"; _macarg=()
        [[ -n "$_mac" ]] && _macarg=(--mac "$_mac")
        dns-manager --no-ssl-verify delete "${VMNAME}" "${ZONE0NAME}.internal" >/dev/null 2>&1 || true
        dns-manager --no-ssl-verify add    "${VMNAME}" "${ZONE0NAME}.internal" "${_vm_ip}" ${_macarg[@]+"${_macarg[@]}"} >/dev/null 2>&1 || true
        info "  ${GN}✓${CL} DNS: ${VMNAME}.${ZONE0NAME}.internal → ${_vm_ip}${_mac:+ (MAC-reserved ${_mac})}"
    fi
fi

# DNS for non-cloud-init APPLIANCE VMs (e.g. HAOS) — issue #303.
# These boot under their own internal hostname (HAOS → "homeassistant"), not
# <vmname>, and have no cloud-init to set it — so they never self-register
# <vmname>.<zone>.internal via their DHCP lease the way cloud-init VMs do (the
# masqdns/Option 2 model). They also boot slowly (HAOS: Linux→Docker→Supervisor
# →Core, 2-5 min), so the guest agent isn't ready immediately. Wait for the IP
# (general loop — returns as soon as the IP appears, so this costs only the
# actual boot time), then pin the DNS record via dns-manager.
# Skipped for cloud-init VMs (they self-register) and for Windows (handled above).
if [[ "$CLOUDINIT" == "false" && "$_is_windows" != "true" ]]; then
    info "Appliance VM (cloudInit:false) — waiting for guest agent IP to register DNS (${VMNAME}.${ZONE0NAME}.internal)..."
    _appliance_ip=""
    _ip_wait=0
    while [[ -z "$_appliance_ip" && $_ip_wait -lt 300 ]]; do
        _appliance_ip=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@${NODE}.${MGMT}.internal" \
            "qm guest cmd ${VMID} network-get-interfaces 2>/dev/null" \
            | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ifaces = d if isinstance(d, list) else d.get('result', [])
    for iface in ifaces:
        for addr in iface.get('ip-addresses', []):
            ip = addr.get('ip-address', '')
            if addr.get('ip-address-type') == 'ipv4' and not ip.startswith('127.') and not ip.startswith('172.'):
                print(ip); sys.exit(0)
except Exception:
    pass
" 2>/dev/null) || _appliance_ip=""
        [[ -n "$_appliance_ip" ]] && break
        sleep 10; _ip_wait=$((_ip_wait + 10))
    done

    if [[ -n "$_appliance_ip" && -x "$(command -v dns-manager)" ]]; then
        # Pin as a static DHCP reservation (MAC -> IP). HAOS leases under its own
        # hostname, so the pin is the only thing resolving <vmname>; a reservation
        # locks the IP so that pin can never go stale on a later lease/reboot
        # (the IP-drift concern). Falls back to a plain host override without MAC.
        _mac="$(_vm_net0_mac)"; _macarg=()
        [[ -n "$_mac" ]] && _macarg=(--mac "$_mac")
        dns-manager --no-ssl-verify delete "${VMNAME}" "${ZONE0NAME}.internal" >/dev/null 2>&1 || true
        dns-manager --no-ssl-verify add    "${VMNAME}" "${ZONE0NAME}.internal" "${_appliance_ip}" ${_macarg[@]+"${_macarg[@]}"} >/dev/null 2>&1 || true
        info "  ${GN}✓${CL} DNS: ${VMNAME}.${ZONE0NAME}.internal → ${_appliance_ip}${_mac:+ (MAC-reserved ${_mac})} (after ${_ip_wait}s)"
    else
        warn "  Could not determine IP for ${VMNAME} after ${_ip_wait}s — DNS NOT registered (VM may still be booting; re-run update-module.sh once it is up)"
    fi
fi

# For ISO-based Windows template builds: start VM, wait for sysprep shutdown,
# delete ISOs, and convert to a Proxmox template.
_PROVIDES=$(read_module_config "$1" 2>/dev/null | jq -r '.provides // [] | .[]' 2>/dev/null) || _PROVIDES=""
if [[ "$IMAGETYPE" == "iso" && "$_is_windows" == "true" ]] && echo "$_PROVIDES" | grep -q "^windows$"; then
    info "Windows template build: starting VM ${VMID} for unattended install (~30 min)..."
    ssh "root@${NODE}.${MGMT}.internal" "qm start ${VMID}" >/dev/null

    # OVMF boot sequence with ms-cert=2023k,pre-enrolled-keys=1:
    #   ~10s  OVMF POST + BDS device scan (scsi0 empty, falls to ide2)
    #   ~15s  Windows EFI bootloader shows "Press any key to boot from CD or DVD......"
    #   ~21s  6-second prompt expires if no key is pressed → falls back to BDS
    # Send a keypress every second from t=12s to t=28s to ensure one lands in the
    # 6-second window regardless of minor timing variation.
    sleep 12
    _kb_end=$(( $(date +%s) + 16 ))
    while [[ $(date +%s) -lt $_kb_end ]]; do
        ssh -n "root@${NODE}.${MGMT}.internal" \
            "printf '%s' '{\"execute\":\"qmp_capabilities\"}{\"execute\":\"send-key\",\"arguments\":{\"keys\":[{\"type\":\"qcode\",\"data\":\"ret\"}]}}' \
             | socat - UNIX-CONNECT:/var/run/qemu-server/${VMID}.qmp" >/dev/null 2>&1 || true
        sleep 1
    done

    _max_wait=3600 _tw_elapsed=0
    while true; do
        _tw_state=$(ssh -n -o BatchMode=yes "root@${NODE}.${MGMT}.internal" \
            "qm status ${VMID} 2>/dev/null | awk '{print \$2}'" 2>/dev/null) || _tw_state=""
        if [[ "$_tw_state" == "stopped" ]]; then
            printf "\r%-70s\n" ""
            info "Windows install and sysprep complete — VM powered off"
            break
        fi
        if [[ $_tw_elapsed -ge $_max_wait ]]; then
            error "Timed out after ${_max_wait}s waiting for Windows template build"
            exit 1
        fi
        printf "\r  Installing Windows + sysprep...  [%dm %02ds elapsed]  " \
            $((_tw_elapsed / 60)) $((_tw_elapsed % 60))
        sleep 30
        _tw_elapsed=$((_tw_elapsed + 30))
    done

    ssh "root@${NODE}.${MGMT}.internal" \
        "qm set ${VMID} --delete ide1,ide2,ide3 2>/dev/null || true" >/dev/null 2>&1 || true
    ssh "root@${NODE}.${MGMT}.internal" "qm template ${VMID}" >/dev/null
    info "Windows Server template VMID ${VMID} is ready for cloning"
fi

echo ""
info "VM ${VMNAME} (VMID: ${VMID}) created successfully on ${NODE}, in Zone: ${ZONE0NAME}"
