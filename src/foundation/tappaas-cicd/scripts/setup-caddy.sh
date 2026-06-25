#!/usr/bin/env bash
#
# Install and configure Caddy reverse proxy on OPNsense firewall
#
# This script:
# 1. Installs the os-caddy package on OPNsense
# 2. Installs os-acme-client + os-ddclient (issue #254 — needed for DNS-01
#    wildcard certificates and DynDNS; both additive, non-disruptive)
# 3. Reconfigures OPNsense web GUI to port 8443 (frees 443 for Caddy)
# 4. Creates firewall rules to allow HTTP/HTTPS traffic to Caddy
# 5. Enables Caddy, sets ACME email — DOES NOT configure Caddy's built-in
#    DNS provider (os-caddy >= 2.0.0 stripped all providers except Cloudflare;
#    operators get their wildcard via `acme-setup.sh` instead, see #254)

set -e

. /home/tappaas/bin/common-install-routines.sh

FIREWALL_FQDN="firewall.mgmt.internal"

info "Setting up Caddy reverse proxy on OPNsense firewall..."

# Domain comes from the default environment (config/environments/<env>.json via
# get_variant_config); email from site.json .email (installer_email). Both fall
# back to configuration.json during the phased migration.
DOMAIN="$(jq -r '.domain // empty' <<<"$(get_variant_config "" 2>/dev/null || echo '{}')")"
EMAIL="$(installer_email)"

if [[ -z "$DOMAIN" || "$DOMAIN" == "null" || "$DOMAIN" == CHANGE* ]]; then
    die "Domain not configured. Set domains.primary in config/environments/<env>.json (or tappaas.domain in configuration.json)."
fi

if [[ -z "$EMAIL" || "$EMAIL" == "null" || "$EMAIL" == CHANGE* ]]; then
    die "Email not configured. Set .email in site.json (or tappaas.email in configuration.json) for Let's Encrypt."
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

    # Verify the package actually got installed
    if ! ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg info os-caddy'" &>/dev/null; then
        die "os-caddy package installation failed — package is not present on the firewall."
    fi
fi

# Step 1b: Install os-acme-client + os-ddclient (issue #254).
# These give us wildcard DNS-01 certs via any acme.sh-supported DNS provider
# (os-caddy >= 2.0.0 ships only the Cloudflare provider, so this is how a
# TAPPaaS operator with another DNS provider — or anyone who wants a single
# wildcard for internal services — actually gets a public cert). Both are
# additive: no impact on the running Caddy or webgui.
for pkg in os-acme-client os-ddclient; do
    if ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg info $pkg'" &>/dev/null; then
        debug "  $pkg already installed"
    else
        info "Step 1b: Installing $pkg..."
        ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg install -y $pkg'" 2>&1 \
            | while IFS= read -r _; do printf "."; done || \
            warn "$pkg installation returned non-zero"
        echo ""
        if ! ssh root@"$FIREWALL_FQDN" "/bin/sh -c 'pkg info $pkg'" &>/dev/null; then
            die "$pkg installation failed"
        fi
    fi
done

# Step 1c: Enable os-acme-client plugin (issue #267).
# The plugin ships disabled by default (<enabled>0</enabled> in model.xml); cert
# signing fails with status=400 if the plugin isn't enabled before issuance.
info "Step 1c: Enabling os-acme-client plugin..."
ACME_ENABLE_RESP=$(ssh root@"$FIREWALL_FQDN" \
    "curl -sk -X POST -H 'Content-Type: application/json' \
         -u \"\$(cat /var/db/api_token)\" \
         -d '{\"settings\":{\"enabled\":\"1\"}}' \
         'https://127.0.0.1/api/acmeclient/settings/set'" 2>/dev/null) || true
if echo "$ACME_ENABLE_RESP" | grep -q '"result":"saved"'; then
    debug "  os-acme-client plugin enabled"
    # Reconfigure to apply the change
    ssh root@"$FIREWALL_FQDN" \
        "curl -sk -X POST -H 'Content-Type: application/json' \
             -u \"\$(cat /var/db/api_token)\" \
             'https://127.0.0.1/api/acmeclient/service/reconfigure'" >/dev/null 2>&1 || true
else
    warn "  Could not enable os-acme-client via API (response: ${ACME_ENABLE_RESP:-empty})"
    warn "  The plugin may already be enabled or manual intervention may be required"
fi

# Step 2: Reconfigure OPNsense web GUI to port 8443 and disable HTTP redirect
info "Step 2: Reconfiguring OPNsense web GUI to port 8443..."
# Pipe PHP script via stdin to avoid csh heredoc issues on OPNsense (csh)
ssh root@"$FIREWALL_FQDN" /bin/sh -c 'php /dev/stdin' << 'EOFPHP'
<?php
require_once("config.inc");
require_once("util.inc");

global $config;

if (!isset($config["system"]["webgui"])) {
    $config["system"]["webgui"] = array();
}
$config["system"]["webgui"]["port"] = "8443";
$config["system"]["webgui"]["disablehttpredirect"] = "1";

write_config("Changed web GUI port to 8443 and disabled HTTP redirect for Caddy reverse proxy");
echo "OK\n";
EOFPHP

# Restart web GUI to pick up the new port from config.xml
# (the connection may drop as lighttpd restarts on a different port)
debug "Restarting web GUI on port 8443..."
ssh root@"$FIREWALL_FQDN" 'configctl webgui restart' 2>/dev/null || true
# Wait for the web GUI to come back up on the new port
sleep 3

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
        --destination wanip \
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
        --destination wanip \
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
    ssh root@"$FIREWALL_FQDN" /bin/sh -c 'php /dev/stdin' << 'EOFPHP' || {
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
        "destination" => array("network" => "wanip", "port" => "80"),
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
        "destination" => array("network" => "wanip", "port" => "443"),
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

# Use OPNsense API to enable Caddy and set ACME email.
# The MVC model (OPNsense.Caddy) requires API calls — raw config.xml writes
# don't update the model, so rc.conf.d/caddy won't be regenerated.
CRED_FILE="/home/tappaas/.opnsense-credentials.txt"
if [[ ! -f "$CRED_FILE" ]]; then
    die "OPNsense credentials not found: $CRED_FILE"
fi
API_KEY=$(grep '^key=' "$CRED_FILE" | cut -d= -f2-)
API_SECRET=$(grep '^secret=' "$CRED_FILE" | cut -d= -f2-)
API_BASE="https://${FIREWALL_FQDN}:8443/api"

# Set Caddy general settings via API
debug "Enabling Caddy via API..."
api_result=$(curl -sk -u "${API_KEY}:${API_SECRET}" \
    -X POST "${API_BASE}/caddy/general/set" \
    -H "Content-Type: application/json" \
    -d "{\"caddy\":{\"general\":{\"enabled\":\"1\",\"TlsEmail\":\"${EMAIL}\"}}}" 2>&1) || {
    # If port 8443 isn't ready yet, try default port 443
    debug "Retrying API on port 443..."
    API_BASE="https://${FIREWALL_FQDN}/api"
    api_result=$(curl -sk -u "${API_KEY}:${API_SECRET}" \
        -X POST "${API_BASE}/caddy/general/set" \
        -H "Content-Type: application/json" \
        -d "{\"caddy\":{\"general\":{\"enabled\":\"1\",\"TlsEmail\":\"${EMAIL}\"}}}" 2>&1) || {
        die "Failed to enable Caddy via API: ${api_result}"
    }
}
debug "API response: ${api_result}"

# Apply Caddy settings — reconfigures rc.conf.d, generates Caddyfile, starts service
debug "Applying Caddy configuration via API..."
curl -sk -u "${API_KEY}:${API_SECRET}" \
    -X POST "${API_BASE}/caddy/service/reconfigure" 2>&1 || {
    warn "Could not apply Caddy configuration via API"
}

# Give Caddy a moment to start
sleep 3

# Step 5: Verify Caddy is running
info "Step 5: Verifying Caddy service..."
sleep 2
if ssh root@"$FIREWALL_FQDN" 'configctl caddy status' 2>/dev/null | grep -qi "running"; then
    info "  ${GN}✓${CL} Caddy service is running"
else
    warn "Caddy service does not appear to be running."
    warn "Please check Caddy status in the OPNsense GUI (Services > Caddy)."
fi

echo ""

# Apply the os-caddy ToDomain underscore patch (#237). os-caddy's HostnameField
# default rejects underscored hostnames; the patch adds <IsDNSName>Y</IsDNSName>
# so internal DNS labels like litellm.srvHome.internal work as reverse-proxy
# upstreams. Idempotent; safe to re-run. Must happen NOW (after os-caddy is
# installed) — pre-update.sh also tries to apply it on every update-tappaas,
# but on a FRESH install pre-update.sh runs BEFORE os-caddy exists (Caddy.xml
# doesn't yet) and silently skips. Without this call here, the very first
# network:proxy install of an underscored-zone module (which install.sh runs
# right after this script) would hit the OPNsense ToDomain validator.
PATCH_SCRIPT="/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/opnsense-patch/apply-caddy-isdnsname.sh"
if [[ -f "${PATCH_SCRIPT}" ]]; then
    info "Applying os-caddy ToDomain underscore patch..."
    scp "${PATCH_SCRIPT}" root@"$FIREWALL_FQDN":/tmp/apply-caddy-isdnsname.sh
    ssh root@"$FIREWALL_FQDN" 'sh /tmp/apply-caddy-isdnsname.sh' \
        | while IFS= read -r line; do info "  $line"; done \
        || warn "  os-caddy patch reported an error"
else
    warn "os-caddy patch script not found at ${PATCH_SCRIPT} — underscored upstreams will be rejected by OPNsense"
fi

info "${GN}✓${CL} Caddy setup completed"
info "  OPNsense web UI: https://$FIREWALL_FQDN:8443"
echo ""
info "${BOLD}Next step (TLS):${CL} run ${BL}acme-setup.sh${CL} to obtain a wildcard certificate"
info "  for ${BL}*.${DOMAIN}${CL} via your DNS provider — see INSTALL.md §2.3 (issue #254)."
info "  Without it, modules with proxyTls=dns01 stay reachable on LAN but have no public TLS."
