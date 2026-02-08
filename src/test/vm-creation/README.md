# VM Creation Test Suite

This directory contains test configurations for validating TAPPaaS VM creation across different scenarios.

## Test Cases

| Test | VMID | Type | Zone | Node | HA Node | Description |
|------|------|------|------|------|---------|-------------|
| test-debian | 601 | Debian img | mgmt | tappaas1 | - | Debian cloud image on management network |
| test-debian-vlan | 602 | Debian img | srv | tappaas1 | - | Debian cloud image on srv VLAN |
| test-debian-node | 603 | Debian img | srv | tappaas2 | - | Debian cloud image on different node |
| test-nixos | 604 | NixOS clone | mgmt | tappaas1 | - | NixOS clone on management network |
| test-nixos-vlan | 605 | NixOS clone | srv | tappaas1 | - | NixOS clone on srv VLAN |
| test-nixos-node | 606 | NixOS clone | srv | tappaas2 | - | NixOS clone on different node |
| test-nixos-ha | 607 | NixOS clone | mgmt | tappaas1 | tappaas2 | NixOS clone with HA replication to tappaas2 |

## Prerequisites

1. Ensure you're on the tappaas-cicd VM
2. Pull the latest code from the repository
3. Copy the Create-TAPPaaS-VM.sh script to the Proxmox nodes:

```bash
cd ~/TAPPaaS
git pull
scp src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh root@tappaas1.mgmt.internal:/root/tappaas/
scp src/foundation/05-ProxmoxNode/Create-TAPPaaS-VM.sh root@tappaas2.mgmt.internal:/root/tappaas/
```

## Running the Full Test Suite

Run all 7 test cases (install + verify each VM):

```bash
cd ~/TAPPaaS/src/test/vm-creation
./test.sh
```

Run a single test case:

```bash
./test.sh test-nixos-ha                    # Install and test only test-nixos-ha
./test.sh test-nixos-ha --skip-install     # Test existing test-nixos-ha VM
./test.sh test-nixos-ha --skip-test        # Only install test-nixos-ha
```

Options:

- `./test.sh` - Install and test all 7 VMs
- `./test.sh [test-name]` - Install and test only the specified VM
- `./test.sh --skip-install` - Only run tests on existing VMs (skip installation)
- `./test.sh --skip-test` - Only install VMs (skip testing)
- `./test.sh --cleanup` - Destroy all test VMs after testing
- `./test.sh --skip-install --cleanup` - Test existing VMs and cleanup after

Available test names:
- `test-debian`, `test-debian-vlan`, `test-debian-node`
- `test-nixos`, `test-nixos-vlan`, `test-nixos-node`
- `test-nixos-ha`

Example output:

```text
==============================================
TAPPaaS VM Creation Test Suite
Started: Wed Feb  8 16:30:00 CET 2026
==============================================

Mode: Install and Test
Logs: /home/tappaas/logs/

[test-debian] Installing... OK. Testing... PASS
[test-debian-vlan] Installing... OK. Testing... PARTIAL (4/3)
[test-nixos] Installing... OK. Testing... PASS
[test-nixos-ha] Installing... OK. Testing... PASS
...

==============================================
Test Results Summary
==============================================

Test                 Type       Zone       Install    Test
----                 ----       ----       -------    ----
test-debian          debian     mgmt       PASS       PASS
test-debian-vlan     debian     srv        PASS       PARTIAL
test-debian-node     debian     srv        PASS       PARTIAL
test-nixos           nixos      mgmt       PASS       PASS
test-nixos-vlan      nixos      srv        PASS       PASS
test-nixos-node      nixos      srv        PASS       PASS
test-nixos-ha        nixos-ha   mgmt       PASS       PASS

==============================================
Total: 5 passed, 2 failed
Logs saved to: /home/tappaas/logs/
==============================================
```

## Running Individual Tests

### Install a single VM

```bash
./install-debian.sh test-debian      # Debian image VM
./install-nixos.sh test-nixos        # NixOS clone VM
./install-nixos-ha.sh test-nixos-ha  # NixOS VM with HA configuration
```

### Test a single VM

```bash
./test-vm.sh test-debian      # Test the test-debian VM
./test-vm.sh test-nixos       # Test the test-nixos VM
./test-ha.sh test-nixos-ha    # Test HA configuration for test-nixos-ha
```

The test-vm.sh script checks:

1. **Ping by IP** - Can reach the VM via IP address
2. **DNS resolution** - Hostname resolves to correct IP
3. **Ping by DNS** - Can reach the VM via DNS name
4. **SSH access** - Can SSH as tappaas (or debian) user
5. **Hostname** - VM reports correct hostname
6. **Internet access** - VM can ping 1.1.1.1
7. **DNS from VM** - VM can resolve and ping google.com

The test-ha.sh script checks HA configuration:

1. **VM status** - VM exists and is running on primary node
2. **HA resource** - VM is registered in HA resources
3. **HA rule** - Node-affinity rule exists for the VM
4. **Rule priorities** - Primary node has priority 2, HA node has priority 1
5. **Replication job** - ZFS replication job exists
6. **Replication target** - Replication target is correct HA node
7. **Replication schedule** - Schedule matches configuration
8. **Replication status** - Replication state is OK
9. **Replicated disks** - VM disks are present on HA node
10. **HA node reachability** - HA node is accessible
11. **Storage availability** - Storage pool exists on HA node
12. **VM connectivity** - Basic ping test to VM
13. **SSH access** - SSH access to VM works

Example output:

```
==============================================
Testing VM: test-nixos (VMID: 604)
Node: tappaas1, Zone: mgmt
==============================================

Running tests...

1. Ping test (by IP)...
  [PASS] Ping VM by IP (10.0.0.123)
2. DNS resolution test...
  [PASS] DNS resolves test-nixos.mgmt.internal to 10.0.0.123
...
==============================================
Test Summary for test-nixos
==============================================
  Passed: 7
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
ssh root@tappaas1.mgmt.internal "qm stop 601; qm destroy 601 --purge"
ssh root@tappaas1.mgmt.internal "qm stop 602; qm destroy 602 --purge"
ssh root@tappaas1.mgmt.internal "qm stop 604; qm destroy 604 --purge"
ssh root@tappaas1.mgmt.internal "qm stop 605; qm destroy 605 --purge"

# For HA VMs, remove HA configuration first
ssh root@tappaas1.mgmt.internal "ha-manager remove vm:607"
ssh root@tappaas1.mgmt.internal "ha-manager rules remove ha-test-nixos-ha"
ssh root@tappaas1.mgmt.internal "pvesr delete 607-0 --force 1"
ssh root@tappaas1.mgmt.internal "qm stop 607; qm destroy 607 --purge"

# On tappaas2
ssh root@tappaas2.mgmt.internal "qm stop 603; qm destroy 603 --purge"
ssh root@tappaas2.mgmt.internal "qm stop 606; qm destroy 606 --purge"
```

## Directory Structure

```text
vm-creation/
├── README.md                 # This file
├── install-debian.sh         # Install script for Debian image VMs
├── install-nixos.sh          # Install script for NixOS clone VMs
├── install-nixos-ha.sh       # Install script for NixOS VMs with HA
├── install.sh                # Legacy install script
├── test.sh                   # Run full test suite (all 7 VMs)
├── test-vm.sh                # Test a single VM (basic tests)
├── test-ha.sh                # Test HA configuration for a VM
├── logs/                     # Test output logs (not in repo)
├── test-debian.json          # Debian on mgmt (tappaas1)
├── test-debian-vlan.json     # Debian on srv VLAN (tappaas1)
├── test-debian-node.json     # Debian on srv VLAN (tappaas2)
├── test-nixos.json           # NixOS clone on mgmt (tappaas1)
├── test-nixos.nix            # NixOS config for test-nixos
├── test-nixos-vlan.json      # NixOS clone on srv VLAN (tappaas1)
├── test-nixos-vlan.nix       # NixOS config for test-nixos-vlan
├── test-nixos-node.json      # NixOS clone on srv VLAN (tappaas2)
├── test-nixos-node.nix       # NixOS config for test-nixos-node
├── test-nixos-ha.json        # NixOS clone with HA on mgmt (tappaas1->tappaas2)
└── test-nixos-ha.nix         # NixOS config for test-nixos-ha
```

## Notes

- Debian VMs use cloud-init for initial configuration
- NixOS VMs are cloned from template 8080 (tappaas-nixos) and configured via nixos-rebuild
- The install-nixos.sh script automatically handles DHCP hostname registration
- Tests on tappaas2 require the tappaas-nixos template to be available on that node
- The test-nixos-ha test case demonstrates HA configuration with:
  - Proxmox HA manager resources for automatic failover
  - Node-affinity rules for priority-based VM placement
  - ZFS replication for data synchronization between nodes
  - The VM prefers tappaas1 (priority 2) but will failover to tappaas2 (priority 1) if needed
