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

FIREWALL_FQDN="firewall.mgmt.internal"
CONFIG_FILE="/home/tappaas/config/configuration.json"

echo "Setting up Caddy reverse proxy on OPNsense firewall..."

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Extract domain and email from configuration.json
if command -v jq &>/dev/null; then
    DOMAIN=$(jq -r '.tappaas.domain' "$CONFIG_FILE")
    EMAIL=$(jq -r '.tappaas.email' "$CONFIG_FILE")
else
    DOMAIN=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['tappaas']['domain'])")
    EMAIL=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['tappaas']['email'])")
fi

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "null" ] || [[ "$DOMAIN" == CHANGE* ]]; then
    echo "Error: Domain not configured in configuration.json"
    echo "Please set tappaas.domain to your actual domain"
    exit 1
fi

if [ -z "$EMAIL" ] || [ "$EMAIL" = "null" ] || [[ "$EMAIL" == CHANGE* ]]; then
    echo "Error: Email not configured in configuration.json"
    echo "Please set tappaas.email to your actual email for Let's Encrypt"
    exit 1
fi

echo "Domain: $DOMAIN"
echo "Email: $EMAIL"

# Check SSH access to firewall
echo ""
echo "Checking SSH access to firewall..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@"$FIREWALL_FQDN" echo "ok" >/dev/null 2>&1; then
    echo "Error: Cannot connect to firewall via SSH"
    echo "Please ensure SSH is enabled and keys are configured"
    exit 1
fi
echo "SSH access confirmed"

# Step 1: Install os-caddy package
echo ""
echo "Step 1: Installing os-caddy package..."
ssh root@"$FIREWALL_FQDN" "pkg install -y os-caddy" || {
    echo "Warning: os-caddy may already be installed or pkg returned non-zero"
}

# Step 2: Reconfigure OPNsense web GUI to port 8443 and disable HTTP redirect
echo ""
echo "Step 2: Reconfiguring OPNsense web GUI to port 8443 and disabling HTTP redirect..."
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
echo "Restarting web GUI..."
ssh root@"$FIREWALL_FQDN" 'configctl webgui restart' || {
    echo "Warning: Could not restart web GUI (this may be expected if port changed)"
    echo "Please verify manually at https://$FIREWALL_FQDN:8443"
}

# Step 3: Create firewall rules for HTTP/HTTPS using opnsense-firewall CLI
echo ""
echo "Step 3: Creating firewall rules for HTTP and HTTPS..."

# Check if opnsense-firewall CLI is available
OPNSENSE_FIREWALL="/home/tappaas/bin/opnsense-firewall"
if [ ! -x "$OPNSENSE_FIREWALL" ]; then
    # Try to find it in the nix profile
    OPNSENSE_FIREWALL=$(command -v opnsense-firewall 2>/dev/null || true)
fi

if [ -x "$OPNSENSE_FIREWALL" ]; then
    # Create HTTP rule (port 80) on WAN interface
    echo "Creating HTTP (port 80) rule on WAN..."
    "$OPNSENSE_FIREWALL" create-rule \
        --firewall "$FIREWALL_FQDN" \
        --no-ssl-verify \
        --description "TAPPaaS: Allow HTTP to Caddy" \
        --interface wan \
        --action pass \
        --protocol tcp \
        --destination-port 80 \
        --log \
        --no-apply || echo "Warning: HTTP rule creation failed or already exists"

    # Create HTTPS rule (port 443) on WAN interface
    echo "Creating HTTPS (port 443) rule on WAN..."
    "$OPNSENSE_FIREWALL" create-rule \
        --firewall "$FIREWALL_FQDN" \
        --no-ssl-verify \
        --description "TAPPaaS: Allow HTTPS to Caddy" \
        --interface wan \
        --action pass \
        --protocol tcp \
        --destination-port 443 \
        --log \
        --no-apply || echo "Warning: HTTPS rule creation failed or already exists"

    # Apply firewall changes
    echo "Applying firewall changes..."
    "$OPNSENSE_FIREWALL" apply \
        --firewall "$FIREWALL_FQDN" \
        --no-ssl-verify || echo "Warning: Could not apply firewall changes"
else
    echo "Warning: opnsense-firewall CLI not found"
    echo "Falling back to SSH/PHP method..."

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
        echo "Warning: Could not create firewall rules automatically"
        echo "Please create HTTP (80) and HTTPS (443) rules manually in OPNsense"
    }

    # Apply firewall filter rules
    echo "Applying firewall filter rules..."
    ssh root@"$FIREWALL_FQDN" 'configctl filter reload' || {
        echo "Warning: Could not reload filter rules"
    }
fi

# Step 4: Enable Caddy, set ACME email, and configure Auto HTTPS
echo ""
echo "Step 4: Enabling Caddy and configuring ACME settings..."

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
echo "Applying Caddy configuration..."
ssh root@"$FIREWALL_FQDN" 'configctl caddy reload' || {
    echo "Warning: Could not reload Caddy service"
}

echo ""
echo "Caddy setup completed successfully."
echo "  OPNsense web UI: https://$FIREWALL_FQDN:8443"
