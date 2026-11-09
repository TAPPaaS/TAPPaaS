# TAPPaaS Source Statistics

Generated: 2026-11-09 by `src/generate-statistics.py` — **2.4** (`1d3b8ed1`, 2026-11-09) against the last release **2026-08-23** (`ddab5fc1`, 2026-08-23). The Δ column is what changed between them.

The snapshot of 2026-04-02 is kept in [STATISTICS-v1.md](STATISTICS-v1.md).

Counts are physical lines over `src/`, from git, by the same rules on both sides. Counted: `.sh` (and extensionless files with a bash shebang), `.ts`/`.tsx`, `.py`, `.nix`, `.md`, `.php`. Data and config files are reported apart and are **not** in the totals. Excluded: `foundation/Deprecated/`, any `00-Template/`, `__pycache__/`, `node_modules/`, the console's built `web/dist/`, these `STATISTICS*.md` files, lock files. Stack modules are `src/<stack>/<module>/`; before the stacks they were `src/apps/<module>/`, so a module is compared by its name.

## Summary

| Area | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| Foundation (`src/foundation/`) | 575 | 1486 | 114,138 | 328,206 | +214,068 |
| Stack modules | 144 | 230 | 15,726 | 26,403 | +10,677 |
| `src/` top level | 3 | 4 | 310 | 568 | +258 |
| **Total** | **722** | **1720** | **130,174** | **355,177** | **+225,003** |

## By file type

| File type | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| Bash (.sh) | 380 | 792 | 59,876 | 135,012 | +75,136 |
| TypeScript (.ts/.tsx) | 89 | 511 | 22,633 | 126,148 | +103,515 |
| Python (.py) | 56 | 119 | 21,470 | 44,919 | +23,449 |
| Documentation (.md) | 150 | 235 | 18,182 | 36,954 | +18,772 |
| NixOS (.nix) | 46 | 61 | 7,753 | 11,837 | +4,084 |
| PHP (.php) | 1 | 2 | 260 | 307 | +47 |
| **Total** | **722** | **1720** | **130,174** | **355,177** | **+225,003** |

### Foundation

| File type | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| Bash (.sh) | 299 | 671 | 51,530 | 122,204 | +70,674 |
| TypeScript (.ts/.tsx) | 89 | 511 | 22,633 | 126,148 | +103,515 |
| Python (.py) | 56 | 119 | 21,470 | 44,919 | +23,449 |
| Documentation (.md) | 93 | 140 | 14,606 | 29,633 | +15,027 |
| NixOS (.nix) | 37 | 43 | 3,639 | 4,995 | +1,356 |
| PHP (.php) | 1 | 2 | 260 | 307 | +47 |
| **Total** | **575** | **1486** | **114,138** | **328,206** | **+214,068** |

### Stack modules

| File type | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| Bash (.sh) | 80 | 120 | 8,131 | 12,586 | +4,455 |
| Documentation (.md) | 55 | 92 | 3,481 | 6,975 | +3,494 |
| NixOS (.nix) | 9 | 18 | 4,114 | 6,842 | +2,728 |
| **Total** | **144** | **230** | **15,726** | **26,403** | **+10,677** |

## Foundation by subsystem

| Subsystem | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| `tappaas-cicd` | 363 | 1106 | 81,942 | 263,136 | +181,194 |
| `cluster` | 40 | 86 | 9,190 | 20,947 | +11,757 |
| `network` | 56 | 72 | 9,810 | 12,920 | +3,110 |
| `backup` | 35 | 74 | 3,754 | 12,600 | +8,846 |
| `identity` | 20 | 28 | 2,483 | 3,883 | +1,400 |
| `satellite` | 20 | 23 | 1,362 | 2,946 | +1,584 |
| `logging` | 9 | 17 | 1,301 | 2,806 | +1,505 |
| `templates` | 24 | 29 | 2,304 | 2,762 | +458 |
| (top-level docs & installers) | 7 | 7 | 1,917 | 2,263 | +346 |
| `storage` | 0 | 18 | 0 | 2,166 | +2,166 |
| `pvehost` | 0 | 10 | 0 | 640 | +640 |
| `console` | 0 | 6 | 0 | 452 | +452 |
| `debianhost` | 0 | 8 | 0 | 444 | +444 |
| `schemas` | 1 | 2 | 75 | 241 | +166 |
| **Total** | **575** | **1486** | **114,138** | **328,206** | **+214,068** |

### Inside `tappaas-cicd`

| Layer | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| `manager` | 166 | 385 | 36,920 | 102,662 | +65,742 |
| `controller` | 116 | 165 | 29,352 | 52,081 | +22,729 |
| `ui` | 0 | 228 | 0 | 44,269 | +44,269 |
| `scripts` | 20 | 178 | 4,689 | 29,876 | +25,187 |
| `lib` | 19 | 76 | 3,810 | 18,350 | +14,540 |
| (top-level) | 13 | 17 | 2,803 | 5,812 | +3,009 |
| `migrations` | 0 | 28 | 0 | 3,396 | +3,396 |
| `update-tappaas` | 7 | 7 | 1,062 | 3,212 | +2,150 |
| `test-vm-creation` | 15 | 15 | 2,195 | 2,216 | +21 |
| `test-variants` | 6 | 6 | 763 | 914 | +151 |
| `test-repository` | 1 | 1 | 348 | 348 | — |
| **Total** | **363** | **1106** | **81,942** | **263,136** | **+181,194** |

## TypeScript by component

| Component | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| `tappaas-cicd/ui` | 0 | 217 | 0 | 42,652 | +42,652 |
| `tappaas-cicd/manager/health-manager` | 8 | 68 | 1,178 | 14,330 | +13,152 |
| `tappaas-cicd/manager/module-manager` | 13 | 36 | 4,301 | 12,303 | +8,002 |
| `tappaas-cicd/manager/network-manager` | 15 | 26 | 5,684 | 11,739 | +6,055 |
| `tappaas-cicd/manager/site-manager` | 9 | 41 | 2,136 | 9,459 | +7,323 |
| `tappaas-cicd/lib/ts` | 6 | 32 | 494 | 7,534 | +7,040 |
| `tappaas-cicd/manager/backup-manager` | 10 | 17 | 1,626 | 5,754 | +4,128 |
| `tappaas-cicd/manager/environment-manager` | 12 | 14 | 2,968 | 5,015 | +2,047 |
| `tappaas-cicd/manager/identity-manager` | 0 | 22 | 0 | 4,509 | +4,509 |
| `tappaas-cicd/manager/asset-manager` | 0 | 12 | 0 | 4,360 | +4,360 |
| `tappaas-cicd/controller/cmdb-controller` | 0 | 9 | 0 | 3,832 | +3,832 |
| `tappaas-cicd/manager/storage-manager` | 0 | 8 | 0 | 2,203 | +2,203 |
| `tappaas-cicd/manager/ca-manager` | 0 | 7 | 0 | 1,467 | +1,467 |
| `network/scripts/switch-controller/src` | 2 | 2 | 963 | 991 | +28 |
| `tappaas-cicd/manager/people-manager` | 14 | 0 | 3,283 | 0 | −3,283 |
| **Total** | **89** | **511** | **22,633** | **126,148** | **+103,515** |

## Stack modules by module

| Module | Stack | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---|---:|---:|---:|---:|---:|
| `litellm` | ai | 17 | 21 | 2,455 | 3,759 | +1,304 |
| `nextcloud` | collaboration | 15 | 21 | 2,635 | 3,478 | +843 |
| `openwebui` | ai | 12 | 12 | 1,911 | 2,477 | +566 |
| `vllm-amd` | ai | 15 | 18 | 1,407 | 1,952 | +545 |
| `coturn` | collaboration | 15 | 17 | 1,291 | 1,636 | +345 |
| `forgejo` | devops | 0 | 17 | 0 | 1,484 | +1,484 |
| `deconz` | home | 17 | 19 | 1,451 | 1,471 | +20 |
| `jellyfin` | home | 0 | 7 | 0 | 1,370 | +1,370 |
| `nextcloud-hpb` | collaboration | 12 | 10 | 1,155 | 1,299 | +144 |
| `euro-office` | collaboration | 10 | 11 | 1,148 | 1,234 | +86 |
| `immich` | home | 0 | 6 | 0 | 1,201 | +1,201 |
| `hass` | home | 10 | 10 | 1,095 | 1,116 | +21 |
| `vaultwarden` | security | 7 | 8 | 513 | 669 | +156 |
| `lazysite` | web-hosting | 0 | 6 | 0 | 614 | +614 |
| `nomad` | home | 0 | 6 | 0 | 598 | +598 |
| `karakeep` | home | 0 | 6 | 0 | 515 | +515 |
| `woodpecker` | devops | 0 | 6 | 0 | 497 | +497 |
| `windows-server` | misc | 6 | 6 | 361 | 346 | −15 |
| `netbird-client` | security | 5 | 6 | 186 | 195 | +9 |
| `n8n` | ai | 2 | 2 | 77 | 77 | — |
| (stack READMEs) | | 1 | 15 | 41 | 415 | +374 |
| **Total** | | **144** | **230** | **15,726** | **26,403** | **+10,677** |

20 modules in 2.4, 13 in 2026-08-23.

## Test vs production code (.sh, .ts/.tsx, .py)

| Language | Production 2026-08-23 | Production 2.4 | Test 2026-08-23 | Test 2.4 | Test share 2026-08-23 | Test share 2.4 |
|---|---:|---:|---:|---:|---:|---:|
| Bash (.sh) | 40,668 | 82,105 | 19,208 | 52,907 | 32% | 39% |
| TypeScript (.ts/.tsx) | 16,135 | 93,639 | 6,498 | 32,509 | 29% | 26% |
| Python (.py) | 16,894 | 32,229 | 4,576 | 12,690 | 21% | 28% |
| **Total** | **73,697** | **207,973** | **30,282** | **98,106** | **29%** | **32%** |

Test code by path and name: `test/`, `tests/`, `test-*`, `test_*.py`, `test*.sh`, `*.test.ts(x)`, `*.spec.ts(x)`.

## Data and config files (not in the totals)

| Type | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| .template (foundation) | 1 | 1 | 1,020 | 899 | −121 |
| CSV (foundation) | 2 | 2 | 614 | 655 | +41 |
| JSON, VEX statements (foundation) | 0 | 6 | 0 | 4,851 | +4,851 |
| JSON, VEX statements (stacks) | 0 | 12 | 0 | 12,340 | +12,340 |
| JSON, config and data (foundation) | 57 | 128 | 3,663 | 10,987 | +7,324 |
| JSON, config and data (stacks) | 18 | 32 | 900 | 1,755 | +855 |
| JSON, test fixtures (foundation) | 65 | 495 | 1,090 | 357,843 | +356,753 |
| LICENSE (stacks) | 9 | 9 | 76 | 76 | — |
| TOML (foundation) | 4 | 4 | 88 | 94 | +6 |
| TXT (foundation) | 1 | 13 | 2 | 3,948 | +3,946 |
| XML (foundation) | 3 | 3 | 468 | 468 | — |
| YAML/YML (foundation) | 1 | 2 | 20 | 37 | +17 |
| YAML/YML (stacks) | 2 | 2 | 118 | 118 | — |

## Excluded from every count

| Path | Files 2026-08-23 | Files 2.4 | Lines 2026-08-23 | Lines 2.4 | Δ lines |
|---|---:|---:|---:|---:|---:|
| `STATISTICS*.md`, lock files | 4 | 5 | 210 | 2,512 | +2,302 |
| `web/dist/` (built console) | 0 | 4 | 0 | 108 | +108 |
| `apps/00-Template/` | 12 | 0 | 676 | 0 | −676 |
| `foundation/Deprecated/` | 3 | 0 | 888 | 0 | −888 |
| `misc/00-Template/` | 0 | 20 | 0 | 1,380 | +1,380 |
