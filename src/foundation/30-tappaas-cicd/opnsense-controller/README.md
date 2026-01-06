# OPNsense Controller

OPNsense controller for TAPPaaS using the `oxl-opnsense-client` library.

## Requirements

- Nix package manager
- OPNsense firewall with API access enabled

## Quick Start

```bash
# Build the project
nix-build -A default default.nix

# Or enter a development shell
nix-shell -A shell default.nix
```

## Configuration

### Option 1: Environment Variables

```bash
export OPNSENSE_HOST="10.0.0.1"
export OPNSENSE_TOKEN="your-api-token"
export OPNSENSE_SECRET="your-api-secret"
```

### Option 2: Credential File

```bash
cp credentials.example.txt ~/.opnsense-credentials.txt
chmod 600 ~/.opnsense-credentials.txt
# Edit with your token (line 1) and secret (line 2)

export OPNSENSE_HOST="10.0.0.1"
export OPNSENSE_CREDENTIAL_FILE="$HOME/.opnsense-credentials.txt"
```

### Creating API Credentials in OPNsense

1. Log into OPNsense web interface
2. Go to **System > Access > Users**
3. Edit your user or create a new one
4. Under **API keys**, click **+** to generate a key
5. Save the key and secret

## Usage

```bash
# Show help
./result/bin/python -m opnsense_controller.main --help

# Test connection
./result/bin/python -m opnsense_controller.main --example test

# List interface modules
./result/bin/python -m opnsense_controller.main --example list

# Create multiple VLANs (dry-run)
./result/bin/python -m opnsense_controller.main --example create-multi

# Create multiple VLANs (actually execute)
./result/bin/python -m opnsense_controller.main --example create-multi --execute

# Disable SSL verification (for self-signed certs)
./result/bin/python -m opnsense_controller.main --no-ssl-verify --example test
```

## Examples Included

| Example | Description |
|---------|-------------|
| `test` | Test connection to firewall |
| `list` | List available interface modules |
| `spec` | Show VLAN module specification |
| `create` | Create single VLAN (Management VLAN 10) |
| `create-multi` | Create multiple VLANs (Management, Servers, Workstations, IoT, Guest, DMZ) |
| `update` | Update VLAN priority |
| `delete` | Delete a VLAN |
| `all` | Run all examples (default) |

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
        ├── vlan_manager.py        # VLAN CRUD operations
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

config = Config(
    firewall="192.168.1.1",
    token="your-token",
    secret="your-secret",
    ssl_verify=False,
)

with VlanManager(config) as manager:
    # Test connection
    manager.test_connection()

    # Create a VLAN
    vlan = Vlan(
        description="Servers",
        tag=20,
        interface="igb0",
    )
    result = manager.create_vlan(vlan)

    # Create multiple VLANs
    vlans = [
        Vlan(description="Management", tag=10, interface="igb0"),
        Vlan(description="DMZ", tag=100, interface="igb0"),
    ]
    manager.create_multiple_vlans(vlans)

    # Update a VLAN
    vlan.priority = 7
    manager.update_vlan(vlan, match_fields=["description"])

    # Delete a VLAN
    manager.delete_vlan("Servers")
```

## License

MIT
