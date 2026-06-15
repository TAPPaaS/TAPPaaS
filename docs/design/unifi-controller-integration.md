# UniFi Controller Integration Design

This document investigates options for deploying a UniFi management solution as a TAPPaaS module and implementing the `unifi.sh` plugin for ADR-008 switch/AP automation.

> **API note (UniFi Network Application v9+):** there is now an **official Network API** — REST, authenticated with an **API key** via the `X-API-KEY` header (Settings → Control Plane → Integrations → Create API Key), base path `https://<host>/proxy/network/integration/v1/...`. Prefer it for inventory/reads and supported device actions. The cookie/CSRF session API documented below (`/api/login` + `/api/s/{site}/...`) is the **legacy, community-reverse-engineered** interface — still functional, and still required for endpoints the official API does not yet cover (e.g. some `port_overrides` writes), but not officially supported. The `unifi.sh` plugin should authenticate via the API key and fall back to the legacy endpoints only where needed.

## Table of Contents

1. [Background](#1-background)
2. [UniFi Controller vs UniFi OS](#2-unifi-controller-vs-unifi-os)
3. [Recommendation](#3-recommendation)
4. [API Investigation](#4-api-investigation)
5. [Plugin Implementation](#5-plugin-implementation)
6. [Module Design](#6-module-design)
7. [References](#7-references)

---

## 1. Background

TAPPaaS needs to manage UniFi switches and access points for:

- **VLAN provisioning** — Configure trunk/access ports with correct VLANs
- **SSID management** — Create/update WiFi networks mapped to zones
- **Device inventory** — Track what's connected where
- **Reconciliation** — Detect drift between desired and actual state

UniFi devices are managed through a central controller. There are two deployment options:

1. **UniFi Network Controller** (formerly UniFi Controller) — Standalone software
2. **UniFi OS** — Integrated OS on UniFi hardware (UDM, UDR, UCG)

### Existing Module Registration

The module catalog already has a placeholder entry for UniFi:

```json
{
    "moduleName": "unifi",
    "repo": "application",
    "moduleJson": "src/apps/unifi/unifi.json",
    "vmid": 810,
    "stack": "infrastructure",
    "category": "network",
    "status": "incomplete"
}
```

This document provides the design to complete this module.

---

## 2. UniFi Controller vs UniFi OS

### 2.1 UniFi Network Controller (Standalone)

The traditional controller is a Java application that can run on any Linux system.

| Aspect | Details |
| ------ | ------- |
| **Deployment** | VM, container, or bare metal |
| **Resource usage** | ~1-2 GB RAM, Java-based |
| **NixOS support** | `services.unifi.enable = true` in nixpkgs |
| **Updates** | Manual or via package manager |
| **API endpoint** | `https://<host>:8443/api` |
| **Multi-site** | Yes |
| **License** | Free |

**Pros:**
- Full control over deployment
- Can run in TAPPaaS mgmt zone
- NixOS has native support
- No additional hardware required

**Cons:**
- Resource overhead (~1.5 GB RAM)
- Java dependency
- Manual firmware distribution

### 2.2 UniFi OS

UniFi OS is Ubiquiti's integrated management platform. It can run on:

1. **Dedicated hardware** — UDM (Dream Machine), UDR (Dream Router), UCG (Cloud Gateway)
2. **Container** — Official `unifi-os` Docker image (since 2024)

| Aspect | Details |
| ------ | ------- |
| **Deployment** | Hardware appliance OR container |
| **Resource usage** | ~2-3 GB RAM (containerized) |
| **Updates** | Automatic via UniFi cloud or manual |
| **API endpoint** | `https://<host>/proxy/network/api` |
| **Multi-site** | Limited (depends on model/license) |
| **License** | Free (container), hardware cost (appliance) |

**Pros:**

- Modern UI/UX (same as hardware appliances)
- Integrated firmware management for adopted devices
- Single unified interface for Network, Protect, Access, etc.
- Container deployment now supported

**Cons:**

- API path differs from standalone Network Controller
- Heavier resource usage than standalone controller
- Container image is relatively new (less community testing)
- Some features require UniFi OS-specific licenses

### 2.3 API Differences

The API is functionally identical, but the **base URL** differs:

| Deployment | API Base URL |
| ---------- | ------------ |
| Standalone Controller | `https://<host>:8443/api` |
| UniFi OS (UDM/UDR/UCG) | `https://<host>/proxy/network/api` |

The plugin must detect which type is in use and adjust the base URL accordingly.

### 2.4 Feature Comparison

| Feature | Network Controller | UniFi OS (Container) | UniFi OS (Hardware) |
| ------- | :----------------: | :------------------: | :-----------------: |
| Switch management | ✅ | ✅ | ✅ |
| AP management | ✅ | ✅ | ✅ |
| VLAN configuration | ✅ | ✅ | ✅ |
| Port profiles | ✅ | ✅ | ✅ |
| SSID management | ✅ | ✅ | ✅ |
| Multi-site | ✅ | Limited | Limited |
| Runs in TAPPaaS | ✅ (NixOS) | ✅ (Container) | ❌ |
| Modern UI | ❌ (classic) | ✅ | ✅ |
| Unified apps | ❌ (network only) | ✅ | ✅ |
| NixOS native | ✅ | ❌ | ❌ |
| Resource usage | ~1.5 GB | ~2-3 GB | N/A |

---

## 3. Recommendation

### Primary: Support Both, Prefer UniFi OS Container for New Deployments

Both deployment types expose the same API (different base paths). The plugin automatically detects which type is in use.

**For new TAPPaaS deployments (recommended):**

- Deploy **UniFi OS as a container** in the `mgmt` zone
- Modern UI, integrated firmware management, future-proof
- Module: `src/apps/unifi/`
- Slightly higher resource usage (~2-3 GB vs ~1.5 GB)

**Alternative: Standalone Network Controller:**

- Deploy as a NixOS service (`services.unifi.enable = true`)
- Lighter resource footprint, NixOS-native
- Classic UI, network-only (no Protect/Access/etc.)
- Good choice if you prefer NixOS-managed packages

**For existing UniFi OS hardware (UDM/UDR/UCG):**

- Use the existing UniFi OS installation
- No additional module needed
- Configure the plugin to point at the hardware appliance

### Plugin Detection Logic

```bash
# In unifi.sh plugin
detect_unifi_type() {
    local host="$1"

    # Try UniFi OS path first (UDM/UDR/UCG)
    if curl -sSk "https://${host}/proxy/network/api" -o /dev/null 2>&1; then
        echo "unifi-os"
        return 0
    fi

    # Try standalone controller path
    if curl -sSk "https://${host}:8443/api" -o /dev/null 2>&1; then
        echo "standalone"
        return 0
    fi

    echo "unknown"
    return 1
}
```

---

## 4. API Investigation

### 4.1 Authentication

UniFi uses cookie-based session authentication. Login returns session cookies that must be included in subsequent requests.

#### Login Request

```bash
# Standalone Controller
curl -sSk -c cookies.txt \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"secret"}' \
    "https://unifi.mgmt.internal:8443/api/login"

# UniFi OS
curl -sSk -c cookies.txt \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"secret"}' \
    "https://192.168.1.1/api/auth/login"
```

#### Response

```json
{
    "meta": {"rc": "ok"},
    "data": []
}
```

The response sets cookies:
- `unifises` — Session ID
- `csrf_token` — CSRF token (required for POST/PUT/DELETE on UniFi OS)

### 4.2 Site Selection

UniFi supports multi-site configurations. Most home/SMB deployments use the `default` site.

```bash
# List sites
curl -sSk -b cookies.txt \
    "https://unifi.mgmt.internal:8443/api/self/sites"
```

Response:
```json
{
    "meta": {"rc": "ok"},
    "data": [
        {"_id": "...", "name": "default", "desc": "Default"}
    ]
}
```

### 4.3 Device Management

#### List All Devices

```bash
curl -sSk -b cookies.txt \
    "https://unifi.mgmt.internal:8443/api/s/default/stat/device"
```

Response includes switches, APs, gateways with full configuration:

```json
{
    "meta": {"rc": "ok"},
    "data": [
        {
            "_id": "abc123",
            "mac": "aa:bb:cc:dd:ee:ff",
            "model": "USW-Pro-48-PoE",
            "name": "core-switch-1",
            "type": "usw",
            "ip": "10.0.0.20",
            "port_table": [
                {
                    "port_idx": 1,
                    "media": "GE",
                    "poe_caps": 7,
                    "speed": 1000,
                    "up": true,
                    "portconf_id": "profile_id_here"
                }
            ]
        }
    ]
}
```

#### Get Specific Device

```bash
curl -sSk -b cookies.txt \
    "https://unifi.mgmt.internal:8443/api/s/default/stat/device/aa:bb:cc:dd:ee:ff"
```

### 4.4 Network (VLAN) Management

#### List Networks

```bash
curl -sSk -b cookies.txt \
    "https://unifi.mgmt.internal:8443/api/s/default/rest/networkconf"
```

Response:
```json
{
    "meta": {"rc": "ok"},
    "data": [
        {
            "_id": "net_home_id",
            "name": "home",
            "vlan": 310,
            "purpose": "vlan-only",
            "enabled": true,
            "vlan_enabled": true
        }
    ]
}
```

#### Create Network (VLAN)

```bash
curl -sSk -b cookies.txt \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "name": "guest",
        "vlan": 500,
        "purpose": "vlan-only",
        "enabled": true,
        "vlan_enabled": true
    }' \
    "https://unifi.mgmt.internal:8443/api/s/default/rest/networkconf"
```

### 4.5 Port Profile Management

Port profiles define VLAN configurations that can be applied to switch ports.

#### List Port Profiles

```bash
curl -sSk -b cookies.txt \
    "https://unifi.mgmt.internal:8443/api/s/default/rest/portconf"
```

Response:
```json
{
    "meta": {"rc": "ok"},
    "data": [
        {
            "_id": "profile_trunk_all",
            "name": "TAPPaaS-Trunk-All",
            "forward": "customize",
            "native_networkconf_id": "",
            "tagged_networkconf_ids": ["net_mgmt", "net_home", "net_work", "..."]
        },
        {
            "_id": "profile_access_home",
            "name": "TAPPaaS-Access-Home",
            "forward": "native",
            "native_networkconf_id": "net_home_id"
        }
    ]
}
```

#### Create Port Profile

```bash
# Trunk profile (all VLANs tagged)
curl -sSk -b cookies.txt \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "name": "TAPPaaS-Trunk-All",
        "forward": "customize",
        "native_networkconf_id": "",
        "tagged_networkconf_ids": ["net_id_1", "net_id_2", "net_id_3"]
    }' \
    "https://unifi.mgmt.internal:8443/api/s/default/rest/portconf"

# Access profile (single VLAN untagged)
curl -sSk -b cookies.txt \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "name": "TAPPaaS-Access-Home",
        "forward": "native",
        "native_networkconf_id": "net_home_id"
    }' \
    "https://unifi.mgmt.internal:8443/api/s/default/rest/portconf"
```

### 4.6 Apply Port Profile to Switch Port

```bash
curl -sSk -b cookies.txt \
    -X PUT \
    -H "Content-Type: application/json" \
    -d '{
        "port_overrides": [
            {
                "port_idx": 1,
                "portconf_id": "profile_trunk_all"
            },
            {
                "port_idx": 10,
                "portconf_id": "profile_access_home"
            }
        ]
    }' \
    "https://unifi.mgmt.internal:8443/api/s/default/rest/device/DEVICE_ID"
```

### 4.7 WLAN (SSID) Management

#### List WLANs

```bash
curl -sSk -b cookies.txt \
    "https://unifi.mgmt.internal:8443/api/s/default/rest/wlanconf"
```

#### Create WLAN

```bash
curl -sSk -b cookies.txt \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{
        "name": "TAPPaaS-Home",
        "security": "wpapsk",
        "wpa_mode": "wpa3",
        "x_passphrase": "wifi-password-here",
        "networkconf_id": "net_home_id",
        "enabled": true,
        "hide_ssid": false
    }' \
    "https://unifi.mgmt.internal:8443/api/s/default/rest/wlanconf"
```

### 4.8 Error Handling

API errors return:
```json
{
    "meta": {
        "rc": "error",
        "msg": "api.err.InvalidPayload"
    },
    "data": []
}
```

Common error codes:
- `api.err.LoginRequired` — Session expired, re-login needed
- `api.err.InvalidPayload` — Malformed request body
- `api.err.NoPermission` — User lacks required permissions
- `api.err.ObjectNotFound` — Device/network/profile not found

---

## 5. Plugin Implementation

### 5.1 Plugin Structure

```bash
src/foundation/firewall/scripts/plugins/
└── unifi.sh
```

### 5.2 Full Plugin Implementation

```bash
#!/usr/bin/env bash
# Plugin: unifi.sh — UniFi Network Controller/OS automation
#
# Supports both standalone UniFi Network Controller and UniFi OS (UDM/UDR/UCG).
# Automatically detects the deployment type and adjusts API paths accordingly.

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
UNIFI_HOST="${UNIFI_HOST:-unifi.mgmt.internal}"
UNIFI_SITE="${UNIFI_SITE:-default}"
UNIFI_USER="${UNIFI_USER:-}"
UNIFI_PASS="${UNIFI_PASS:-}"
COOKIE_JAR="/tmp/unifi-cookies-$$.txt"

# ── Internal State ───────────────────────────────────────────────────────────
_UNIFI_TYPE=""       # "standalone" or "unifi-os"
_UNIFI_BASE_URL=""   # Computed base URL
_CSRF_TOKEN=""       # For UniFi OS

# ── Helpers ──────────────────────────────────────────────────────────────────

_cleanup() {
    rm -f "$COOKIE_JAR" 2>/dev/null || true
}
trap _cleanup EXIT

_detect_type() {
    # Try UniFi OS first (responds on /api/auth)
    if curl -sSk --connect-timeout 5 "https://${UNIFI_HOST}/api" -o /dev/null 2>&1; then
        _UNIFI_TYPE="unifi-os"
        _UNIFI_BASE_URL="https://${UNIFI_HOST}/proxy/network"
        return 0
    fi

    # Try standalone controller
    if curl -sSk --connect-timeout 5 "https://${UNIFI_HOST}:8443/api" -o /dev/null 2>&1; then
        _UNIFI_TYPE="standalone"
        _UNIFI_BASE_URL="https://${UNIFI_HOST}:8443"
        return 0
    fi

    echo "ERROR: Cannot detect UniFi type at ${UNIFI_HOST}" >&2
    return 1
}

_login() {
    local response

    if [[ "$_UNIFI_TYPE" == "unifi-os" ]]; then
        # UniFi OS uses a different login endpoint
        response=$(curl -sSk -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"$UNIFI_USER\",\"password\":\"$UNIFI_PASS\"}" \
            "https://${UNIFI_HOST}/api/auth/login")

        # Extract CSRF token from cookies
        _CSRF_TOKEN=$(grep -oP 'csrf_token\s+\K\S+' "$COOKIE_JAR" 2>/dev/null || true)
    else
        # Standalone controller
        response=$(curl -sSk -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"$UNIFI_USER\",\"password\":\"$UNIFI_PASS\"}" \
            "${_UNIFI_BASE_URL}/api/login")
    fi

    # Check for login success
    if ! echo "$response" | jq -e '.meta.rc == "ok"' >/dev/null 2>&1; then
        echo "ERROR: UniFi login failed: $(echo "$response" | jq -r '.meta.msg // "unknown error"')" >&2
        return 1
    fi
}

_api_get() {
    local endpoint="$1"
    curl -sSk -b "$COOKIE_JAR" \
        -H "Content-Type: application/json" \
        ${_CSRF_TOKEN:+-H "X-CSRF-Token: $_CSRF_TOKEN"} \
        "${_UNIFI_BASE_URL}${endpoint}"
}

_api_post() {
    local endpoint="$1"
    local data="$2"
    curl -sSk -b "$COOKIE_JAR" \
        -X POST \
        -H "Content-Type: application/json" \
        ${_CSRF_TOKEN:+-H "X-CSRF-Token: $_CSRF_TOKEN"} \
        -d "$data" \
        "${_UNIFI_BASE_URL}${endpoint}"
}

_api_put() {
    local endpoint="$1"
    local data="$2"
    curl -sSk -b "$COOKIE_JAR" \
        -X PUT \
        -H "Content-Type: application/json" \
        ${_CSRF_TOKEN:+-H "X-CSRF-Token: $_CSRF_TOKEN"} \
        -d "$data" \
        "${_UNIFI_BASE_URL}${endpoint}"
}

# ── Plugin Interface ─────────────────────────────────────────────────────────

plugin_supports() {
    local vendor="$1"
    [[ "$vendor" == "unifi" ]]
}

plugin_init() {
    # Load credentials from TAPPaaS secrets
    if [[ -f /etc/secrets/unifi.env ]]; then
        # shellcheck source=/dev/null
        source /etc/secrets/unifi.env
    fi

    [[ -n "$UNIFI_USER" ]] || { echo "ERROR: UNIFI_USER not set" >&2; return 1; }
    [[ -n "$UNIFI_PASS" ]] || { echo "ERROR: UNIFI_PASS not set" >&2; return 1; }

    _detect_type || return 1
    _login || return 1

    echo "Connected to UniFi (${_UNIFI_TYPE}) at ${UNIFI_HOST}"
}

plugin_interrogate() {
    local switch_name="$1"

    # Get all devices
    local devices
    devices=$(_api_get "/api/s/${UNIFI_SITE}/stat/device")

    # Find the specific switch by name
    local switch_data
    switch_data=$(echo "$devices" | jq --arg name "$switch_name" \
        '.data[] | select(.name == $name and .type == "usw")')

    if [[ -z "$switch_data" || "$switch_data" == "null" ]]; then
        echo "ERROR: Switch '$switch_name' not found in UniFi" >&2
        return 1
    fi

    # Get port profiles for mapping
    local profiles
    profiles=$(_api_get "/api/s/${UNIFI_SITE}/rest/portconf")

    # Get networks for VLAN mapping
    local networks
    networks=$(_api_get "/api/s/${UNIFI_SITE}/rest/networkconf")

    # Build standardized output
    jq -n \
        --argjson switch "$switch_data" \
        --argjson profiles "$profiles" \
        --argjson networks "$networks" \
        '{
            name: $switch.name,
            mac: $switch.mac,
            model: $switch.model,
            ip: $switch.ip,
            ports: (
                $switch.port_table | map({
                    port_idx: .port_idx,
                    up: .up,
                    speed: .speed,
                    portconf_id: .portconf_id,
                    poe_mode: .poe_mode
                }) | INDEX(.port_idx)
            ),
            profiles: ($profiles.data | map({key: ._id, value: .}) | from_entries),
            networks: ($networks.data | map({key: ._id, value: {name: .name, vlan: .vlan}}) | from_entries)
        }'
}

plugin_apply() {
    local switch_name="$1"
    local delta_json="$2"

    local success=true

    # Get switch device ID
    local devices
    devices=$(_api_get "/api/s/${UNIFI_SITE}/stat/device")
    local device_id
    device_id=$(echo "$devices" | jq -r --arg name "$switch_name" \
        '.data[] | select(.name == $name and .type == "usw") | ._id')

    if [[ -z "$device_id" ]]; then
        echo "ERROR: Switch '$switch_name' not found" >&2
        return 1
    fi

    # Process each change
    echo "$delta_json" | jq -c '.changes[]' | while read -r change; do
        local action
        action=$(echo "$change" | jq -r '.action')

        case "$action" in
            create_network)
                local name vlan
                name=$(echo "$change" | jq -r '.name')
                vlan=$(echo "$change" | jq -r '.vlan')

                echo "Creating network: $name (VLAN $vlan)"
                local response
                response=$(_api_post "/api/s/${UNIFI_SITE}/rest/networkconf" \
                    "{\"name\":\"$name\",\"vlan\":$vlan,\"purpose\":\"vlan-only\",\"enabled\":true,\"vlan_enabled\":true}")

                if ! echo "$response" | jq -e '.meta.rc == "ok"' >/dev/null; then
                    echo "ERROR: Failed to create network $name" >&2
                    success=false
                fi
                ;;

            create_profile)
                local profile_name native_id tagged_ids
                profile_name=$(echo "$change" | jq -r '.name')
                native_id=$(echo "$change" | jq -r '.native_network_id // ""')
                tagged_ids=$(echo "$change" | jq -c '.tagged_network_ids // []')

                echo "Creating port profile: $profile_name"
                local payload
                if [[ -n "$native_id" && "$native_id" != "null" ]]; then
                    payload="{\"name\":\"$profile_name\",\"forward\":\"native\",\"native_networkconf_id\":\"$native_id\"}"
                else
                    payload="{\"name\":\"$profile_name\",\"forward\":\"customize\",\"native_networkconf_id\":\"\",\"tagged_networkconf_ids\":$tagged_ids}"
                fi

                local response
                response=$(_api_post "/api/s/${UNIFI_SITE}/rest/portconf" "$payload")

                if ! echo "$response" | jq -e '.meta.rc == "ok"' >/dev/null; then
                    echo "ERROR: Failed to create profile $profile_name" >&2
                    success=false
                fi
                ;;

            apply_profile)
                local port_idx profile_id
                port_idx=$(echo "$change" | jq -r '.port_idx')
                profile_id=$(echo "$change" | jq -r '.profile_id')

                echo "Applying profile to port $port_idx"

                # Get current port overrides
                local current_overrides
                current_overrides=$(echo "$devices" | jq --arg name "$switch_name" \
                    '.data[] | select(.name == $name) | .port_overrides // []')

                # Update or add the override
                local new_overrides
                new_overrides=$(echo "$current_overrides" | jq \
                    --argjson port "$port_idx" \
                    --arg profile "$profile_id" \
                    '(map(select(.port_idx != $port))) + [{"port_idx": $port, "portconf_id": $profile}]')

                local response
                response=$(_api_put "/api/s/${UNIFI_SITE}/rest/device/${device_id}" \
                    "{\"port_overrides\":$new_overrides}")

                if ! echo "$response" | jq -e '.meta.rc == "ok"' >/dev/null; then
                    echo "ERROR: Failed to apply profile to port $port_idx" >&2
                    success=false
                fi
                ;;

            *)
                echo "WARNING: Unknown action: $action" >&2
                ;;
        esac
    done

    $success
}

# ── Main (for testing) ───────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        test)
            plugin_init
            echo "Interrogating switch: ${2:-core-switch-1}"
            plugin_interrogate "${2:-core-switch-1}"
            ;;
        *)
            echo "Usage: $0 test [switch-name]"
            ;;
    esac
fi
```

### 5.3 Credential Storage

Credentials are stored in TAPPaaS secrets:

```bash
# /etc/secrets/unifi.env
UNIFI_HOST="unifi.mgmt.internal"
UNIFI_USER="tappaas-admin"
UNIFI_PASS="<generated-password>"
UNIFI_SITE="default"
```

The identity module generates these credentials during UniFi controller installation.

---

## 6. Module Design

### 6.1 Module Location

Per the module catalog, the UniFi module lives at:

```
src/apps/unifi/
├── unifi.json                # Module metadata
├── unifi.nix                 # NixOS configuration
├── install.sh                # Installation script
├── update.sh                 # Update script
├── test.sh                   # Test script
└── README.md                 # Documentation
```

### 6.2 Module JSON

```json
{
    "description": "UniFi Network Controller for managing UniFi switches and APs",
    "version": "8.x",
    "vmname": "unifi",
    "vmid": 810,
    "vmtag": "TAPPaaS,Infrastructure",
    "zone0": "mgmt",
    "cores": 2,
    "memory": "2048",
    "diskSize": "32G",
    "dependsOn": ["nixos", "firewall"],
    "provides": ["unifi"],
    "config": {
        "cluster:vm": {
            "storage": "tanka1",
            "onboot": "1",
            "startdelay": 60
        }
    }
}
```

### 6.3 NixOS Configuration

```nix
{ config, pkgs, lib, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    /etc/nixos/tappaas-common.nix
  ];

  networking.hostName = "unifi";
  networking.firewall.allowedTCPPorts = [ 8443 8080 8843 8880 6789 ];
  networking.firewall.allowedUDPPorts = [ 3478 10001 ];

  services.unifi = {
    enable = true;
    unifiPackage = pkgs.unifi8;
    openFirewall = true;

    # Store data on persistent volume
    dataDir = "/var/lib/unifi";
  };

  # MongoDB is required by UniFi
  services.mongodb = {
    enable = true;
    dbpath = "/var/lib/mongodb";
  };

  # Increase Java heap for larger deployments
  systemd.services.unifi.environment = {
    JAVA_HOME = "${pkgs.jdk11}";
    JVM_INIT_HEAP_SIZE = "256M";
    JVM_MAX_HEAP_SIZE = "1024M";
  };

  system.stateVersion = "25.05";
}
```

### 6.4 Installation Script

```bash
#!/usr/bin/env bash
# install.sh — Install UniFi Network Controller

set -euo pipefail
source /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_JSON="${SCRIPT_DIR}/unifi.json"

# Standard TAPPaaS module installation
install_nixos_module "$MODULE_JSON"

# Wait for UniFi to start
info "Waiting for UniFi Controller to start..."
wait_for_port "unifi.mgmt.internal" 8443 120

# Generate API credentials
info "Generating UniFi API credentials..."
UNIFI_PASS=$(generate_password 24)

# Create admin user via UniFi setup wizard API
# (This is done on first access; we pre-configure it)
cat > /etc/secrets/unifi.env <<EOF
UNIFI_HOST=unifi.mgmt.internal
UNIFI_USER=tappaas-admin
UNIFI_PASS=${UNIFI_PASS}
UNIFI_SITE=default
EOF

chmod 600 /etc/secrets/unifi.env

info "UniFi Controller installed successfully"
info "Access UI: https://unifi.mgmt.internal:8443"
info "API credentials stored in /etc/secrets/unifi.env"
```

---

## 7. References

### 7.1 Official Documentation

- [UniFi Network Controller Manual](https://help.ui.com/hc/en-us/categories/200320654-UniFi-Network)
- [UniFi OS Documentation](https://help.ui.com/hc/en-us/articles/360049859754)

### 7.2 API Resources

- [UniFi API Browser](https://ubntwiki.com/products/software/unifi-controller/api) — Community documentation
- [Art-of-WiFi UniFi API Client (PHP)](https://github.com/Art-of-WiFi/UniFi-API-client) — Reference implementation
- [unifi-poller](https://github.com/unpoller/unpoller) — Go client for metrics
- [node-unifi](https://github.com/jens-maus/node-unifi) — Node.js client

### 7.3 NixOS

- [NixOS UniFi Module](https://search.nixos.org/options?query=services.unifi)
- [nixpkgs unifi package](https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/unifi/default.nix)

### 7.4 Example Code Repositories

| Repository | Language | Notes |
| ---------- | -------- | ----- |
| [Art-of-WiFi/UniFi-API-client](https://github.com/Art-of-WiFi/UniFi-API-client) | PHP | Most comprehensive, good reference |
| [unpoller/unpoller](https://github.com/unpoller/unpoller) | Go | Production-quality, metrics focus |
| [jens-maus/node-unifi](https://github.com/jens-maus/node-unifi) | Node.js | Well-maintained |
| [finish06/pyunifi](https://github.com/finish06/pyunifi) | Python | Simple, readable |
| [jacobalberty/unifi-docker](https://github.com/jacobalberty/unifi-docker) | Docker | Deployment reference |

---

## Appendix: API Quick Reference

### Authentication

| Endpoint | Method | Description |
| -------- | ------ | ----------- |
| `/api/login` | POST | Login (standalone) |
| `/api/auth/login` | POST | Login (UniFi OS) |
| `/api/logout` | POST | Logout |

### Devices

| Endpoint | Method | Description |
| -------- | ------ | ----------- |
| `/api/s/{site}/stat/device` | GET | List all devices |
| `/api/s/{site}/stat/device/{mac}` | GET | Get specific device |
| `/api/s/{site}/rest/device/{id}` | PUT | Update device config |

### Networks

| Endpoint | Method | Description |
| -------- | ------ | ----------- |
| `/api/s/{site}/rest/networkconf` | GET | List networks |
| `/api/s/{site}/rest/networkconf` | POST | Create network |
| `/api/s/{site}/rest/networkconf/{id}` | PUT | Update network |
| `/api/s/{site}/rest/networkconf/{id}` | DELETE | Delete network |

### Port Profiles

| Endpoint | Method | Description |
| -------- | ------ | ----------- |
| `/api/s/{site}/rest/portconf` | GET | List profiles |
| `/api/s/{site}/rest/portconf` | POST | Create profile |
| `/api/s/{site}/rest/portconf/{id}` | PUT | Update profile |
| `/api/s/{site}/rest/portconf/{id}` | DELETE | Delete profile |

### WLANs

| Endpoint | Method | Description |
| -------- | ------ | ----------- |
| `/api/s/{site}/rest/wlanconf` | GET | List WLANs |
| `/api/s/{site}/rest/wlanconf` | POST | Create WLAN |
| `/api/s/{site}/rest/wlanconf/{id}` | PUT | Update WLAN |
| `/api/s/{site}/rest/wlanconf/{id}` | DELETE | Delete WLAN |
