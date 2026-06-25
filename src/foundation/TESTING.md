# TAPPaaS test coverage (foundation)

Cross-component view of the test suites: every component exposes a **`test.sh`**
(the component contract) with a **fast tier** (offline / non-disruptive, always
run) and an optional **deep tier** (live, gated by `TAPPAAS_TEST_DEEP=1` and/or
`--deep`). Per-component detail is in each component's **`TEST.md`**.

> **How to run everything:** each module/manager/controller `./test.sh` (fast) or
> `TAPPAAS_TEST_DEEP=1 ./test.sh` (deep). The TS managers also run offline unit
> suites (compiled with `tsc`, injected fakes) inside their fast tier.

## Modules

| Module | test.sh | Fast | Deep tier | Gap |
|--------|:-------:|------|-----------|-----|
| cluster | ✅ | script presence + `vm-net.sh` unit suite + `cluster:vm --check` | ✅ live vm/ha/lxc reconcile (#192/#193/#203) | live migration not exercised |
| network | ✅ | zones audit + opnsense compile + **unifi-plugin unit (incl. `tagged_vlan_mgmt:custom` regression)** + plane-bin-resolves | ✅ live OPNsense rules/NAT/connectivity; switch+ap **5-verb lifecycle via generic/manual plugin only** | no live switch/AP hardware path; proxmox apply + top-level network-manager reconcile only smoke-tested |
| identity | ✅ | Authentik reachable + role groups + allow-list grep | ✅ live forward-auth gating vs OIDC passthrough (fixture VMs) | §3 is a source grep, not enforcement |
| logging | ✅ | **live** 8 health probes (Loki/Grafana/Promtail/syslog) | ❌ **none** | liveness-only; ingest assertion weak; no retention/dashboards/alerting |
| backup | ✅ | `lib/test-pbs-*.sh` unit suites (9 asserts: vmid-list CSV + ACL/parent/retention) | ✅ live PBS reachability via `backup-controller list` | per-VM backup verification is the consumers' `backup:vm` service test; no restore/encryption/prune/GC verification |
| templates | ✅ | template config JSONs valid + service scripts parse (+ flags the NixOS stub) | ✅ template VMs present on the cluster (qm status) | **NixOS `services/nixos/test-service.sh` is still a STUB (zero assertions)** — the base image's applied config is unverified (tracked TODO); Windows test = 4 baseline items |
| tappaas-cicd | ✅ | config-reader unit tests + bin presence/load smoke | ✅ live VM create/reinstall/snapshot-rollback/variants; re-dispatches manager+controller suites | Test 11 component checks shallow; silent skips when optional bins absent |

## Managers (all have `test.sh` ✅; all run offline unit suites in fast tier)

| Manager | Fast (unit) | Deep/live tier | Gap |
|---------|-------------|----------------|-----|
| people-manager | reconcile + entity CRUD (incl. ref guards) | ✅ **strong** — live Authentik OIDC/forward-auth via fixture VMs | — |
| network-manager | reconcile orchestration (FakePlaneClient) + plane-bin-resolves | ✅ live reconcile **dry-run** | apply path not driven from the manager test (covered in network module) |
| environment-manager | config CRUD + cascade | ✅ **light** — read-only-validates the live env | cascade apply not exercised live |
| module-manager | list/show/validate + reconcile delegation (39 asserts) | ⚠️ gate exists but **same as fast (no live probes)** | no live install/update/reconcile probe |
| site-manager | validate + reconcile dispatch | ⚠️ **no extra deep** | cascade/`--deep` not live-tested |
| backup-manager | cascade resolve + validate + modify (46 asserts) | ⚠️ **no live** (pure config — defensible) | the actual PBS push lives in backup-controller (see below) |
| health-manager | inspect/gate unit tests (23 asserts) | ❌ **no deep gate at all** | the manager *reads the live cluster* (`list vm`, `validate`) yet has **no live tier** to exercise it |

## Controllers

| Controller | test.sh | Tests | Gap |
|-----------|:-------:|-------|-----|
| opnsense-controller | ✅ | `test.sh` builds (nix) + runs the stdlib `unittest` suite — **152 tests** (zone/rules/dhcp/caddy/acme/dns) | live behaviour additionally exercised via `network/test.sh` |
| proxmox-controller | ✅ dispatcher | → `test-proxmox-manager.sh` (unit) | live apply only smoke-tested (in network) |
| switch-controller | ✅ dispatcher | → `test-switch-controller.sh` + `test-setup-switches.sh` | no live vendor-apply test (the UniFi 10.x fix was verified manually on hardware) |
| ap-controller | ✅ dispatcher | → `test-ap-manager.sh` + `test-setup-wlan-secrets.sh` | no live AP path |
| backup-controller | ✅ inline | PBS job/namespace/verify + `--json` | live PBS mutation (`add-to-job`/`apply-schedule`) not live-tested |
| identity-controller | ✅ runs unittest | → `python -m unittest` → `test_authentik_manager.py` + `test_people_primitives.py` | — |

## Coverage gaps & recommendations (prioritized)

**P1 — missing `test.sh` (component contract holes) — ✅ DONE:**
1. ✅ **opnsense-controller** — added `test.sh` (nix-build + `python -m unittest discover`); **152 tests** now run under the contract (were orphaned).
2. ✅ **backup module** — added `backup/test.sh` aggregating the `lib/test-pbs-*.sh` unit suites (9 asserts) + a deep live-PBS check.
3. ✅ **templates module** — added `templates/test.sh` (config + service-script validation + deep template-VM check). ⚠️ **Still open:** the NixOS `services/nixos/test-service.sh` is a zero-assertion stub — the base image's applied config remains unverified (its `test.sh` runs but asserts nothing). Implementing it is the remaining piece.

**P2 — weak/missing deep tiers (live behaviour unverified):**
4. **health-manager** — add a deep tier exercising `list vm`/`validate` against the live cluster (it's a live-reading manager with no live test).
5. **logging** — add a deep tier (remote syslog → Loki ingest, retention) — today only local liveness.
6. **backup** — the vm-service deep checks **only warn**; make "backup older than 48h / VMID not in a job" **fail** so regressions are caught.

**P3 — assertion quality:**
7. **module/site managers** — their deep gate is a no-op; add at least one live reconcile probe (or document that fast coverage is sufficient and remove the empty gate).
8. **identity** §3 source-grep → assert the live binding instead; **logging** ingest assertion is too weak (≥1 job label).
9. **switch/ap/proxmox controllers** — live vendor/apply paths are only smoke-tested; a tagged live tier (opt-in) would close the hardware gap.

**Overall:** managers are the best-covered layer (unit suites + people/network live tiers). The real holes are at the **module edges** (backup, templates) and the **opnsense-controller contract wrapper** — all three are *missing a `test.sh`*, so a green `update-tappaas`/CI run does not exercise them.
