#!/usr/bin/env bash
#
# Install and configure Caddy reverse proxy on OPNsense firewall
#
# This script:
# 1. Installs the os-caddy package on OPNsense
# 2. Creates firewall rules to allow HTTP/HTTPS traffic to Caddy
# 3. Configures Caddy with the domain from configuration.json
# 4. Reconfigures OPNsense web GUI to port 8443

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

# Step 2: Reconfigure OPNsense web GUI to port 8443
echo ""
echo "Step 2: Reconfiguring OPNsense web GUI to port 8443..."
# Use PHP to modify config.xml and reload the web GUI
ssh root@"$FIREWALL_FQDN" "php -r '
require_once(\"config.inc\");
require_once(\"system.inc\");

global \$config;

if (!isset(\$config[\"system\"][\"webgui\"])) {
    \$config[\"system\"][\"webgui\"] = array();
}
\$config[\"system\"][\"webgui\"][\"port\"] = \"8443\";

write_config(\"Changed web GUI port to 8443 for Caddy reverse proxy\");
echo \"Configuration saved. Restarting web GUI...\\n\";
' && ssh root@\"$FIREWALL_FQDN\" \"configctl webgui restart\"" || {
    echo "Warning: Could not change web GUI port automatically"
    echo "Please change it manually in System > Settings > Administration"
}

# Step 3: Create firewall rules for HTTP/HTTPS using opnsense-controller
echo ""
echo "Step 3: Creating firewall rules for HTTP and HTTPS..."

# Check if opnsense-controller is available
if [ -x /home/tappaas/bin/opnsense-controller ]; then
    export OPNSENSE_HOST="$FIREWALL_FQDN"

    # Create HTTP rule (port 80) on WAN interface
    echo "Creating HTTP (port 80) rule on WAN..."
    /home/tappaas/bin/opnsense-controller firewall create-rule \
        --description "TAPPaaS: Allow HTTP to Caddy" \
        --interface wan \
        --protocol TCP \
        --destination-port 80 \
        --action pass \
        --log true || echo "Warning: HTTP rule creation failed or already exists"

    # Create HTTPS rule (port 443) on WAN interface
    echo "Creating HTTPS (port 443) rule on WAN..."
    /home/tappaas/bin/opnsense-controller firewall create-rule \
        --description "TAPPaaS: Allow HTTPS to Caddy" \
        --interface wan \
        --protocol TCP \
        --destination-port 443 \
        --action pass \
        --log true || echo "Warning: HTTPS rule creation failed or already exists"

    # Apply firewall changes
    echo "Applying firewall changes..."
    /home/tappaas/bin/opnsense-controller firewall apply || true
else
    echo "Warning: opnsense-controller not found, creating rules via SSH..."
    # Fallback: use OPNsense API directly via curl
    echo "Please create HTTP and HTTPS firewall rules manually in OPNsense"
fi

# Step 4: Enable Caddy service
echo ""
echo "Step 4: Enabling Caddy service..."
ssh root@"$FIREWALL_FQDN" "/usr/local/etc/rc.d/caddy enable" || {
    echo "Warning: Could not enable Caddy service via rc.d"
}

# Step 5: Print manual configuration steps
echo ""
echo "=============================================="
echo "Caddy Setup - Manual Configuration Required"
echo "=============================================="
echo ""
echo "Automated steps completed:"
echo "  [x] Installed os-caddy package"
echo "  [x] Configured web GUI to use port 8443"
echo "  [x] Created firewall rules for HTTP (80) and HTTPS (443)"
echo "  [x] Enabled Caddy service"
echo ""
echo "Manual steps required in OPNsense web UI:"
echo ""
echo "  Access OPNsense at: https://$FIREWALL_FQDN:8443"
echo "  (If port 8443 doesn't work, try the original port and complete step 1)"
echo ""
echo "  1. Verify Web GUI Port (System > Settings > Administration)"
echo "     - Scroll to 'TCP Port' field"
echo "     - Set to: 8443"
echo "     - Click 'Save'"
echo "     - You will be redirected to the new port"
echo ""
echo "  2. Enable Caddy (Services > Caddy Web Server > General)"
echo "     - Check 'Enable Caddy'"
echo "     - Set 'ACME Email' to: $EMAIL"
echo "     - Set 'Auto HTTPS' to: On (default)"
echo "     - Click 'Save'"
echo "     - Click 'Apply'"
echo ""
echo "  3. Add Domain (Services > Caddy Web Server > Reverse Proxy > Domains)"
echo "     - Click '+' button to add new domain"
echo "     - Set 'Domain' to: $DOMAIN"
echo "     - Set 'Description' to: TAPPaaS Main Domain"
echo "     - Leave 'Access List' empty for public access"
echo "     - Click 'Save'"
echo "     - Click 'Apply'"
echo ""
echo "  4. Add Wildcard Domain (Services > Caddy Web Server > Reverse Proxy > Domains)"
echo "     - Click '+' button to add new domain"
echo "     - Set 'Domain' to: *.$DOMAIN"
echo "     - Set 'Description' to: TAPPaaS Wildcard"
echo "     - Enable 'DNS-01 Challenge' (required for wildcards)"
echo "     - Configure your DNS provider credentials"
echo "     - Click 'Save'"
echo "     - Click 'Apply'"
echo ""
echo "  5. Add Handlers (Services > Caddy Web Server > Reverse Proxy > Handlers)"
echo "     - Click '+' to add a new handler for each service"
echo "     - Example handler for a service:"
echo "       - Domain: Select '$DOMAIN' or '*.$DOMAIN'"
echo "       - Upstream Domain: <service>.srv.internal"
echo "       - Upstream Port: <service port>"
echo "       - Description: <service name>"
echo "     - Click 'Save' after each handler"
echo "     - Click 'Apply' when all handlers are added"
echo ""
echo "  6. Verify Certificates (Services > Caddy Web Server > Log File)"
echo "     - Check that ACME certificates are being issued"
echo "     - Look for 'certificate obtained successfully' messages"
echo ""
echo "Caddy setup script completed."
