# OPNsense Controller

OPNsense controller for TAPPaaS using the `oxl-opnsense-client` library.

## Setup

### 1. Create API credentials in OPNsense

1. Log into your OPNsense web interface
2. Go to **System > Access > Users**
3. Create a new user or edit an existing one
4. Under **API keys**, click **+** to generate a new key
5. Save the key and secret to a file (one per line)

### 2. Configure credentials

Option A: Using a credential file:
```bash
cp credentials.example.txt ~/.opnsense-credentials.txt
chmod 600 ~/.opnsense-credentials.txt
# Edit the file with your actual token and secret
```

Option B: Using environment variables:
```bash
export OPNSENSE_HOST="10.0.0.1"
export OPNSENSE_TOKEN="your-api-token"
export OPNSENSE_SECRET="your-api-secret"
```

## Usage with Nix

```bash
# Enter development shell
nix-shell -A shell default.nix

# Or build and run directly
nix-build -A default default.nix
./result/bin/python -m opnsense_controller.main --help
```

## Examples

```bash
# Test connection (dry-run mode by default)
python -m opnsense_controller.main --example test

# List interface modules
python -m opnsense_controller.main --example list

# Show VLAN module specification
python -m opnsense_controller.main --example spec

# Create a single VLAN (dry-run)
python -m opnsense_controller.main --example create

# Create multiple VLANs (dry-run)
python -m opnsense_controller.main --example create-multi

# Actually execute changes (removes dry-run mode)
python -m opnsense_controller.main --example create --execute

# Run all examples
python -m opnsense_controller.main

# Disable SSL verification (for self-signed certs)
python -m opnsense_controller.main --no-ssl-verify

# Enable debug logging
python -m opnsense_controller.main --debug
```

## Project Structure

```
.
├── default.nix                    # Nix package definition
├── credentials.example.txt        # Example credentials file
└── src/
    ├── pyproject.toml
    └── opnsense_controller/
        ├── __init__.py
        ├── config.py              # Configuration management
        ├── vlan_manager.py        # VLAN operations
        └── main.py                # CLI entry point with examples
```

## License

MIT
