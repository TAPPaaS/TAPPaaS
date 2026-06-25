# templates — tests

## How to run
- **`./test.sh`** (fast) — the module test.sh; validates the template config JSONs
  (`templates.json` + the `tappaas-nixos`/`tappaas-winserver` build configs) and
  parses the service scripts; flags the NixOS test stub.
- **`TAPPAAS_TEST_DEEP=1 ./test.sh`** — adds a check that the template VMs (by
  `vmid`: 8080 nixos, 8081 winserver) exist on the cluster's primary node.
- The per-OS **service tests** are owned by the *consumer* modules and invoked by
  `test-module.sh` for `templates:nixos` / `templates:windows` dependents:
  `./services/<os>/test-service.sh <module-name>` (live, SSH to the VM).

## Standard (fast) tests
- `services/nixos/test-service.sh`: a STUB — prints "(no tests implemented yet)" and exits 0. It asserts nothing.
- `services/windows/test-service.sh` (live, SSH to `tappaas@<vmname>.<zone0>.internal`, zone0 default `srv`):
  - Check 1 — SSH: asserts `ssh … exit 0` succeeds; fatal exit 1 if not (other checks skipped).
  - Check 2 — Guest agent: asserts the `QEMU-GA` Windows service is `Running` (via PowerShell `Get-Service`).
  - Check 3 — tappaas account: asserts the local `tappaas` user exists, is enabled, and is a member of the local Administrators group (resolved by well-known SID S-1-5-32-544); distinct failures for NOTFOUND/DISABLED/NOTADMIN.
  - Check 4 — RDP state: reads `fDenyTSConnections` and asserts the actual RDP enabled/disabled state matches `windows.enableRDP` from the module JSON.

## Deep tests (live; --deep / TAPPAAS_TEST_DEEP=1)
- None — neither service test has a deep tier. The standard windows tests are themselves live (SSH + PowerShell against the VM). Unverified: NixOS baseline correctness entirely (the nixos test is a stub); for Windows, anything beyond the four baseline checks (patch level, network/zone wiring, installed roles/software, RDP reachability through the firewall rather than just the registry flag).

## Coverage notes
- A module `test.sh` now validates the template configs + scripts (fast) and the
  template VMs' presence (deep). The per-OS service tests remain owned by consumer
  modules (they verify a deployed VM against the baseline).
- ⚠️ `services/nixos/test-service.sh` is still a PLACEHOLDER with zero assertions
  ("no tests implemented yet") — the NixOS template baseline is effectively
  UNTESTED despite a green exit. Implementing it is the remaining open item.
- The Windows service test is the only one with real assertions; it covers SSH, guest agent, the tappaas admin account, and RDP-vs-config consistency, but does not validate template provenance, updates, or guest-agent version.
- No fixtures, no teardown/cleanup, and no negative tests — purely read-only probes against an already-provisioned VM.
