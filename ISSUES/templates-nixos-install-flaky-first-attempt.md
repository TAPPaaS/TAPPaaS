# templates:nixos install flaky for VMs in freshly-activated zones

> **GitHub issue**: TAPPaaS/TAPPaaS#309

**Observed**: 2026-05-16, during three back-to-back `firewall/test.sh --deep` runs while validating issues #173 and #177.

## Symptom

When `install-module.sh` is run for a NixOS module immediately after the
module's zone was just activated by `zone-manager`, the
`templates:nixos` install-service step fails on the first attempt with a
generic error:

```
[Error] Service installer failed: templates:nixos
```

The retry helper in `firewall/test.sh` (`install_with_retry`) handles this
by deleting the partially-created VM and re-running `install-module.sh`. For
**test-fw-a** and **test-fw-b** the retry consistently succeeds. For
**test-fw-c** (in the new `test3` zone) the retry also failed in 2 of 3
deep runs:

```
[Error] Service installer failed: templates:nixos
[Warning]   First install of test-fw-c failed (likely cloud-init race) — retrying once after cleanup...
[Error] Service installer failed: templates:nixos
[Error]     ✗ install-module.sh test-fw-c (failed twice)
```

The VM does come up (it gets a DHCP IP and registers in DNS), but only with
the **base NixOS template** configuration — the consumer's `<vmname>.nix`
overlay was never applied. Diagnostics inside the VM after the failed
install confirm this:

```
$ ssh tappaas@test-fw-c.test3.internal "hostname; systemctl is-active tappaas-test-webserver"
tappaas-nixos             # not 'test-fw-c'
Unit tappaas-test-webserver.service could not be found.
$ ss -tlnp | head        # only sshd, no webserver on 9091
LISTEN 0  128  0.0.0.0:22  0.0.0.0:*
```

Running the same `nixos-rebuild` command manually a few minutes later
**succeeds**:

```bash
$ cd src/foundation/firewall/test-fixtures/test-fw-c
$ nixos-rebuild --target-host tappaas@10.80.30.187 --use-remote-sudo switch \
                -I nixos-config=./test-fw-c.nix
# ... copies paths, activates, starts tappaas-test-webserver.service
$ Done. The new configuration is /nix/store/...nixos-system-test-fw-c-...
```

So the underlying `nixos-rebuild` works; the failure is purely timing-related
during the install pipeline.

## Why this matters

A silent half-install is the worst failure mode:

- The VM is "up" in DNS and reachable on sshd, looking healthy from PVE.
- `install-module.sh` reports `failed twice` and downstream test steps that
  expect the .nix to be applied (`Deep 3: Verify test-fw-a webserver`, etc.)
  fail with confusing symptoms like "service unit not found" or "port not
  listening" — far removed from the actual root cause two steps upstream.
- This recently bit issue #177's Deep 9b validation: test-fw-c was the
  auto-pinhole *provider* fixture, but its webserver never came up, so the
  AC-2 curl failed with "connection timed out" — a red herring that took
  many diagnostics to unwind back to "templates:nixos retry-also-failed".

## Likely root cause

`update-os.sh` (templates:nixos's worker) chains:

1. `wait_for_vm_ip()` — DHCP-driven, returns the first IP that pings
2. `wait_for_ssh()` — first successful SSH login on port 22 with our key
3. `wait_for_cloud_init()` — runs `cloud-init status --wait` on the target
4. `nixos-rebuild --target-host switch -I nixos-config=./<vmname>.nix`

A working hypothesis: a race between steps 2 and 3 — SSH accepts the
connection but cloud-init isn't done setting up `/etc/nixos`,
`/etc/ssh/authorized_keys`, or the `tappaas` user's sudo. The
`nixos-rebuild` then sees a partially-initialised target and bails. The
generic "Service installer failed" message swallows the actual stderr that
would identify which step exploded.

It also affects newly-activated zones more than long-standing ones — likely
because OPNsense's freshly-created zone interface, dnsmasq lease tables,
and Unbound forward map all need to converge before the new VM is fully
reachable, and the per-step waits in `update-os.sh` may exit too early on
the first-ever VM in a new zone.

## Concrete asks

1. **Surface the real error.** `install-service.sh` for templates:nixos
   currently calls `update-os.sh` and discards stderr; only the generic
   "Service installer failed" leaks out. Capturing the last 20 lines of
   `update-os.sh` stderr to a `/tmp/<module>-templates-nixos-install.err`
   on failure (and printing them to the install log) would have saved
   hours during this #177 investigation.

2. **Tighten the post-SSH wait.** Wait for `cloud-init status --wait` to
   actually return `done` (current code waits with a fixed sleep, IIRC),
   AND verify `sudo -n true` over SSH succeeds before proceeding to
   `nixos-rebuild`. The current heuristic appears too optimistic for
   first-VM-in-fresh-zone.

3. **Retry the right thing.** `install_with_retry` in `firewall/test.sh`
   retries `install-module.sh`, which re-does the entire VM creation
   including the disk clone. The actual failure is in step 4
   (`nixos-rebuild`), which could be retried on its own without
   recreating the VM. A `update-os.sh --retry-nix-only` mode (or a
   bounded retry loop inside `update-os.sh` itself, with linear backoff
   between `nixos-rebuild` attempts) would be far cheaper and more
   reliable than the current "delete the VM and start over" approach.

## Reproduction recipe

```bash
# From a cluster where test1/test2/test3 zones are currently Inactive:
cd /home/tappaas/TAPPaaS/src/foundation/firewall
./test.sh --deep
# Watch Deep 2a — test-fw-c's install will sometimes fail twice.
# When it does, ssh into the VM via its DHCP IP (NOT the FQDN, which DNS
# lookup will redirect to a stale lease from an earlier successful run):
$ ssh tappaas@<test-fw-c-current-ip> hostname
tappaas-nixos
# Now run nixos-rebuild manually — it succeeds:
$ cd src/foundation/firewall/test-fixtures/test-fw-c
$ nixos-rebuild --target-host tappaas@<ip> --use-remote-sudo switch \
                -I nixos-config=./test-fw-c.nix
```

## Workaround in the firewall test suite

`install_with_retry` already does one retry. Until the underlying issue is
fixed, the test suite can be made more robust by:

- Increasing retry count to 2 (so a fresh-zone VM has 3 attempts total).
- Sleeping 30s between the failed install and the retry, giving cloud-init /
  Unbound / dnsmasq more time to converge.
- Surfacing `update-os.sh` stderr from the failed attempts into the test
  log so an operator can see *what* failed when it does.

These are bandaids — the real fix is in `update-os.sh` / templates:nixos's
install-service.

## Related

- Surfaces during #177 Deep 9b validation (auto-pinhole live test), but is
  independent of #173.
- Adjacent to (but distinct from) the OPNsense FQDN-alias async-population
  timing race documented in [zone-manager-block-private-shadows-auto-pinholes.md](zone-manager-block-private-shadows-auto-pinholes.md);
  both stem from the same family of "TAPPaaS waits aren't tight enough on
  cold start".

## Out of scope for #177

The auto-pinhole work in #173 and the test expansion in #177 are unaffected
by this issue — auto-pinhole rules are correctly created in OPNsense
regardless of whether the provider VM's nixos config applied. Filing here so
the work can be picked up separately.
