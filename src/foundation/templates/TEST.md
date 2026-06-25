# templates — tests

## How to run
There is NO module-level `test.sh` for templates. Tests are per-service and invoked by `test-module.sh` for modules that depend on the corresponding `templates:*` capability:

- `./services/nixos/test-service.sh <module-name>` — for `templates:nixos` dependents.
- `./services/windows/test-service.sh <module-name>` — for `templates:windows` dependents.
- Exit codes: 0 pass, 1 failed checks, 2 fatal (missing module-name arg or missing module JSON).
- Both are live tests that SSH into the target VM; neither has a `--deep` / `TAPPAAS_TEST_DEEP` tier.

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
- MISSING top-level `test.sh`: templates has no module test.sh aggregating these service tests; they only run when `test-module.sh` evaluates a dependent module's `templates:nixos` / `templates:windows` dependency.
- `services/nixos/test-service.sh` is a PLACEHOLDER with zero assertions ("no tests implemented yet") — the NixOS template baseline is effectively UNTESTED despite being a green exit.
- The Windows service test is the only one with real assertions; it covers SSH, guest agent, the tappaas admin account, and RDP-vs-config consistency, but does not validate template provenance, updates, or guest-agent version.
- No fixtures, no teardown/cleanup, and no negative tests — purely read-only probes against an already-provisioned VM.
