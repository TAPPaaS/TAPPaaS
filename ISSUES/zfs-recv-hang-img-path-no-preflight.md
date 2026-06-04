# tappaas2: D-state `zfs recv` for vm-110 blocks `imageType=img` deploys silently

> **GitHub issue**: TAPPaaS/TAPPaaS#308

**Observed**: 2026-05-16, while validating issue #147 with `test-debian-srv-lan2.json` on its native node tappaas2.

## What we saw

On tappaas2:

```text
ps -eo pid,stat,etime,cmd --no-headers | awk '$2 ~ /D/ && /zfs recv/'
1279754 D       01:07:14 zfs recv -F -- tanka1/vm-110-disk-0
```

The receive is for `vm-110-disk-0` = the **production firewall**, mid-replication from tappaas1 → tappaas2.
Firewall itself is running on tappaas1, so day-to-day traffic is fine. **HA failover for the firewall is broken until tappaas2 is rebooted** — D-state processes cannot be killed from user-space; only a reboot clears them.

dmesg confirms the known ZFS workqueue hang pattern:

```text
__wait_for_common
wait_for_completion
__flush_workqueue
zvol_os_add_disk
zvol_os_create_minor
zvol_task_cb
```

This is the **exact same pathology** that
[Create-TAPPaaS-VM.sh:347-388](../src/foundation/cluster/Create-TAPPaaS-VM.sh#L347-L388)
already has a pre-flight check for. From that block:

```bash
# Detect that up-front and capture diagnostics so the operator can act.
info "Pre-flight check for stale migration state on ${CURRENT_NODE}..."
STALE_SNAPS=$(zfs list -H -t snapshot -o name 2>/dev/null | grep '@__migration__' || true)
STUCK_RECV=$(ps -eo pid,stat,cmd --no-headers 2>/dev/null | awk '$2 ~ /D/ && /zfs recv/' || true)
if [ -n "$STALE_SNAPS" ] || [ -n "$STUCK_RECV" ]; then
    ...
fi
```

## The gap

That pre-flight only runs inside the `imageType == "clone"` branch of `Create-TAPPaaS-VM.sh`.
The `imageType == "img"` branch (lines 284-293) does **not** check for the same condition, so:

- `qm importdisk` queues behind the stuck `zfs recv`
- The installer process hangs with no diagnostic
- The operator's only signal is a long-running install with stale output
- The standard `--force` cleanup leaves a 56K phantom zvol (`tanka1/vm-909-disk-0` in this incident) that cannot be `zfs destroy`ed until the pool is unstuck

## Proposed fix

Hoist the pre-flight check out of the `clone` branch and run it unconditionally
before any VM-creation work that will touch ZFS on the target node — i.e. for
both `clone` and `img` paths. The check is read-only and cheap; running it
always makes the failure mode loud and recoverable.

Optionally also: have the check inspect the *target* storage pool rather than
the whole system, so `tankb1` work isn't blocked by `tanka1` damage.

## Reproduction / current incident

- Node: tappaas2
- Stuck recv start: ~15:14, observed at 16:22 still in D-state
- Replication snapshots for vm-110 present:
  ```
  tanka1/vm-110-disk-0@__replicate_110-0_1778936400__
  tanka1/vm-110-disk-0@__replicate_110-0_1778937300__
  ```
- Orphaned phantom volume from the aborted #147 test:
  ```
  tanka1/vm-909-disk-0   56K
  ```
- Required action: reboot tappaas2 (will clear D-state + restore firewall HA replication).

## Out of scope for #147

The #147 fix landed cleanly; the validation was just deflected to tappaas3
because the native node was wedged. This ticket is the separate concern.
