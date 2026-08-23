# ADR-014 Migration Runbook — upgrading an existing TAPPaaS to the zone lifecycle

**Companion to:** [ADR-014](<../ADR/ADR-014 - Zone and Environment Lifecycle.md>) (the decision) ·
[ADR-014-implementation.md](ADR-014-implementation.md) (the build log)
**Audience:** the operator of an existing install, upgrading across the ADR-014 release.
**Fresh installs need none of this** — `install.sh` runs `network-manager init core` and the result is
already correct.

---

## What this migration does, and does not, change

| | |
|---|---|
| **Does not change** | **Any firewall pass rule.** The `access-to` graph — the only field that compiles to rules — comes out byte-identical. Verified on a production config. |
| **Does not change** | Which zone any deployed module lives in. Installed modules stay put; the occupancy guard refuses to retire a zone that still hosts one. |
| **Changes (authored)** | Client/IoT zones gain a `serves` link and lose the literal service-zone reference it replaces. |
| **Changes (authored)** | Every shipped zone gains `tier`, and the isolated ones gain `isolated`. |
| **Changes (policy)** | Three IoT zones' `pinhole-allowed-from` swap a renamed-away name (`srvHome`) for the live service zone. This creates **no rule** — it is a policy gate — and it *is* the #424 fix: a module in the live service zone previously could not declare a pinhole into those zones at all. |
| **Removes** | Up to ten zones the release stopped shipping — but only ones that are both switched off and unoccupied, and only when you run `retire --apply`. |
| **Adds a file** | `config/zones.effective.json` — generated, never hand-edited. |

**Expected residue:** exactly **one** `I1` warning from `validate --effective` — the client→service edge
(`home` tier 2 → `<env>` tier 1). That is the deliberate, deferred part of ADR-014 (decision F2), not a
fault. Nothing is wired to fail on it.

---

## Before you start

```bash
# 1. Archive the config that matters. Cheap, and it is the real rollback.
BK=~/config/baseline-adr014-$(date +%Y%m%d)
mkdir -p "$BK" && cd ~/config
cp -a zones.json zones.json.orig zones.rename.json site.json "$BK"/ && cp -a environments "$BK"/

# 2. Record the "before" picture — you will diff against this.
network-manager list                    > "$BK"/before-list.txt
network-manager validate                > "$BK"/before-validate.txt 2>&1

# 3. Snapshot tappaas-cicd (Proxmox). This is the backstop for everything below.
```

> **Pause unattended updates while you work.** Set `updateSchedule` in `~/config/site.json` to
> `["none", …]`; the hourly timer keeps ticking and logs "Updates disabled", which is a useful heartbeat.
> Restore the frequency when you are done.

---

## Step 1 — take the release

```bash
update-tappaas --force        # or wait for the schedule
```

`pre-update.sh` pulls, rebuilds the managers, then runs `network-manager merge`, which performs the
**`serves` back-fill** as part of the merge (it already holds the rename context). Expect output like:

```
serves back-fill: 2 zone(s) linked to an environment
    iot  → serves '<env>' (dropped literal '<env>' from pinhole-allowed-from)
    home → serves '<env>' (dropped literal '<env>' from access-to)
```

**Assert the invariant before going further.** The authored file changed; the graph the planes receive
must not have:

```bash
network-manager reconcile           # dry-run: renders zones.effective.json, converges nothing
network-manager validate            # authored scope
network-manager validate --effective   # the graph zone-manager actually receives
```

Both should exit 0. If `validate` reports **errors** (not warnings), stop and read them — an unresolved
`serves` link means an environment file is missing or misnamed, and it is fixable with
`network-manager bind <zone> --environment <env>` or by creating the environment.

---

## Step 2 — retire what the release stopped shipping

```bash
network-manager retire              # DRY RUN — read this carefully
```

It reports, per zone, either "would remove" or "KEPT" with the reason. Read the KEPT lines: a zone is
kept when it is still `Active`/`Mandatory`/`Manual`, or when a deployed module still names it. Both are
protections, not obstacles — retiring either would tear down a live interface or orphan a running
service.

If you want a kept-but-unwanted zone gone, deal with the reason first:

```bash
network-manager disable <zone> && network-manager reconcile --apply   # if it was still live
# or migrate/remove the module that occupies it, then re-run retire
```

When the dry run says what you expect:

```bash
network-manager retire --apply
network-manager reconcile --apply   # converge the (now smaller) desired state
```

`retire` also strips every reference to the removed zones from the zones that named them, so no dangling
reference is left behind.

---

## Step 3 — verify

```bash
network-manager list                       # compare with $BK/before-list.txt
network-manager validate --effective       # expect: errors 0, warnings 1 (the I1 client→service edge)
```

Then confirm nothing moved on the wire. The strongest check is a rule diff, but a functional spot-check
is usually enough:

- a service in the default environment is still reachable from `home`;
- IoT devices still respond (`iotLocal` / `iotCloud`);
- a Caddy-proxied service with an explicit `proxyAllowedZones` still loads from an allowed zone **and
  still 403s from a disallowed one**.

Run the regression suites if you want the full picture:

```bash
(cd ~/TAPPaaS/src/foundation/tappaas-cicd/manager/network-manager     && ./test.sh)
(cd ~/TAPPaaS/src/foundation/tappaas-cicd/manager/environment-manager && ./test.sh)
(cd ~/TAPPaaS/src/foundation/tappaas-cicd/manager/module-manager      && ./test.sh)
```

---

## Optional — opt in to the IoT segment set

The IoT zones are now opt-in. An existing install that already has them keeps them (nothing removes a
zone you are using). A site that wants them:

```bash
network-manager init iot --name <defaultEnvironment>
network-manager reconcile --apply
```

This adds the four zones and the `grants` they need — control-plane visibility, and reach from the
service and client zones to the controlled devices.

---

## Rollback

```bash
cp -a $BK/zones.json $BK/zones.json.orig $BK/zones.rename.json ~/config/
cp -a $BK/environments ~/config/
rm -f ~/config/zones.effective.json
network-manager reconcile --apply
```

Point the repo back at the previous release and re-run the update:

```bash
site-manager repository modify TAPPaaS --branch <previous-branch>
update-tappaas --force
```

The Proxmox snapshot is the backstop if the config restore is not enough.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `validate`: `serves … has no readable environments/<env>.json` | a zone is bound to an environment that does not exist | `environment-manager add <env>` — or `network-manager bind <zone> --unbind` |
| `reconcile` refuses: "unresolved 'serves' link(s)" | same as above; reconcile is fatal on it by design | fix the binding, then re-run |
| `environment reconcile`: "is a Client zone, not a Service zone" | the environment points at a client/IoT zone | `environment-manager modify <env> --zone <serviceZone>`, or bind the client zone the other way with `network-manager bind` |
| A module install now fails on `proxyAllowedZones` | it names a zone that no longer resolves — this used to be dropped silently, leaving a reduced allow-list | fix the module's `proxyAllowedZones`; check names with `network-manager list` |
| `validate` notes "N zone(s) carry no 'tier'" | operator-added zones the template never shipped | harmless; back-fill by recreating with `add --archetype <A>`, or leave them — they are simply skipped by I1/I3/I4 |
| One `I1` warning after migration | the deferred client→service edge (F2) | expected; nothing is wired to fail on it |
