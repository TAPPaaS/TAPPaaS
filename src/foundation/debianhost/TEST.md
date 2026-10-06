# debianhost — tests

`test.sh <instance>`:

1. root login by the mothership's key — without it nothing else is checked;
2. the machine runs Debian;
3. no reboot pending — in the pre-update gate (`TAPPAAS_TEST_RUNTIME_ONLY=1`) reported, not
   failed, because the update is what takes it;
4. root filesystem below 90% full;
5. clock synchronised (`timedatectl` `NTPSynchronized`);
6. SSH is key-only, when `sshKeyOnly` is true (the default, #756) — read from what `sshd -T`
   enforces, not from the drop-in's presence. In the pre-update gate reported, not failed: the
   update applies it. With `sshKeyOnly: false` nothing is asserted;
7. (information) how many package upgrades are waiting — not a failure; new ones appear daily.

The decisions without a machine — the script against a stub `sshd`, the field's default, the
boolean override, `adopt --set` — are `tappaas-cicd/scripts/test/test-ssh-key-only.sh` and
`test-adopt.sh`; migration 0013 has `test-migration-0013-key-only.sh`.

The live test plan — stand-in VMs outside TAPPaaS, `adopt`, the lifecycle, removal, PXE — is
[docs/plans/debianhost-test-plan.md](../../../docs/plans/debianhost-test-plan.md).
