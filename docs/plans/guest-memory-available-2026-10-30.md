# guest-memory reads what a guest can use, live test 2026-10-30

`guest-memory` took Proxmox's `mem` as used. That figure is the balloon's total minus MemFree, so page cache counted as used and every busy Linux guest read about 90 % (measurement in `adr-041-live-test-plan.md`, "Memory measurement, 2026-10-30"). Used is now total minus available from the balloon statistics, read on the node with `qom-get /machine/peripheral/balloon0 guest-stats` in the node's one ssh. The thresholds stay at 75 and 90.

Test on hrossen, read-only. `validate` reads the stored result of the last assess and `validate --live` writes conditions to the CMDB, so the rows below come from `checkGuestMemory` with the real client, called directly from the installed code and from a build of this branch in `~/tmp-work/guestmem`, one straight after the other.

| guest | before (installed) | after (this branch) |
|---|---|---|
| tappaas-cicd | FAIL `16.0G 15.8G 14.9G 93% of declared, gap 1.0G` | pass `16.0G 15.8G 1.1G 7% of declared, gap 14.7G, cache 11.9G` |
| immich | FAIL `8.0G 7.5G 7.3G 91% of declared, gap 0.2G` | pass `8.0G 7.5G 1.3G 16% of declared, gap 6.2G, cache 6.3G` |
| network | skip `8.0G 7.9G unmeasured` | skip `8.0G 7.9G unmeasured` (unchanged) |
| VM totals | `96.5G 78.6G 66.2G reclaimable 4.8G` | `96.5G 78.6G 18.8G reclaimable 51.8G` |
| the gate | **fail**, 9 critical, 4 warn | **pass**, none critical, none warn, in 18.1 s against 10.4 s |

`network` is the fallback for a guest that reports nothing: a FreeBSD guest has every statistic at 2^64-1 and `last-update` 0, which is rejected as absent. No guest on hrossen has a balloon driver without an available figure, so the `cache counts as used` row is exercised by the unit test only, with no Windows guest to confirm it live.

The probe costs about 0.4 s per running VM (`qm monitor` starts a Perl process each time), 8 s on hrossen's 20 VMs, for each `nodeCapacity` call. Two gates call it in one assess (`memory-commitment` and `guest-memory`), so an assess takes about 16 s longer.

`reclaimable` now includes page cache, which is true of a balloon (the guest gives cache up when the balloon inflates) but makes the total much larger than before. The stored `validate` rows change at the first assess after this is deployed.
