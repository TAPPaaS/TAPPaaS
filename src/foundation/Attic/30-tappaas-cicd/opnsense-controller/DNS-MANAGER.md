# DNS Manager CLI

The DNS Manager is a dedicated command-line tool for managing DNS host entries in OPNsense's Dnsmasq service.

## Installation

The DNS manager is installed as part of the OPNsense controller Nix package:

```bash
# Build the OPNsense controller package
cd ~/TAPPaaS/src/foundation/30-tappaas-cicd/opnsense-controller
nix-build -A default default.nix

# The dns-manager command will be available in the result
./result/bin/dns-manager --help
```

## Usage

### Add a DNS Entry

```bash
dns-manager --no-ssl-verify add <hostname> <domain> <ip-address>
```

Example:
```bash
dns-manager --no-ssl-verify add backup mgmt.internal 10.0.0.12
```

With custom description:
```bash
dns-manager --no-ssl-verify add backup mgmt.internal 10.0.0.12 --description "PBS Backup Server"
```

### Delete a DNS Entry

Delete by hostname and domain (ignores description field):

```bash
dns-manager --no-ssl-verify delete backup mgmt.internal
```

### List DNS Entries

```bash
dns-manager --no-ssl-verify list
```

### Dry-Run Mode

Test changes without applying them:

```bash
dns-manager --no-ssl-verify --check-mode add backup mgmt.internal 10.0.0.12
```

## Options

| Option | Description |
|--------|-------------|
| `--firewall HOST` | Firewall IP/hostname (default: firewall.mgmt.internal) |
| `--credential-file PATH` | Path to credential file (default: ~/.opnsense-credentials.txt) |
| `--no-ssl-verify` | Disable SSL certificate verification |
| `--debug` | Enable debug logging |
| `--check-mode` | Dry-run mode (don't make actual changes) |

## Commands

| Command | Arguments | Description |
|---------|-----------|-------------|
| `add` | `<hostname> <domain> <ip>` | Add or update a DNS host entry |
| `delete` | `<hostname> <domain>` | Delete a DNS host entry by hostname and domain (ignores description) |
| `list` | - | List all DNS host entries |

## Authentication

The DNS manager uses the same credentials as other OPNsense controller tools. Set up credentials in one of these ways:

1. **Credential file** (recommended):
   ```bash
   cat > ~/.opnsense-credentials.txt <<EOF
   your-api-token
   your-api-secret
   EOF
   chmod 600 ~/.opnsense-credentials.txt
   ```

2. **Environment variables**:
   ```bash
   export OPNSENSE_TOKEN="your-api-token"
   export OPNSENSE_SECRET="your-api-secret"
   ```

3. **Command-line option**:
   ```bash
   dns-manager --credential-file /path/to/creds.txt ...
   ```

## Integration with TAPPaaS

The DNS manager is automatically used by the PBS backup configuration script:

```bash
# In configure.sh
dns-manager --no-ssl-verify add backup mgmt.internal ${PBS_NODE_IP} --description "PBS Backup Server"
```

## Technical Details

- Uses OPNsense's Dnsmasq DHCP/DNS service
- Creates static host entries that work for both DNS resolution and DHCP reservations
- Manages entries via the OPNsense API
- Implemented as a Python module in `opnsense_controller.dns_manager_cli`
