# firewall/test.sh --deep: two defects found (June 2026)

Discovered while validating the ADR-005 Caddy work. The firewall `--deep` suite
had never actually run end-to-end (a `local` outside a function aborted it at
Deep 1 — fixed in commit 3f84658), which hid the two defects below. **Until both
are fixed, `firewall/test.sh --deep` is unsafe to run against a live firewall.**

## Defect 1 — trunk-sync clobbers the firewall VM NIC config (SERIOUS)

The deep block (around the "Sync OPNsense VM net0 trunks" section) treats
`firewall.json` `trunks0` as a **zone-name list**: it appends the test zone name
to it and re-derives VLAN tags itself. But the firewall uses the sentinel
`trunks0 = "ALL"`, which `firewall/update.sh` resolves to *all active zones* via
`vmnet_resolve_trunks`. The deep test instead:

1. mangled `trunks0` to `ALL;testPinhole`, and
2. ran `qm set 110 --net0 '…,trunks=830'` — overwriting the firewall VM's NIC
   config to a SINGLE VLAN (830).

`qm set --net0` did not hot-apply to the running VM, so production stayed up — but
the **config** was left at `trunks=830`, which would have dropped every tagged
zone on the next firewall reboot. Manual recovery was required: restore
`net0 trunks=210;220;230;310;320;410;420;430;510;610`, reset `trunks0="ALL"`,
revert test zones to Inactive, delete leftover VMs, re-run zone-manager.

Also: only the test-fw-c provider zone (830) was ever added to trunks0 —
testAllowA (810) / testAllowB (820) were not — so even past defect 2 those VMs
would get no DHCP.

**Fix:** the deep test must use the SAME mechanism as `firewall/update.sh` —
keep `trunks0="ALL"` and call `vmnet_resolve_trunks "ALL" zones.json` (the test
zones are Active by then, so they're included automatically). And `cleanup_deep`
must restore the firewall `net0` trunks (and `trunks0`) on teardown.

## Defect 2 — nix-build fails: parent-relative .nix import not copied to the VM

`test-fw-c.nix` lives in `test-fixtures/test-fw-c/` and imports the shared
overlay one level up:

    imports = [ /etc/nixos/hardware-configuration.nix  ../test-fw-webserver.nix ];

`update-os.sh` copies `<vmname>.nix` plus **same-directory** sibling `.nix` files
into `/etc/nixos/` on the VM. It does not copy a parent-relative import, and once
the file is flattened to `/etc/nixos/test-fw-c.nix` the `../` resolves to
`/etc/test-fw-webserver.nix`, which does not exist:

    error: path '/etc/test-fw-webserver.nix' does not exist
    nixos-rebuild … returned non-zero exit status 1

(test-fw-a.nix imports `./test-fw-webserver.nix` same-dir, which *would* be copied
— it just failed earlier on the 810 trunk/no-IP issue.)

**Fix options:** (a) place a copy of `test-fw-webserver.nix` inside `test-fw-c/`
and import `./test-fw-webserver.nix`; (b) inline the overlay into `test-fw-c.nix`;
or (c) teach `update-os.sh` to copy parent-relative `imports`. New fixtures should
be **self-contained** (no cross-dir imports) — see `test-caddy-web.nix`.

## Note

The standalone Caddy test (`firewall/test-caddy-public.sh`, Option B) deliberately
avoids both defects: it places its webserver in an already-active zone (no zone
activation, no trunk-sync) and uses a self-contained `.nix` (no cross-dir import).
