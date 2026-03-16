#!/usr/bin/env bash
#
# Install and configure Caddy reverse proxy on OPNsense firewall
#
# This script:
# 1. Installs the os-caddy package on OPNsense
# 2. Reconfigures OPNsense web GUI to port 8443 (frees 443 for Caddy)
# 3. Creates firewall rules to allow HTTP/HTTPS traffic to Caddy
# 4. Enables Caddy, sets ACME email, and configures Auto HTTPS

set -e

. /home/tappaas/bin/common-install-routines.sh

FIREWALL_FQDN="firewall.mgmt.internal"
CONFIG_FILE="/home/tappaas/config/configuration.json"

info "Setting up Caddy reverse proxy on OPNsense firewall..."

# Check if configuration file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Configuration file not found: $CONFIG_FILE"
fi

# Extract domain and email from configuration.json
DOMAIN=$(jq -r '.tappaas.domain' "$CONFIG_FILE")
EMAIL=$(jq -r '.tappaas.email' "$CONFIG_FILE")

if [[ -z "$DOMAIN" || "$DOMAIN" == "null" || "$DOMAIN" == CHANGE* ]]; then
    die "Domain not configured in configuration.json. Please set tappaas.domain to your actual domain."
fi

if [[ -z "$EMAIL" || "$EMAIL" == "null" || "$EMAIL" == CHANGE* ]]; then
    die "Email not configured in configuration.json. Please set tappaas.email for Let's Encrypt."
fi

debug "Domain: $DOMAIN"
debug "Email: $EMAIL"

# Check SSH access to firewall
debug "Checking SSH access to firewall..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$FIREWALL_FQDN" echo "ok" >/dev/null 2>&1; then
    die "Cannot connect to firewall via SSH. Please ensure SSH is enabled and keys are configured."
fi
debug "SSH access confirmed"

# Step 1: Install os-caddy package
info "Step 1: Installing os-caddy package..."
if ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg info os-caddy'" &>/dev/null; then
    debug "  os-caddy already installed"
else
    if [[ "${OPT_DEBUG:-0}" -eq 1 ]]; then
        ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg install -y os-caddy'" || {
            warn "os-caddy installation failed or returned non-zero"
        }
    else
        ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg install -y os-caddy'" 2>&1 | while IFS= read -r _; do printf "."; done || {
            echo ""
            warn "os-caddy installation failed or returned non-zero"
        }
        echo ""
    fi
fi

# Step 2: Reconfigure OPNsense web GUI to port 8443 and disable HTTP redirect
info "Step 2: Reconfiguring OPNsense web GUI to port 8443..."
# Write PHP script to temp file and execute (avoids shell quoting issues on BSD/csh)
ssh root@"$FIREWALL_FQDN" 'cat > /tmp/set-webgui-port.php << '\''EOFPHP'\''
<?php
require_once("config.inc");
require_once("system.inc");

global $config;

if (!isset($config["system"]["webgui"])) {
    $config["system"]["webgui"] = array();
}
$config["system"]["webgui"]["port"] = "8443";
$config["system"]["webgui"]["disablehttpredirect"] = "1";

write_config("Changed web GUI port to 8443 and disabled HTTP redirect for Caddy reverse proxy");
echo "Configuration saved.\n";
EOFPHP
php /tmp/set-webgui-port.php && rm /tmp/set-webgui-port.php'

# Restart web GUI separately (connection may drop during restart)
debug "Restarting web GUI..."
ssh root@"$FIREWALL_FQDN" 'configctl webgui restart' || {
    warn "Could not restart web GUI (this may be expected if port changed)"
    warn "Please verify manually at https://$FIREWALL_FQDN:8443"
}

# Step 3: Create firewall rules for HTTP/HTTPS using opnsense-firewall CLI
info "Step 3: Creating firewall rules for HTTP and HTTPS..."

# Check if opnsense-firewall CLI is available
OPNSENSE_FIREWALL="/home/tappaas/bin/opnsense-firewall"
if [[ ! -x "$OPNSENSE_FIREWALL" ]]; then
    # Try to find it in the nix profile
    OPNSENSE_FIREWALL=$(command -v opnsense-firewall 2>/dev/null || true)
fi

if [[ -x "$OPNSENSE_FIREWALL" ]]; then
    # Create HTTP rule (port 80) on WAN interface
    debug "Creating HTTP (port 80) rule on WAN..."
    "$OPNSENSE_FIREWALL" create-rule \
        --firewall "$FIREWALL_FQDN" \
        --no-ssl-verify \
        --description "TAPPaaS: Allow HTTP to Caddy" \
        --interface wan \
        --action pass \
        --protocol tcp \
        --destination-port 80 \
        --log \
        --no-apply || warn "HTTP rule creation failed or already exists"

    # Create HTTPS rule (port 443) on WAN interface
    debug "Creating HTTPS (port 443) rule on WAN..."
    "$OPNSENSE_FIREWALL" create-rule \
        --firewall "$FIREWALL_FQDN" \
        --no-ssl-verify \
        --description "TAPPaaS: Allow HTTPS to Caddy" \
        --interface wan \
        --action pass \
        --protocol tcp \
        --destination-port 443 \
        --log \
        --no-apply || warn "HTTPS rule creation failed or already exists"

    # Apply firewall changes
    debug "Applying firewall changes..."
    "$OPNSENSE_FIREWALL" apply \
        --firewall "$FIREWALL_FQDN" \
        --no-ssl-verify || warn "Could not apply firewall changes"
else
    warn "opnsense-firewall CLI not found, falling back to SSH/PHP method..."

    # Fallback: Create firewall rules using PHP on OPNsense
    ssh root@"$FIREWALL_FQDN" 'cat > /tmp/create-caddy-rules.php << '\''EOFPHP'\''
<?php
require_once("config.inc");
require_once("filter.inc");
require_once("util.inc");

global $config;

if (!isset($config["filter"]["rule"])) {
    $config["filter"]["rule"] = array();
}

$http_exists = false;
$https_exists = false;
foreach ($config["filter"]["rule"] as $rule) {
    if (isset($rule["descr"]) && strpos($rule["descr"], "TAPPaaS: Allow HTTP to Caddy") !== false) {
        $http_exists = true;
    }
    if (isset($rule["descr"]) && strpos($rule["descr"], "TAPPaaS: Allow HTTPS to Caddy") !== false) {
        $https_exists = true;
    }
}

$changed = false;

if (!$http_exists) {
    $config["filter"]["rule"][] = array(
        "type" => "pass",
        "interface" => "wan",
        "ipprotocol" => "inet",
        "protocol" => "tcp",
        "source" => array("any" => true),
        "destination" => array("any" => true, "port" => "80"),
        "descr" => "TAPPaaS: Allow HTTP to Caddy",
        "log" => true,
    );
    echo "Created HTTP (port 80) rule on WAN\n";
    $changed = true;
} else {
    echo "HTTP rule already exists, skipping\n";
}

if (!$https_exists) {
    $config["filter"]["rule"][] = array(
        "type" => "pass",
        "interface" => "wan",
        "ipprotocol" => "inet",
        "protocol" => "tcp",
        "source" => array("any" => true),
        "destination" => array("any" => true, "port" => "443"),
        "descr" => "TAPPaaS: Allow HTTPS to Caddy",
        "log" => true,
    );
    echo "Created HTTPS (port 443) rule on WAN\n";
    $changed = true;
} else {
    echo "HTTPS rule already exists, skipping\n";
}

if ($changed) {
    write_config("Added TAPPaaS Caddy HTTP/HTTPS firewall rules");
    echo "Configuration saved.\n";
}
EOFPHP
php /tmp/create-caddy-rules.php && rm /tmp/create-caddy-rules.php' || {
        warn "Could not create firewall rules automatically"
        warn "Please create HTTP (80) and HTTPS (443) rules manually in OPNsense"
    }

    # Apply firewall filter rules
    debug "Applying firewall filter rules..."
    ssh root@"$FIREWALL_FQDN" 'configctl filter reload' || {
        warn "Could not reload filter rules"
    }
fi

# Step 4: Enable Caddy, set ACME email, and configure Auto HTTPS
info "Step 4: Enabling Caddy and configuring ACME settings..."

# Use PHP to set Caddy plugin general settings in config.xml
# Config path: caddy > general (fields: enabled, TlsEmail, TlsAutoHttps)
ssh root@"$FIREWALL_FQDN" 'cat > /tmp/configure-caddy-general.php << '\''EOFPHP'\''
<?php
require_once("config.inc");

global $config;

if (!isset($config["caddy"])) {
    $config["caddy"] = array();
}
if (!isset($config["caddy"]["general"])) {
    $config["caddy"]["general"] = array();
}

$config["caddy"]["general"]["enabled"] = "1";
$config["caddy"]["general"]["TlsEmail"] = $argv[1];

write_config("Enabled Caddy reverse proxy and set ACME email");
echo "Caddy enabled with ACME email: " . $argv[1] . "\n";
EOFPHP
php /tmp/configure-caddy-general.php "'"$EMAIL"'" && rm /tmp/configure-caddy-general.php'

# Reconfigure Caddy to apply settings
debug "Applying Caddy configuration..."
ssh root@"$FIREWALL_FQDN" 'configctl caddy reload' || {
    warn "Could not reload Caddy service"
}

echo ""
info "${GN}✓${CL} Caddy setup completed"
info "  OPNsense web UI: https://$FIREWALL_FQDN:8443"
