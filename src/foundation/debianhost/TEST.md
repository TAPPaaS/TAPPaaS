# debianhost — tests

`test.sh <instance>`:

1. root login by the mothership's key — without it nothing else is checked;
2. the machine runs Debian;
3. no reboot pending — in the pre-update gate (`TAPPAAS_TEST_RUNTIME_ONLY=1`) reported, not
   failed, because the update is what takes it;
4. root filesystem below 90% full;
5. clock synchronised (`timedatectl` `NTPSynchronized`);
6. (information) how many package upgrades are waiting — not a failure; new ones appear daily.

The live test plan — stand-in VMs outside TAPPaaS, `adopt`, the lifecycle, removal, PXE — is
[docs/design/debianhost-test-plan.md](../../../docs/design/debianhost-test-plan.md).
