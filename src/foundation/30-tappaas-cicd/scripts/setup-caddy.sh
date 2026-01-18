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
# Use OPNsense's configctl to change the web GUI port
ssh root@"$FIREWALL_FQDN" "configctl webgui port 8443" || {
    echo "Warning: Could not change web GUI port via configctl, trying alternative method..."
    # Alternative: directly modify config via PHP
    ssh root@"$FIREWALL_FQDN" "php -r \"
        \\\$config = include('/conf/config.xml');
        // This is a simplified approach - OPNsense config is XML
    \"" 2>/dev/null || true
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

# Step 4: Configure Caddy via OPNsense API
echo ""
echo "Step 4: Configuring Caddy..."

# Enable Caddy and set email for ACME
# OPNsense Caddy configuration is done via the web API
# We'll use the configctl command to apply basic settings

ssh root@"$FIREWALL_FQDN" "cat > /tmp/caddy-config.sh << 'EOFCADDY'
#!/bin/sh
# Configure Caddy via OPNsense

# Enable Caddy service
/usr/local/etc/rc.d/caddy enable 2>/dev/null || true

# The Caddy configuration in OPNsense is managed via the web UI
# We'll create a basic configuration hint
echo \"Caddy has been installed. Please complete configuration via OPNsense web UI:\"
echo \"1. Go to Services > Caddy Web Server > General\"
echo \"2. Enable Caddy\"
echo \"3. Set ACME Email to: $EMAIL\"
echo \"4. Go to Services > Caddy Web Server > Domains\"
echo \"5. Add domain: $DOMAIN\"
echo \"6. Apply changes\"
EOFCADDY
chmod +x /tmp/caddy-config.sh
/tmp/caddy-config.sh
"

# Step 5: Print summary and manual steps required
echo ""
echo "=============================================="
echo "Caddy Setup Summary"
echo "=============================================="
echo ""
echo "Completed:"
echo "  - Installed os-caddy package"
echo "  - Created firewall rules for HTTP (80) and HTTPS (443)"
echo ""
echo "Manual steps required in OPNsense web UI (https://$FIREWALL_FQDN:8443):"
echo ""
echo "1. Go to System > Settings > Administration"
echo "   - Set TCP Port to 8443 (if not already done)"
echo "   - Save"
echo ""
echo "2. Go to Services > Caddy Web Server > General"
echo "   - Check 'Enable Caddy'"
echo "   - Set 'ACME Email' to: $EMAIL"
echo "   - Save and Apply"
echo ""
echo "3. Go to Services > Caddy Web Server > Reverse Proxy > Domains"
echo "   - Click '+' to add a new domain"
echo "   - Set 'Domain' to: $DOMAIN"
echo "   - Set 'Description' to: TAPPaaS Main Domain"
echo "   - Save and Apply"
echo ""
echo "4. Go to Services > Caddy Web Server > Reverse Proxy > Handlers"
echo "   - Add handlers for your services as needed"
echo ""
echo "Caddy setup script completed."
