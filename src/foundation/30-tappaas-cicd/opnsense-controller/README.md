# OPNsense Controller

OPNsense controller for TAPPaaS using the `oxl-opnsense-client` library.

## CLI Tools

This package provides four command-line tools:

| Command | Description |
|---------|-------------|
| `opnsense-controller` | Main CLI with examples for VLANs, DHCP, and firewall management |
| `opnsense-firewall` | Standalone firewall rule management (create, list, delete rules) |
| `dns-manager` | DNS host entry management for Dnsmasq |
| `zone-manager` | Automated zone configuration from zones.json |

## Requirements

- Nix package manager
- OPNsense firewall with API access enabled
- Custom PHP extension for interface assignment (optional, see below)

## Quick Start

```bash
# Build the project
nix-build -A default default.nix

# Or enter a development shell
nix-shell -A shell default.nix

# Run with defaults (firewall.mgmt.internal, credentials from ~/.opnsense-credentials.txt)
./result/bin/opnsense-controller --no-ssl-verify --example test
```

## Configuration

### Credential File (Recommended)

The controller looks for credentials in `$HOME/.opnsense-credentials.txt` by default:

```bash
cp credentials.example.txt ~/.opnsense-credentials.txt
chmod 600 ~/.opnsense-credentials.txt
# Edit with your token (line 1) and secret (line 2)
```

The credential file format is:
```
your-api-token
your-api-secret
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OPNSENSE_HOST` | Firewall IP/hostname | `firewall.mgmt.internal` (via CLI) |
| `OPNSENSE_CREDENTIAL_FILE` | Path to credentials file | `$HOME/.opnsense-credentials.txt` |
| `OPNSENSE_TOKEN` | API token (alternative to credential file) | - |
| `OPNSENSE_SECRET` | API secret (alternative to credential file) | - |
| `OPNSENSE_SSL_VERIFY` | Set to `false` to disable SSL verification | `true` |
| `OPNSENSE_SSL_CA_FILE` | Path to custom CA certificate | - |
| `OPNSENSE_DEBUG` | Set to `true` to enable debug logging | `false` |
| `OPNSENSE_API_TIMEOUT` | API timeout in seconds | `30` |
| `OPNSENSE_API_RETRIES` | Number of retries for failed requests | `3` |

### Creating API Credentials in OPNsense

1. Log into OPNsense web interface
2. Go to **System > Access > Users**
3. Edit your user or create a new one
4. Under **API keys**, click **+** to generate a key
5. Save the key and secret to your credentials file

## CLI Usage

### VLAN Examples

```bash
# Show help
./result/bin/opnsense-controller --help

# Test connection
./result/bin/opnsense-controller --no-ssl-verify --example test

# Show assigned VLANs
./result/bin/opnsense-controller --no-ssl-verify --example assigned

# Create a VLAN (dry-run mode by default)
./result/bin/opnsense-controller --no-ssl-verify --example create

# Create a VLAN and execute changes
./result/bin/opnsense-controller --no-ssl-verify --execute --example create

# Create a VLAN, assign to interface, and enable (requires PHP extension)
./result/bin/opnsense-controller --no-ssl-verify --execute --assign --example create

# Use a different firewall
./result/bin/opnsense-controller --firewall 10.0.0.1 --no-ssl-verify --example test

# Use a specific credential file
./result/bin/opnsense-controller --credential-file /path/to/creds.txt --example test

# Enable debug output
./result/bin/opnsense-controller --debug --no-ssl-verify --example test
```

### DHCP Examples

```bash
# Test DHCP manager connection
./result/bin/opnsense-controller --mode dhcp --no-ssl-verify --example test

# Show DHCP module specifications
./result/bin/opnsense-controller --mode dhcp --no-ssl-verify --example spec

# Create a DHCP range (dry-run)
./result/bin/opnsense-controller --mode dhcp --no-ssl-verify --example range

# Create multiple DHCP ranges (execute)
./result/bin/opnsense-controller --mode dhcp --no-ssl-verify --execute --example range-multi

# Create a static DHCP host reservation
./result/bin/opnsense-controller --mode dhcp --no-ssl-verify --execute --example host

# Create multiple static DHCP hosts
./result/bin/opnsense-controller --mode dhcp --no-ssl-verify --execute --example host-multi

# Enable Dnsmasq DHCP service
./result/bin/opnsense-controller --mode dhcp --no-ssl-verify --execute --example enable

# Configure general Dnsmasq settings
./result/bin/opnsense-controller --mode dhcp --no-ssl-verify --execute --example config
```

### Firewall Examples

```bash
# Test firewall manager connection
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --example test

# Show firewall rule module specification
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --example spec

# List all firewall rules
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --example list

# Create a firewall rule (dry-run)
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --example create

# Create a firewall rule (execute)
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --execute --example create

# Create multiple firewall rules
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --execute --example create-multi

# Delete a firewall rule
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --execute --example delete

# Create allow rule (convenience method)
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --execute --example allow

# Create block rule (convenience method)
./result/bin/opnsense-controller --mode firewall --no-ssl-verify --execute --example block
```

## CLI Options

| Option | Description |
|--------|-------------|
| `--firewall HOST` | Firewall IP/hostname (default: `firewall.mgmt.internal`) |
| `--credential-file PATH` | Path to credential file |
| `--no-ssl-verify` | Disable SSL certificate verification |
| `--debug` | Enable debug logging |
| `--execute` | Actually execute changes (default is dry-run mode) |
| `--mode MODE` | Which manager to use: `vlan`, `dhcp`, or `firewall` (default: `vlan`) |
| `--assign` | Assign created VLANs to interfaces and enable them |
| `--interface NAME` | Parent interface for VLAN examples (default: `vtnet0`) |
| `--example NAME` | Which example to run (default: `all`) |

## Examples

### VLAN Examples (`--mode vlan`, default)

| Example | Description |
|---------|-------------|
| `test` | Test connection to firewall |
| `list` | List available interface modules |
| `spec` | Show VLAN module specification |
| `assigned` | Show VLANs that are assigned to interfaces |
| `create` | Create single VLAN (Management VLAN tag 10) |
| `create-multi` | Create multiple VLANs (Management, Servers, Workstations, IoT, Guest, DMZ) |
| `update` | Update VLAN priority |
| `delete` | Delete a VLAN |
| `all` | Run all examples (default) |

### DHCP Examples (`--mode dhcp`)

| Example | Description |
|---------|-------------|
| `test` | Test connection to firewall |
| `spec` | Show Dnsmasq DHCP module specifications |
| `range` | Create single DHCP range (Server Network) |
| `range-multi` | Create multiple DHCP ranges (Private, IoT, DMZ networks) |
| `host` | Create single static DHCP host reservation |
| `host-multi` | Create multiple static DHCP host reservations |
| `delete-host` | Delete a DHCP host reservation |
| `enable` | Enable Dnsmasq DHCP service |
| `config` | Configure general Dnsmasq settings |
| `all` | Run all DHCP examples (default) |

### Firewall Examples (`--mode firewall`)

| Example | Description |
|---------|-------------|
| `test` | Test connection to firewall |
| `spec` | Show firewall rule module specification |
| `list` | List all firewall rules |
| `create` | Create single firewall rule (Allow SSH) |
| `create-multi` | Create multiple firewall rules (DNS, HTTP, HTTPS, Block) |
| `delete` | Delete a firewall rule |
| `allow` | Create allow rule using convenience method |
| `block` | Create block rule using convenience method |
| `all` | Run all firewall examples (default) |

### Firewall CLI (`opnsense-firewall` command)

The Firewall CLI provides a dedicated command-line interface for managing firewall rules on OPNsense. This is the recommended tool for scripted firewall management.

#### CLI Usage

```bash
# Test connection to OPNsense
opnsense-firewall test --no-ssl-verify

# Create a firewall rule (allow HTTPS on WAN)
opnsense-firewall create-rule \
    --no-ssl-verify \
    --description "Allow HTTPS" \
    --interface wan \
    --protocol tcp \
    --destination-port 443

# Create a rule without applying immediately
opnsense-firewall create-rule \
    --no-ssl-verify \
    --description "Allow HTTP" \
    --interface wan \
    --protocol tcp \
    --destination-port 80 \
    --no-apply

# List all firewall rules
opnsense-firewall list-rules --no-ssl-verify

# List rules matching a search pattern
opnsense-firewall list-rules --no-ssl-verify --search "TAPPaaS"

# List rules in JSON format
opnsense-firewall list-rules --no-ssl-verify --json

# Delete a rule by description
opnsense-firewall delete-rule --no-ssl-verify --description "Allow HTTP"

# Delete a rule by UUID
opnsense-firewall delete-rule --no-ssl-verify --uuid "abc123-def456-..."

# Apply pending firewall changes
opnsense-firewall apply --no-ssl-verify

# Show help
opnsense-firewall --help
opnsense-firewall create-rule --help
```

#### Commands

| Command | Description |
|---------|-------------|
| `create-rule` | Create a new firewall rule |
| `list-rules` | List all firewall rules (with optional search filter) |
| `delete-rule` | Delete a firewall rule by description or UUID |
| `apply` | Apply pending firewall configuration changes |
| `test` | Test connection to OPNsense firewall |

#### Global Options

| Option | Description |
|--------|-------------|
| `--firewall HOST` | Firewall IP/hostname (default: `firewall.mgmt.internal`) |
| `--credential-file PATH` | Path to credential file |
| `--no-ssl-verify` | Disable SSL certificate verification |
| `--debug` | Enable debug logging |
| `--json` | Output in JSON format |

#### create-rule Options

| Option | Description |
|--------|-------------|
| `--description, -d` | Rule description (required, used as identifier) |
| `--interface, -i` | Interface name, e.g., `wan`, `lan`, `opt1` (required) |
| `--action, -a` | Rule action: `pass`, `block`, `reject` (default: `pass`) |
| `--direction` | Traffic direction: `in`, `out` (default: `in`) |
| `--ip-protocol` | IP version: `inet`, `inet6`, `inet46` (default: `inet`) |
| `--protocol, -p` | Network protocol: `any`, `tcp`, `udp`, `tcp/udp`, `icmp` (default: `any`) |
| `--source, -s` | Source network/host (default: `any`) |
| `--source-port` | Source port or range |
| `--destination, -D` | Destination network/host (default: `any`) |
| `--destination-port, -P` | Destination port or range |
| `--log/--no-log` | Enable/disable logging (default: enabled) |
| `--disabled` | Create rule in disabled state |
| `--sequence` | Rule sequence/priority (lower = higher priority) |
| `--force, -f` | Overwrite existing rule with same description |
| `--no-apply` | Don't apply changes immediately |

#### list-rules Options

| Option | Description |
|--------|-------------|
| `--search` | Filter rules by description (substring match) |

#### delete-rule Options

| Option | Description |
|--------|-------------|
| `--description, -d` | Rule description to delete (mutually exclusive with --uuid) |
| `--uuid` | Rule UUID to delete (mutually exclusive with --description) |
| `--no-apply` | Don't apply changes immediately |

#### Examples

```bash
# Allow SSH from management network
opnsense-firewall create-rule \
    --no-ssl-verify \
    --description "Allow SSH from mgmt" \
    --interface lan \
    --protocol tcp \
    --source 10.0.0.0/16 \
    --destination-port 22

# Block all traffic from specific IP
opnsense-firewall create-rule \
    --no-ssl-verify \
    --description "Block bad actor" \
    --interface wan \
    --action block \
    --source 192.168.100.50

# Create rule with high priority (low sequence number)
opnsense-firewall create-rule \
    --no-ssl-verify \
    --description "Priority rule" \
    --interface wan \
    --protocol tcp \
    --destination-port 443 \
    --sequence 10

# List all TAPPaaS-created rules
opnsense-firewall list-rules --no-ssl-verify --search "TAPPaaS"

# Delete rule and apply immediately
opnsense-firewall delete-rule --no-ssl-verify --description "Block bad actor"

# Batch operations (create multiple rules without applying, then apply once)
opnsense-firewall create-rule --no-ssl-verify --no-apply -d "Rule 1" -i wan -p tcp -P 80
opnsense-firewall create-rule --no-ssl-verify --no-apply -d "Rule 2" -i wan -p tcp -P 443
opnsense-firewall create-rule --no-ssl-verify --no-apply -d "Rule 3" -i wan -p udp -P 53
opnsense-firewall apply --no-ssl-verify
```

### DNS Manager (`dns-manager` command)

The DNS Manager provides a dedicated CLI for managing DNS host entries in OPNsense's Dnsmasq service. This is useful for creating static DNS records for VMs and services.

#### CLI Usage

```bash
# Add a DNS host entry
./result/bin/dns-manager --no-ssl-verify add backup mgmt.internal 10.0.0.12

# Add with custom description
./result/bin/dns-manager --no-ssl-verify add backup mgmt.internal 10.0.0.12 --description "PBS Backup Server"

# Delete a DNS entry (by hostname and domain)
./result/bin/dns-manager --no-ssl-verify delete backup mgmt.internal

# List all DNS entries
./result/bin/dns-manager --no-ssl-verify list

# Dry-run mode (don't make changes)
./result/bin/dns-manager --no-ssl-verify --check-mode add backup mgmt.internal 10.0.0.12

# Show help
./result/bin/dns-manager --help
```

#### CLI Options

| Option | Description |
|--------|-------------|
| `--firewall HOST` | Firewall IP/hostname (default: `firewall.mgmt.internal`) |
| `--credential-file PATH` | Path to credential file |
| `--no-ssl-verify` | Disable SSL certificate verification |
| `--debug` | Enable debug logging |
| `--check-mode` | Dry-run mode (don't make actual changes) |

#### Commands

| Command | Description |
|---------|-------------|
| `add <hostname> <domain> <ip>` | Add or update a DNS host entry |
| `delete <hostname> <domain>` | Delete a DNS host entry by hostname and domain (ignores description) |
| `list` | List all DNS host entries |

### Zone Manager (`zone-manager` command)

The Zone Manager reads TAPPaaS zone definitions from `zones.json` and automatically configures VLANs and DHCP ranges for each enabled zone.

#### CLI Usage

```bash
# Show zone summary (dry-run, no changes)
./result/bin/zone-manager --no-ssl-verify --summary

# List current OPNsense VLAN and DHCP configuration
./result/bin/zone-manager --no-ssl-verify --list-config

# Configure all zones (VLANs + DHCP + firewall rules) in dry-run mode
./result/bin/zone-manager --no-ssl-verify

# Execute changes (creates VLANs, assigns interfaces, configures DHCP, and creates firewall rules)
./result/bin/zone-manager --no-ssl-verify --execute

# Configure only VLANs
./result/bin/zone-manager --no-ssl-verify --execute --vlans-only

# Configure only DHCP
./result/bin/zone-manager --no-ssl-verify --execute --dhcp-only

# Configure only firewall rules
./result/bin/zone-manager --no-ssl-verify --execute --firewall-rules-only

# Skip firewall rules (only VLANs + DHCP)
./result/bin/zone-manager --no-ssl-verify --execute --no-firewall-rules

# Skip assigning VLANs to interfaces (by default VLANs are assigned)
./result/bin/zone-manager --no-ssl-verify --execute --no-assign

# Use a specific zones.json file
./result/bin/zone-manager --zones-file /path/to/zones.json --execute
```

#### CLI Options

| Option | Description |
|--------|-------------|
| `--zones-file PATH` | Path to zones.json file (auto-detected if not specified) |
| `--firewall HOST` | Firewall IP/hostname (default: `firewall.mgmt.internal`) |
| `--credential-file PATH` | Path to credential file |
| `--no-ssl-verify` | Disable SSL certificate verification |
| `--debug` | Enable debug logging |
| `--execute` | Actually execute changes (default is dry-run mode) |
| `--interface NAME` | Physical interface for VLANs (default: `vtnet1`) |
| `--no-assign` | Do not assign VLANs to interfaces (by default VLANs are assigned) |
| `--no-firewall-rules` | Do not configure firewall rules (by default firewall rules are configured based on `access-to` field) |
| `--vlans-only` | Only configure VLANs, skip DHCP and firewall rules |
| `--dhcp-only` | Only configure DHCP, skip VLANs and firewall rules |
| `--firewall-rules-only` | Only configure firewall rules, skip VLANs and DHCP |
| `--summary` | Only show zone summary, don't configure anything |
| `--list-config` | List current OPNsense VLAN and DHCP configuration |

#### Programmatic Usage

```python
from opnsense_controller import Config, Zone, ZoneManager

config = Config(
    firewall="firewall.mgmt.internal",
    ssl_verify=False,
)

manager = ZoneManager(
    config=config,
    zones_file="/path/to/zones.json",
    interface="vtnet1",
)

# Load zones from JSON file
zones = manager.load_zones()

# Print zone summary
manager.print_zone_summary()

# List current OPNsense configuration
manager.print_current_config()

# Get enabled zones
enabled = manager.get_enabled_zones()
for zone in enabled:
    print(f"{zone.name}: {zone.ip_network} (VLAN {zone.vlan_tag})")

# Get zones that need VLANs (tag > 0)
vlan_zones = manager.get_vlan_zones()

# Configure VLANs only (dry-run)
vlan_results = manager.configure_vlans(check_mode=True)

# Configure VLANs (VLANs are assigned to interfaces by default)
vlan_results = manager.configure_vlans(check_mode=False)

# Configure DHCP ranges only
dhcp_results = manager.configure_dhcp(check_mode=False)

# Configure VLANs, DHCP, and firewall rules (default)
results = manager.configure_all(check_mode=False)
print(f"VLANs: {len(results['vlans'])} zones configured")
print(f"DHCP: {len(results['dhcp'])} zones configured")
print(f"Firewall: {len(results.get('firewall', {}))} rules configured")

# Configure VLANs and DHCP only, skip firewall rules
results = manager.configure_all(check_mode=False, firewall_rules=False)
```

#### ZoneManager Methods

| Method | Description |
|--------|-------------|
| `load_zones()` | Load zones from the JSON file |
| `get_enabled_zones()` | Get all enabled zones (Active or Mandatory state) |
| `get_disabled_zones()` | Get all disabled zones |
| `get_vlan_zones()` | Get enabled zones that need VLANs (tag > 0) |
| `configure_vlans(check_mode, assign)` | Configure VLANs for all enabled zones (assign=True by default) |
| `configure_dhcp(check_mode)` | Configure DHCP ranges for all enabled zones |
| `configure_firewall_rules(check_mode)` | Configure firewall rules based on access-to field |
| `configure_all(check_mode, assign_vlans, firewall_rules)` | Configure VLANs, DHCP, and firewall rules (all enabled by default) |
| `list_current_config()` | Get current OPNsense VLAN and DHCP configuration |
| `print_current_config()` | Print current OPNsense configuration |
| `print_zone_summary()` | Print a summary table of all zones |

#### Zone Properties

The `Zone` class provides these properties for each zone loaded from `zones.json`:

| Property | Description |
|----------|-------------|
| `name` | Zone name (e.g., `srv`, `dmz`, `private`) |
| `zone_type` | Zone type from config |
| `state` | Zone state (`Active`, `Mandatory`, `Disabled`) |
| `vlan_tag` | VLAN tag number (0 for untagged) |
| `ip_network` | IP network in CIDR notation (e.g., `10.21.0.0/16`) |
| `bridge` | Bridge interface name |
| `description` | Human-readable description |
| `is_enabled` | True if zone is Active or Mandatory |
| `needs_vlan` | True if zone has VLAN tag > 0 |
| `gateway_ip` | Gateway IP address (first host in network) |
| `dhcp_start` | DHCP range start (.50 in the network) |
| `dhcp_end` | DHCP range end (.250 in the network) |
| `domain` | Zone domain name (e.g., `srv.internal`) |

#### zones.json Format

The Zone Manager expects zones.json in the following format:

```json
{
  "mgmt": {
    "type": "management",
    "state": "Mandatory",
    "typeId": "0",
    "subId": "0",
    "vlantag": 0,
    "ip": "10.0.0.0/16",
    "bridge": "lan",
    "description": "Management network"
  },
  "srv": {
    "type": "service",
    "state": "Active",
    "typeId": "2",
    "subId": "1",
    "vlantag": 210,
    "ip": "10.21.0.0/16",
    "bridge": "lan",
    "description": "Service network",
    "access-to": ["mgmt", "dmz"]
  },
  "dmz": {
    "type": "dmz",
    "state": "Active",
    "typeId": "6",
    "subId": "1",
    "vlantag": 610,
    "ip": "10.61.0.0/16",
    "bridge": "lan",
    "description": "DMZ network",
    "pinhole-allowed-from": ["srv"]
  }
}
```

## Interface Assignment

By default, OPNsense API does not support interface assignment. TAPPaaS includes a custom PHP controller to enable this. The controller is deployed automatically by `update.sh`.

**Manual installation** (if needed):
```bash
scp InterfaceAssignController.php root@firewall:/usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/
scp ACL.xml root@firewall:/usr/local/opnsense/mvc/app/models/OPNsense/Interfaces/ACL/
ssh root@firewall "configctl webgui restart"
```

See `src/foundation/30-tappaas-cicd/opnsense-patch/README.md` for details on the controller and OPNsense 26.1 compatibility.

## Project Structure

```
.
├── README.md
├── default.nix                    # Nix package definitions
├── credentials.example.txt        # Example credentials file
└── src/
    ├── pyproject.toml
    ├── README.md
    └── opnsense_controller/
        ├── __init__.py
        ├── config.py              # Connection configuration
        ├── vlan_manager.py        # VLAN and interface operations
        ├── dhcp_manager.py        # DHCP/Dnsmasq operations
        ├── firewall_manager.py    # Firewall rule operations
        ├── firewall_cli.py        # Standalone firewall CLI (opnsense-firewall)
        ├── zone_manager.py        # Zone configuration from zones.json
        ├── dns_manager_cli.py     # Standalone DNS CLI (dns-manager)
        └── main.py                # Main CLI entry point (opnsense-controller)
```

## Nix Outputs

```bash
# Default: Python environment with all packages
nix-build -A default default.nix

# Development shell
nix-shell -A shell default.nix

# Just the opnsense-api-client package
nix-build -A opnsense-api-client default.nix

# Just the opnsense-controller package
nix-build -A opnsense-controller default.nix
```

## Programmatic Usage

### VLAN Management

```python
from opnsense_controller import Config, Vlan, VlanManager

# Using default credential file ($HOME/.opnsense-credentials.txt)
config = Config(
    firewall="firewall.mgmt.internal",
    ssl_verify=False,
)

# Or with explicit credentials
config = Config(
    firewall="192.168.1.1",
    token="your-token",
    secret="your-secret",
    ssl_verify=False,
    debug=True,
)

with VlanManager(config) as manager:
    # Test connection
    if manager.test_connection():
        print("Connected!")

    # List assigned VLANs
    assigned = manager.get_assigned_vlans()
    for vlan in assigned:
        print(f"VLAN {vlan['vlan_tag']}: {vlan['identifier']} ({vlan['description']})")

    # Create a VLAN device only
    vlan = Vlan(
        description="Servers",
        tag=20,
        interface="vtnet0",
    )
    result = manager.create_vlan(vlan)

    # Create a VLAN and assign it to an interface (requires PHP extension)
    result = manager.create_vlan(vlan, assign=True, enable=True)
    if result.get("ifname"):
        print(f"Assigned to interface: {result['ifname']}")

    # Create multiple VLANs with assignment
    vlans = [
        Vlan(description="Management", tag=10, interface="vtnet0"),
        Vlan(description="DMZ", tag=100, interface="vtnet0"),
    ]
    results = manager.create_multiple_vlans(vlans, assign=True)

    # Assign an existing device to an interface manually
    result = manager.assign_interface(
        device="vlan0.50",
        description="Guest Network",
        enable=True,
    )

    # Unassign an interface
    manager.unassign_interface("opt3")

    # Update a VLAN
    vlan.priority = 7
    manager.update_vlan(vlan)

    # Delete a VLAN
    manager.delete_vlan("Servers")
```

### VlanManager Methods

| Method | Description |
|--------|-------------|
| `test_connection()` | Test connection to OPNsense |
| `list_modules()` | List all available API modules |
| `get_vlan_spec()` | Get VLAN module specification |
| `get_interfaces_info()` | Get information about all interfaces |
| `get_assigned_vlans()` | Get list of VLANs assigned to interfaces |
| `create_vlan(vlan, check_mode, assign, enable)` | Create a VLAN device |
| `update_vlan(vlan, check_mode)` | Update an existing VLAN |
| `delete_vlan(description, check_mode)` | Delete a VLAN by description |
| `create_multiple_vlans(vlans, check_mode, assign, enable)` | Create multiple VLANs |
| `assign_interface(device, description, enable, ipv4_type, ipv4_address, ipv4_subnet)` | Assign device to interface |
| `unassign_interface(identifier)` | Remove interface assignment |

### DHCP Management

```python
from opnsense_controller import Config, DhcpHost, DhcpManager, DhcpRange

config = Config(
    firewall="firewall.mgmt.internal",
    ssl_verify=False,
)

with DhcpManager(config) as manager:
    # Test connection
    if manager.test_connection():
        print("Connected!")

    # Create a DHCP range for a network
    dhcp_range = DhcpRange(
        description="Server Network DHCP",
        start_addr="10.21.0.100",
        end_addr="10.21.0.200",
        interface="opt1",  # OPNsense interface name
        lease_time=86400,  # 24 hours
        domain="srv.internal",
    )
    result = manager.create_range(dhcp_range)

    # Create multiple DHCP ranges
    ranges = [
        DhcpRange(
            description="Private Network",
            start_addr="10.31.0.100",
            end_addr="10.31.0.250",
            domain="private.internal",
        ),
        DhcpRange(
            description="IoT Network",
            start_addr="10.41.0.100",
            end_addr="10.41.0.250",
            domain="iot.internal",
        ),
    ]
    manager.create_multiple_ranges(ranges)

    # Create a static DHCP host reservation
    host = DhcpHost(
        description="Nextcloud Server",
        host="nextcloud",
        ip=["10.21.0.10"],
        hardware_addr=["00:11:22:33:44:55"],
        domain="srv.internal",
    )
    manager.create_host(host)

    # Create multiple static host reservations
    hosts = [
        DhcpHost(description="Gitea", host="gitea", ip=["10.21.0.11"]),
        DhcpHost(description="Matrix", host="matrix", ip=["10.21.0.12"]),
    ]
    manager.create_multiple_hosts(hosts)

    # Delete a host reservation
    manager.delete_host("Matrix")

    # Delete a DHCP range
    manager.delete_range("IoT Network")

    # Enable Dnsmasq service
    manager.enable_service(
        interfaces=["opt1", "opt2"],
        dhcp_authoritative=True,
    )

    # Configure general settings
    manager.configure_general(
        enabled=True,
        dhcp_authoritative=True,
        dhcp_fqdn=True,
        regdhcp=True,
        regdhcpstatic=True,
    )
```

### DhcpManager Methods

| Method | Description |
|--------|-------------|
| `test_connection()` | Test connection to OPNsense |
| `get_range_spec()` | Get DHCP range module specification |
| `get_host_spec()` | Get DHCP host module specification |
| `get_general_spec()` | Get Dnsmasq general settings specification |
| `create_range(dhcp_range, check_mode)` | Create a DHCP range |
| `update_range(dhcp_range, check_mode)` | Update an existing DHCP range |
| `delete_range(description, check_mode)` | Delete a DHCP range by description |
| `create_multiple_ranges(ranges, check_mode)` | Create multiple DHCP ranges |
| `create_host(host, check_mode)` | Create a static DHCP host reservation |
| `update_host(host, check_mode)` | Update an existing host reservation |
| `delete_host(description, check_mode)` | Delete a host reservation by description |
| `create_multiple_hosts(hosts, check_mode)` | Create multiple host reservations |
| `enable_service(interfaces, dhcp_authoritative, check_mode)` | Enable Dnsmasq service |
| `disable_service(check_mode)` | Disable Dnsmasq service |
| `configure_general(...)` | Configure general Dnsmasq settings |

### DhcpRange Fields

| Field | Type | Description |
|-------|------|-------------|
| `description` | str | Unique description for the range (required) |
| `start_addr` | str | Start IP address of the range (required) |
| `end_addr` | str | End IP address of the range (required) |
| `interface` | str | OPNsense interface to serve (e.g., `opt1`) |
| `subnet_mask` | str | Subnet mask (auto-calculated if not specified) |
| `lease_time` | int | Lease time in seconds (default: 86400) |
| `domain` | str | Domain to offer to DHCP clients |
| `set_tag` | str | Tag to set for matching requests |

### DhcpHost Fields

| Field | Type | Description |
|-------|------|-------------|
| `description` | str | Unique description for the host (required) |
| `host` | str | Hostname without domain (required) |
| `ip` | list[str] | IP addresses to assign |
| `hardware_addr` | list[str] | MAC addresses to match |
| `domain` | str | Domain of the host |
| `lease_time` | int | Lease time in seconds |
| `set_tag` | str | Tag to set for matching requests |
| `ignore` | bool | Ignore DHCP packets from this host |

### Firewall Management

```python
from opnsense_controller import (
    Config,
    FirewallManager,
    FirewallRule,
    Protocol,
    RuleAction,
    RuleDirection,
    IpProtocol,
)

config = Config(
    firewall="firewall.mgmt.internal",
    ssl_verify=False,
)

with FirewallManager(config) as manager:
    # Test connection
    if manager.test_connection():
        print("Connected!")

    # List all firewall rules
    rules = manager.list_rules()
    for rule in rules:
        print(f"{rule.action} {rule.protocol} {rule.source_net} -> {rule.destination_net}")

    # Get a specific rule by description
    rule_info = manager.get_rule_by_description("Allow SSH")
    if rule_info:
        print(f"Found rule: {rule_info.uuid}")

    # Create a firewall rule
    rule = FirewallRule(
        description="Allow SSH from management",
        action=RuleAction.PASS,
        interface="lan",
        direction=RuleDirection.IN,
        protocol=Protocol.TCP,
        source_net="10.0.0.0/24",
        destination_port="22",
        log=True,
    )
    result = manager.create_rule(rule)

    # Create multiple rules (applies changes once at the end)
    rules = [
        FirewallRule(
            description="Allow DNS",
            action=RuleAction.PASS,
            interface="lan",
            protocol=Protocol.UDP,
            destination_port="53",
        ),
        FirewallRule(
            description="Allow HTTPS",
            action=RuleAction.PASS,
            interface="lan",
            protocol=Protocol.TCP,
            destination_port="443",
        ),
        FirewallRule(
            description="Block all other",
            action=RuleAction.BLOCK,
            interface="lan",
            sequence=65000,  # Low priority (processed last)
        ),
    ]
    manager.create_multiple_rules(rules)

    # Convenience methods for common rules
    manager.create_allow_rule(
        description="Allow ICMP ping",
        interface="lan",
        protocol=Protocol.ICMP,
    )

    manager.create_block_rule(
        description="Block Telnet",
        interface="lan",
        protocol=Protocol.TCP,
        destination_port="23",
    )

    # Toggle a rule on/off
    manager.toggle_rule(uuid="some-uuid", enabled=False)

    # Delete a rule by description
    manager.delete_rule("Block Telnet")

    # Delete a rule by UUID
    manager.delete_rule_by_uuid("some-uuid")

    # Create a savepoint before bulk changes
    savepoint = manager.create_savepoint()

    # Revert to savepoint if needed
    # manager.revert_changes(savepoint["revision"])

    # Manually apply changes (if apply=False was used)
    manager.apply_changes()
```

### FirewallManager Methods

| Method | Description |
|--------|-------------|
| `test_connection()` | Test connection to OPNsense |
| `get_rule_spec()` | Get firewall rule module specification |
| `list_rules(search_pattern)` | List all firewall rules |
| `get_rule(uuid)` | Get details of a specific rule |
| `get_rule_by_description(description)` | Find a rule by description |
| `create_rule(rule, apply)` | Create a new firewall rule |
| `update_rule(rule, apply)` | Update an existing rule |
| `delete_rule(description, apply)` | Delete rule by description |
| `delete_rule_by_uuid(uuid, apply)` | Delete rule by UUID |
| `toggle_rule(uuid, enabled, apply)` | Enable/disable a rule |
| `apply_changes()` | Apply firewall configuration |
| `create_savepoint()` | Create a rollback point |
| `revert_changes(revision)` | Revert to a previous configuration |
| `create_allow_rule(...)` | Convenience method for allow rules |
| `create_block_rule(...)` | Convenience method for block rules |
| `create_multiple_rules(rules, apply)` | Create multiple rules at once |

### FirewallRule Fields

| Field | Type | Description |
|-------|------|-------------|
| `description` | str | Unique description for the rule (required) |
| `action` | RuleAction | `PASS`, `BLOCK`, or `REJECT` (default: `PASS`) |
| `interface` | str \| list[str] | Interface name(s) to apply rule on (default: `lan`) |
| `direction` | RuleDirection | `IN` or `OUT` (default: `IN`) |
| `ip_protocol` | IpProtocol | `IPV4`, `IPV6`, or `BOTH` (default: `IPV4`) |
| `protocol` | Protocol | `ANY`, `TCP`, `UDP`, `ICMP`, etc. (default: `ANY`) |
| `source_net` | str | Source IP/network/alias or `any` (default: `any`) |
| `source_port` | str | Source port, range, or alias (default: any) |
| `source_invert` | bool | Negate source matching (default: `False`) |
| `destination_net` | str | Destination IP/network/alias or `any` (default: `any`) |
| `destination_port` | str | Destination port, range, or alias (default: any) |
| `destination_invert` | bool | Negate destination matching (default: `False`) |
| `gateway` | str | Gateway name for policy routing |
| `log` | bool | Log matching packets (default: `True`) |
| `quick` | bool | Stop processing on match (default: `True`) |
| `enabled` | bool | Enable the rule (default: `True`) |
| `sequence` | int | Rule order (lower = higher priority) |

### Protocol Enum

| Value | Description |
|-------|-------------|
| `Protocol.ANY` | Any protocol |
| `Protocol.TCP` | TCP |
| `Protocol.UDP` | UDP |
| `Protocol.TCP_UDP` | TCP and UDP |
| `Protocol.ICMP` | ICMP (IPv4) |
| `Protocol.ICMPV6` | ICMPv6 |
| `Protocol.ESP` | ESP (IPsec) |
| `Protocol.AH` | AH (IPsec) |
| `Protocol.GRE` | GRE tunneling |
| `Protocol.IGMP` | IGMP multicast |
| `Protocol.OSPF` | OSPF routing |
| `Protocol.PIM` | PIM multicast |
| `Protocol.CARP` | CARP failover |
| `Protocol.PFSYNC` | pfsync state sync |

## License

MIT
