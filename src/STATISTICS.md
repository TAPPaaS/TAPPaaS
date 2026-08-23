# TAPPaaS Source Statistics

Generated: 2026-08-23 — branch `feat/adr-014-zone-lifecycle`, commit `ddab5fc`

Previous snapshot (2026-04-02) is kept in [STATISTICS-v1.md](STATISTICS-v1.md).

Counts are physical lines (`wc -l`) over `src/`. Excluded throughout:
`foundation/Deprecated/` (archived code, formerly `Attic/`), `apps/00-Template/`
(template scaffolding), `__pycache__/` (`.pyc` bytecode), the `STATISTICS*.md`
files themselves, and binary/lockfile artifacts (`.deb`, `.lock`).

Source types counted in the totals: `.sh` (including extensionless files with a
bash shebang), `.ts`, `.py`, `.nix`, `.md`, `.php`. Data and config files
(`.json`, `.xml`, `.template`, `.yaml`/`.yml`, `.toml`, `.csv`, `.txt`,
`LICENSE`) are reported separately and are **not** in the totals.

## Foundation (`src/foundation/`)

| File Type           | Files  | Lines  |
|---------------------|-------:|-------:|
| Bash (.sh)          |    299 | 51,530 |
| TypeScript (.ts)    |     89 | 22,633 |
| Python (.py)        |     56 | 21,470 |
| Documentation (.md) |     93 | 14,606 |
| NixOS (.nix)        |     37 |  3,639 |
| PHP (.php)          |      1 |    260 |
| **Total**           |**575** |**114,138** |

The 299 bash files include 6 extensionless controller entrypoints
(`ap-controller`, `backup-controller`, `proxmox-controller`,
`switch-controller`, `opnsense-ensure-patches`, `zone-reconcile` — 1,864 lines).
The single PHP file is the OPNsense `InterfaceAssignController.php` patch.

### By subsystem

| Subsystem        | Files  | Lines  |
|------------------|-------:|-------:|
| `tappaas-cicd`   |    363 | 81,942 |
| `network`        |     56 |  9,810 |
| `cluster`        |     40 |  9,190 |
| `backup`         |     35 |  3,754 |
| `identity`       |     20 |  2,483 |
| `templates`      |     24 |  2,304 |
| (top-level docs & installers) | 7 | 1,917 |
| `satellite`      |     20 |  1,362 |
| `logging`        |      9 |  1,301 |
| `schemas`        |      1 |     75 |
| **Total**        |**575** |**114,138** |

### Inside `tappaas-cicd`

| Layer              | Files  | Lines  |
|--------------------|-------:|-------:|
| `manager`          |    166 | 36,920 |
| `controller`       |    116 | 29,352 |
| `scripts`          |     20 |  4,689 |
| `lib`              |     19 |  3,810 |
| (top-level)        |     13 |  2,803 |
| `test-vm-creation` |     15 |  2,195 |
| `update-tappaas`   |      7 |  1,062 |
| `test-variants`    |      6 |    763 |
| `test-repository`  |      1 |    348 |
| **Total**          |**363** |**81,942** |

## TypeScript (`.ts`)

TypeScript is the implementation language of the manager layer and was missing
from the previous revision of this document. All 89 files / 22,633 lines:

| Module                     | Files  | Lines  |
|----------------------------|-------:|-------:|
| `manager/network-manager`  |     15 |  5,684 |
| `manager/module-manager`   |     13 |  4,301 |
| `manager/people-manager`   |     14 |  3,283 |
| `manager/environment-manager` |  12 |  2,968 |
| `manager/site-manager`     |      9 |  2,136 |
| `manager/backup-manager`   |     10 |  1,626 |
| `manager/health-manager`   |      8 |  1,178 |
| `network/scripts/switch-controller` | 2 | 963 |
| `tappaas-cicd/lib/ts`      |      6 |    494 |
| **Total**                  | **89** |**22,633** |

There are no TypeScript sources outside `foundation/` — apps contain none.
No `node_modules/`, `dist/`, or other build output exists in the tree, so
nothing is being filtered out of these counts.

## Apps (`src/apps/`)

Covers 13 installed app modules.

| File Type           | Files  | Lines  |
|---------------------|-------:|-------:|
| Bash (.sh)          |     80 |  8,131 |
| NixOS (.nix)        |      9 |  4,114 |
| Documentation (.md) |     55 |  3,481 |
| TypeScript (.ts)    |      0 |      0 |
| Python (.py)        |      0 |      0 |
| **Total**           |**144** |**15,726** |

### By app

| App              | Files  | Lines  |
|------------------|-------:|-------:|
| `nextcloud`      |     15 |  2,635 |
| `litellm`        |     17 |  2,455 |
| `openwebui`      |     12 |  1,911 |
| `deconz`         |     17 |  1,451 |
| `vllm-amd`       |     15 |  1,407 |
| `coturn`         |     15 |  1,291 |
| `nextcloud-hpb`  |     12 |  1,155 |
| `euro-office`    |     10 |  1,148 |
| `hass`           |     10 |  1,095 |
| `vaultwarden`    |      7 |    513 |
| `windows-server` |      6 |    361 |
| `netbird-client` |      5 |    186 |
| `n8n`            |      2 |     77 |
| (apps README)    |      1 |     41 |
| **Total**        |**144** |**15,726** |

## Grand Total

| Area                  | Files  |   Lines   |
|-----------------------|-------:|----------:|
| Foundation            |    575 |   114,138 |
| Apps                  |    144 |    15,726 |
| `src/` top level      |      4 |       603 |
| **Total**             |**723** |**130,467**|

`src/` top level: `README.md`, `module-dependencies.md`,
`generate-module-dependencies.sh`, `module-catalog.json`.

## Cross-cutting views

### Test vs production code (.sh + .ts + .py)

| Category         | Files  | Lines  |
|------------------|-------:|-------:|
| Production       |    380 | 73,697 |
| Test             |    145 | 30,282 |
| **Total**        |**525** |**103,979** |

Test code is ~29% of executable source. Per language:

| Language | Production        | Test              | Test share |
|----------|------------------:|------------------:|-----------:|
| Bash     | 276 f / 40,668 l  | 104 f / 19,208 l  |        32% |
| TypeScript | 65 f / 16,135 l |  24 f /  6,498 l  |        29% |
| Python   |  39 f / 16,894 l  |  17 f /  4,576 l  |        21% |

Classified by path/name convention (`test/`, `tests/`, `test-*`, `test_*.py`,
`test*.sh`, `*.test.ts`, `*.spec.ts`).

### Data & config files (not in totals above)

| File Type   | Foundation              | Apps                 |
|-------------|------------------------:|---------------------:|
| JSON        | 122 files / 4,753 lines | 17 files / 607 lines |
| XML         |   3 files /   468 lines | 0                    |
| `.template` |   1 file  / 1,020 lines | 0                    |
| YAML/YML    |   1 file  /    20 lines |  2 files / 118 lines |
| TOML        |   4 files /    88 lines | 0                    |
| CSV         |   2 files /   614 lines | 0                    |
| TXT         |   1 file  /     2 lines | 0                    |
| LICENSE     |   0                     |  9 files /  76 lines |

`.template` is `foundation/network/firewall-config.xml.template`; the TOML files
are the four Python `pyproject.toml` manifests.

### Excluded from all counts

| Path                     | Files | Lines |
|--------------------------|------:|------:|
| `foundation/Deprecated/` |     3 |   888 |
| `apps/00-Template/`      |    10 |   646 |
| `__pycache__/` (.pyc)    |    37 |     — |

## Change since 2026-04-02

| Area       | Files (was → now) | Lines (was → now)     |
|------------|------------------:|----------------------:|
| Foundation |     105 → 575     |    22,714 → 114,138   |
| Apps       |      47 → 144     |     6,847 → 15,726    |
| **Total**  |   **152 → 723**   | **29,561 → 130,467**  |

Foundation growth is dominated by `tappaas-cicd` (363 files / 81,942 lines),
roughly 72% of foundation source. The two largest components are the
TypeScript manager layer (36,920 lines across 8 managers) and the
controller layer (29,352 lines of bash and Python — `opnsense-controller`,
`identity-controller`, `node-provisioner`, `update-tappaas`, plus the
switch/AP/proxmox/backup controllers).

> **Note on the previous revision of this file:** it counted only `.sh`, `.py`,
> `.nix`, and `.md`, and therefore omitted all 89 TypeScript files (22,633
> lines), the 6 extensionless bash controller entrypoints (1,864 lines), and the
> PHP patch (260 lines) — understating the total by 24,757 lines. Every figure
> it did report has been re-verified and was correct for the types it covered.
