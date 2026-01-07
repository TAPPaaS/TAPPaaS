# OPNsense Controller

OPNsense controller for TAPPaaS using the `oxl-opnsense-client` library.

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

### Creating API Credentials in OPNsense

1. Log into OPNsense web interface
2. Go to **System > Access > Users**
3. Edit your user or create a new one
4. Under **API keys**, click **+** to generate a key
5. Save the key and secret to your credentials file

## CLI Usage

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

## CLI Options

| Option | Description |
|--------|-------------|
| `--firewall HOST` | Firewall IP/hostname (default: `firewall.mgmt.internal`) |
| `--credential-file PATH` | Path to credential file |
| `--no-ssl-verify` | Disable SSL certificate verification |
| `--debug` | Enable debug logging |
| `--execute` | Actually execute changes (default is dry-run mode) |
| `--assign` | Assign created VLANs to interfaces and enable them |
| `--interface NAME` | Parent interface for VLAN examples (default: `vtnet0`) |
| `--example NAME` | Which example to run (default: `all`) |

## Examples

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

## Interface Assignment

By default, OPNsense API does not support interface assignment. To enable automatic interface assignment when creating VLANs, install the custom PHP extension:

1. Download from: https://gist.github.com/szymczag/df152a82e86aff67b984ed3786b027ba
2. Place it on your OPNsense firewall at:
   ```
   /usr/local/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/AssignSettingsController.php
   ```
3. Use the `--assign` flag when creating VLANs

See: https://github.com/opnsense/core/issues/7324#issuecomment-2830694222

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
        └── main.py                # CLI entry point
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

## License

MIT
