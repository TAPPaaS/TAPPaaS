# VM Creation Test Suite

This directory contains test configurations for validating TAPPaaS VM creation across different scenarios.

## Test Cases

| Test | VMID | Type | Zone | Node | HA Node | Description |
|------|------|------|------|------|---------|-------------|
| test-debian | 901 | Debian img | mgmt | tappaas1 | - | Debian cloud image on management network |
| test-debian-vlan-node | 902 | Debian img | srv | tappaas3 | - | Debian cloud image on srv VLAN on different node |
| test-nixos | 903 | NixOS clone | mgmt | tappaas1 | tappaas2 | NixOS clone on mgmt with HA replication to tappaas2 |
| test-nixos-vlan-node | 904 | NixOS clone | srv | tappaas2 | - | NixOS clone on srv VLAN on different node |
| test-ubuntu-vlan | 905 | Ubuntu img | srv | tappaas2 | - | Ubuntu cloud image on srv VLAN |

## Prerequisites

1. Ensure you're on the tappaas-cicd VM
2. Pull the latest code from the repository
3. Copy the Create-TAPPaaS-VM.sh script to the Proxmox nodes:

```bash
cd ~/TAPPaaS
git pull
scp src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh root@tappaas1.mgmt.internal:/root/tappaas/
scp src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh root@tappaas2.mgmt.internal:/root/tappaas/
scp src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh root@tappaas3.mgmt.internal:/root/tappaas/
```

## Running the Full Test Suite

Run all 5 test cases (install + verify each VM):

```bash
cd ~/TAPPaaS/src/test/vm-creation
./test.sh
```

Run a single test case:

```bash
./test.sh test-nixos                    # Install and test only test-nixos
./test.sh test-nixos --skip-install     # Test existing test-nixos VM
./test.sh test-nixos --skip-test        # Only install test-nixos
```

Options:

- `./test.sh` - Install and test all 5 VMs
- `./test.sh [test-name]` - Install and test only the specified VM
- `./test.sh --skip-install` - Only run tests on existing VMs (skip installation)
- `./test.sh --skip-test` - Only install VMs (skip testing)
- `./test.sh --cleanup` - Destroy all test VMs after testing
- `./test.sh --skip-install --cleanup` - Test existing VMs and cleanup after

Available test names:
- `test-debian`, `test-debian-vlan-node`
- `test-nixos`, `test-nixos-vlan-node`
- `test-ubuntu-vlan`

Example output:

```text
==============================================
TAPPaaS VM Creation Test Suite
Started: Wed Feb  14 12:30:00 CET 2026
==============================================

Mode: Install and Test
Logs: /home/tappaas/logs/

[test-debian] Installing... OK. Testing... PASS
[test-debian-vlan-node] Installing... OK. Testing... PASS
[test-nixos] Installing... OK. Testing... PASS
[test-nixos-vlan-node] Installing... OK. Testing... PASS
[test-ubuntu-vlan] Installing... OK. Testing... PASS

==============================================
Test Results Summary
==============================================

Test                 Type       Zone       Install    Test
----                 ----       ----       -------    ----
test-debian          debian     mgmt       PASS       PASS
test-debian-vlan-node debian    srv        PASS       PASS
test-nixos           nixos-ha   mgmt       PASS       PASS
test-nixos-vlan-node nixos      srv        PASS       PASS
test-ubuntu-vlan     ubuntu     srv        PASS       PASS

==============================================
Total: 5 passed, 0 failed
Logs saved to: /home/tappaas/logs/
==============================================
```

## Running Individual Tests

### Install a single VM

The unified `install.sh` script handles both NixOS and Debian/Ubuntu VMs. It automatically:
1. Creates the VM using `install-vm.sh`
2. Detects the OS type (NixOS or Debian/Ubuntu)
3. Applies OS-specific configuration via `update-os.sh`
4. Configures HA if `HANode` is specified in the JSON config

```bash
./install.sh test-debian           # Debian image VM
./install.sh test-nixos            # NixOS clone VM (with HA if HANode specified)
./install.sh test-nixos-vlan-node  # NixOS clone VM without HA
./install.sh test-ubuntu-vlan      # Ubuntu image VM
```

### Test a single VM

```bash
./test-vm.sh test-debian      # Test the test-debian VM
./test-vm.sh test-nixos       # Test the test-nixos VM (includes HA tests)
```

The test-vm.sh script checks:

1. **Ping by IP** - Can reach the VM via IP address
2. **DNS resolution** - Hostname resolves to correct IP
3. **Ping by DNS** - Can reach the VM via DNS name
4. **SSH access** - Can SSH as tappaas (or debian) user
5. **Hostname** - VM reports correct hostname
6. **Internet access** - VM can ping 1.1.1.1
7. **DNS from VM** - VM can resolve and ping google.com
8. **Disk size** - VM disk size matches configuration

When HANode is specified in the VM config, test-vm.sh also runs HA tests:

9. **HA resource** - VM is registered in HA resources
10. **HA rule** - Node-affinity rule exists for the VM
11. **Rule priorities** - Primary node has priority 2, HA node has priority 1
12. **Replication job** - ZFS replication job exists
13. **Replication target** - Replication target is correct HA node
14. **Replication schedule** - Schedule matches configuration
15. **Replication status** - Replication state is OK
16. **Replicated disks** - VM disks are present on HA node
17. **HA node reachability** - HA node is accessible
18. **Storage availability** - Storage pool exists on HA node

Example output:

```
==============================================
Testing VM: test-nixos (VMID: 903)
Node: tappaas1, Zone: mgmt
HA Node: tappaas2
==============================================

Running tests...

1. Ping test (by IP)...
  [PASS] Ping VM by IP (10.0.0.123)
2. DNS resolution test...
  [PASS] DNS resolves test-nixos.mgmt.internal to 10.0.0.123
...

Running HA configuration tests...

9. HA resource test...
  [PASS] VM 903 is registered in HA resources
10. HA rule test...
  [PASS] HA rule 'ha-test-nixos' exists
...
==============================================
Test Summary for test-nixos
==============================================
  Passed: 18
  Failed: 0

[SUCCESS] All tests passed!
```

## Cleanup

To remove all test VMs after testing:

```bash
# Automatic cleanup (via test.sh)
./test.sh --cleanup

# Or manual cleanup
# On tappaas1
ssh root@tappaas1.mgmt.internal "ha-manager remove vm:903"
ssh root@tappaas1.mgmt.internal "ha-manager rules remove ha-test-nixos"
ssh root@tappaas1.mgmt.internal "pvesr delete 903-0 --force 1"
ssh root@tappaas1.mgmt.internal "qm stop 901; qm destroy 901 --purge"
ssh root@tappaas1.mgmt.internal "qm stop 903; qm destroy 903 --purge"

# On tappaas2
ssh root@tappaas2.mgmt.internal "qm stop 904; qm destroy 904 --purge"
ssh root@tappaas2.mgmt.internal "qm stop 905; qm destroy 905 --purge"

# On tappaas3
ssh root@tappaas3.mgmt.internal "qm stop 902; qm destroy 902 --purge"
```

## Directory Structure

```text
test-vm-creation/
├── README.md                     # This file
├── install.sh                    # Unified install script for all VM types
├── test.sh                       # Run full test suite (all 5 VMs)
├── test-vm.sh                    # Test a single VM (basic + HA tests if applicable)
├── test-debian.json              # Debian on mgmt (tappaas1) - VMID 901
├── test-debian-vlan-node.json    # Debian on srv VLAN (tappaas3) - VMID 902
├── test-nixos.json               # NixOS clone on mgmt with HA (tappaas1->tappaas2) - VMID 903
├── test-nixos.nix                # NixOS config for test-nixos
├── test-nixos-vlan-node.json     # NixOS clone on srv VLAN (tappaas2) - VMID 904
├── test-nixos-vlan-node.nix      # NixOS config for test-nixos-vlan-node
└── test-ubuntu-vlan.json         # Ubuntu on srv VLAN (tappaas2) - VMID 905
```

## Notes

- The unified `install.sh` script handles all VM types by auto-detecting NixOS vs Debian/Ubuntu
- Debian/Ubuntu VMs use cloud-init for initial configuration
- NixOS VMs are cloned from template 9000 (tappaas-nixos) and configured via nixos-rebuild
- The `update-os.sh` script (called by install.sh) handles:
  - OS detection (NixOS vs Debian/Ubuntu)
  - IP address detection (via guest agent or DHCP leases)
  - NixOS: runs nixos-rebuild with `./<vmname>.nix` and reboots
  - Debian/Ubuntu: runs apt update/upgrade and installs qemu-guest-agent
  - DHCP hostname registration fix for both OS types
- HA is automatically configured when `HANode` is specified in the JSON config
- Tests on tappaas2/tappaas3 require the tappaas-nixos template to be available on those nodes
- The test-nixos test case demonstrates HA configuration with:
  - Proxmox HA manager resources for automatic failover
  - Node-affinity rules for priority-based VM placement
  - ZFS replication for data synchronization between nodes
  - The VM prefers tappaas1 (priority 2) but will failover to tappaas2 (priority 1) if needed
