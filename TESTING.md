# Testing TAPPaaS

TAPPaaS tests at three levels. They share one file name, `test.sh`, so a result is
only meaningful when it says **which file ran, where, and in which mode**.

| Level | What runs | Where it runs | When | Purpose |
|---|---|---|---|---|
| **1. Component** | Offline suites next to the code: `manager/*/test.sh`, `controller/*/test.sh`, `ui/test.sh`, unit tests (`*.test.ts`, Python `unittest`), and `lib/test-*.sh` / `scripts/test/*.sh` | Anywhere, a developer laptop included. No cluster. | On every code change, before it leaves the developer's machine | A quick, local regression check: did this change break existing behaviour? |
| **2. Module** | `test-module.sh <module>`: the module's configuration, the tests of the services it depends on, and the module's own `test.sh` (fast part) | On the mothership, against the installed module | Before and after every `update-module.sh`, so on every scheduled update | Is the installed module still working? |
| **3. Deep** | `test-module.sh <module> --deep` (or `test.sh --deep`, `TAPPAAS_TEST_DEEP=1`): everything in level 2, plus the deep part of the module's `test.sh` and the live suites it drives | On a test site, supervised | Before a release, and after risky changes | Does the module deliver all of its intended function? As complete as practical; may take long |

## Level 1: component tests

Component tests use fakes and fixtures instead of a live system, so they run on a
laptop. Most of them belong to `tappaas-cicd`: each manager and controller, and the
console, carries its own `test.sh` that compiles its TypeScript, runs its unit suites
and checks its scripts' contracts. A few modules keep offline suites of their own in
`lib/` (backup, cluster, storage, network).

They need the toolchain a mothership has: Node 22, TypeScript 5.9, Python 3.13, bash 5
and GNU coreutils (`timeout`, `stat -c`, `readlink -f`, `date -d`). On a Mac, install
these alongside the system tools (macOS ships BSD tools, bash 3.2 and an old Python),
and keep TMPDIR resolved (`/private/var/...`), because some suites compare it with
bash's `$PWD`. When `tsc` is missing and `nix-shell` exists, the TypeScript suites
fetch their toolchain through `nix-shell` by themselves.

Run one suite from its directory:

```bash
cd src/foundation/tappaas-cicd/manager/module-manager && ./test.sh
```

Suites that call other TAPPaaS scripts find them through `TAPPAAS_BIN`, which defaults
to `/home/tappaas/bin` (the mothership). Point it at a directory of links into your
checkout to run those suites off-site.

## Level 2: module tests

`test-module.sh <module>` runs, in order:

1. validation of the module's configuration;
2. a check that every service the module depends on has a test;
3. those dependency service tests: each provider's `services/<service>/test-service.sh`,
   run on behalf of this module (for example, the cluster's VM test checks that this
   module's VM is up);
4. the module's own `test.sh`.

`update-module.sh` runs it as a gate before and after the update, and compares the two:
only a failure that is new after the update counts against it. Both gates use
`--runtime-only`, which skips a module's checks against the source tree, so a code
defect cannot block the update of a healthy module. A manual `test-module.sh` run
includes those checks.

## Level 3: deep tests

`--deep` adds the module's deep checks: live mutations, fixture VMs, failover and
migration runs. For `tappaas-cicd` it also runs every component suite (level 1) and
the VM-creation and variant suites, so a deep run of that module covers all three
levels. A module without a deep part runs the same checks with or without `--deep`.

## Reporting a result

Name the file, the place and the mode, for example:

- `test-module.sh vaultwarden` on the test site: N passed, 0 failed
- `test-module.sh network --deep` on the test site: N passed, 0 failed
- `manager/module-manager/test.sh` locally: N passed, 0 failed

## More detail

- [src/foundation/TESTING.md](src/foundation/TESTING.md): coverage and known gaps of
  the foundation modules, managers and controllers, check by check. This is the place
  to elaborate on what a suite covers and what it misses.
- `TEST.md` in a module's directory: that module's test plan.

## Inventory (2026-11-09)

Checks per module and level, for every module in this repository (the `00-Template`
skeleton excluded). Regenerate with:

```bash
src/foundation/tappaas-cicd/scripts/test-inventory.py
```

A check is one assertion in the source (a `pass`/`ok`/`check` call, a printed `ok:`/`✓`
line, a TypeScript `check()`/`eq()`, a Python `assert`), counted statically: a check in
a loop counts once, and a skipped check still counts. Measured against real runs, the
counts come within 10–30 % of the number a run reports. Service checks belong to the
provider, but run for every module that consumes the service. Numbers in brackets
are files.

| Module | Component checks (files) | Service checks (files) | Module test.sh: fast | Deep checks | Total |
|---|--:|--:|--:|--:|--:|
| ai/litellm | 53 (3) | 6 (1) | 20 | – | 79 |
| ai/openwebui | – | – | 9 | – | 9 |
| ai/vllm-amd | 7 (1) | 2 (1) | 18 | – | 27 |
| collaboration/coturn | – | 2 (1) | 13 | – | 15 |
| collaboration/euro-office | – | – | 22 | – | 22 |
| collaboration/nextcloud | – | 7 (1) | 21 | – | 28 |
| collaboration/nextcloud-hpb | – | – | 16 | – | 16 |
| devops/forgejo | – | 8 (2) | 17 | – | 25 |
| devops/woodpecker | – | – | 10 | – | 10 |
| foundation/backup | 599 (23) | 12 (2) | 1 | 4 | 616 |
| foundation/cluster | 353 (19) | 18 (3) | 52 | 87 | 510 |
| foundation/console | – | – | 5 | – | 5 |
| foundation/debianhost | – | – | 5 | – | 5 |
| foundation/identity | 32 (1) | 13 (2) | 12 | 22 | 79 |
| foundation/logging | – | 1 (1) | 13 | – | 14 |
| foundation/network | 40 (4) | 16 (6) | 74 | 47 | 177 |
| foundation/pvehost | – | – | 7 | – | 7 |
| foundation/satellite | – | – | 61 | 2 | 63 |
| foundation/storage | 110 (1) | 6 (1) | 1 | 45 | 162 |
| foundation/tappaas-cicd | 13545 (383) | – | 59 | 188 | 13792 |
| foundation/templates | – | 5 (3) | 3 | 1 | 9 |
| home/deconz | – | 4 (2) | 4 | – | 8 |
| home/hass | – | – | 17 | – | 17 |
| home/immich | – | – | 18 | – | 18 |
| home/jellyfin | – | – | 16 | – | 16 |
| home/karakeep | – | – | 11 | – | 11 |
| home/nomad | – | – | 12 | – | 12 |
| misc/windows-server | – | – | 0 | – | 0 |
| security/netbird-client | – | – | 0 | – | 0 |
| security/vaultwarden | – | – | 7 | – | 7 |
| web-hosting/lazysite | – | – | 10 | – | 10 |
| **All 31 modules** | **14739 (435)** | **100 (26)** | **534** | **396** | **15769** |

What the numbers say:

- **Every module has a `test.sh`**, but two carry no checks of their own:
  `netbird-client` is still the template stub, and `windows-server` hands off to the
  templates' Windows service test.
- **Deep coverage is thin:** 8 of 31 modules have deep checks, all of them foundation
  modules. No application module has a deep part yet.
- **Component tests sit almost entirely in `tappaas-cicd`** (92 % of them): the
  managers, controllers and console. Among the other modules, only backup, cluster,
  storage, network, identity, litellm and vllm-amd carry offline suites.
- **Fast module tests are short:** most application modules check 7–22 things, which
  fits their purpose (is it up and reachable?) but says little about function.
