# TAPPaaS Source Statistics

Generated: 2026-08-23 — branch `feat/adr-014-zone-lifecycle`, commit `ed712af`

Previous snapshot (2026-04-02) is kept in [STATISTICS-v1.md](STATISTICS-v1.md).

Counts are physical lines (`wc -l`) over `src/`. Excluded throughout:
`foundation/Deprecated/` (archived code, formerly `Attic/`) and
`apps/00-Template/` (template scaffolding).

## Foundation (`src/foundation/`)

| File Type           | Files  | Lines  |
|---------------------|-------:|-------:|
| Bash (.sh)          |    293 | 49,666 |
| Python (.py)        |     56 | 21,470 |
| NixOS (.nix)        |     37 |  3,639 |
| Documentation (.md) |     93 | 14,606 |
| **Total**           |**479** |**89,381** |

### By subsystem

| Subsystem        | Files  | Lines  |
|------------------|-------:|-------:|
| `tappaas-cicd`   |    269 | 58,148 |
| `cluster`        |     40 |  9,190 |
| `network`        |     54 |  8,847 |
| `backup`         |     35 |  3,754 |
| `identity`       |     20 |  2,483 |
| `templates`      |     24 |  2,304 |
| `satellite`      |     20 |  1,362 |
| `logging`        |      9 |  1,301 |
| `schemas`        |      1 |     75 |
| (top-level docs & installers) | 7 | 1,917 |
| **Total**        |**479** |**89,381** |

## Apps (`src/apps/`)

Covers 13 installed app modules.

| File Type           | Files  | Lines  |
|---------------------|-------:|-------:|
| Bash (.sh)          |     80 |  8,131 |
| Python (.py)        |      0 |      0 |
| NixOS (.nix)        |      9 |  4,114 |
| Documentation (.md) |     55 |  3,481 |
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
| Foundation            |    479 |    89,381 |
| Apps                  |    144 |    15,726 |
| `src/` top level      |      4 |       603 |
| **Total**             |**627** |**105,710**|

`src/` top level: `README.md`, `module-dependencies.md`,
`generate-module-dependencies.sh`, `module-catalog.json`. The `STATISTICS*.md`
files are excluded to keep the count from being self-referential.

## Cross-cutting views

### Test vs production code (.sh + .py only)

| Category         | Files  | Lines  |
|------------------|-------:|-------:|
| Production       |    293 | 55,149 |
| Test             |    136 | 24,118 |
| **Total**        |**429** |**79,267** |

Test code is ~30% of executable source. Classified by path/name convention
(`test/`, `tests/`, `test-*`, `test_*.py`, `test*.sh`).

### Data & config files (not in totals above)

| File Type | Foundation | Apps  |
|-----------|-----------:|------:|
| JSON      | 122 files / 4,753 lines | 17 files / 607 lines |
| YAML/YML  |   1 file /    20 lines |  2 files /  118 lines |
| CSV       |   2 files /   614 lines |  0 |

### Excluded from all counts

| Path                     | Files | Lines |
|--------------------------|------:|------:|
| `foundation/Deprecated/` |     3 |   888 |
| `apps/00-Template/`      |    10 |   646 |

## Change since 2026-04-02

| Area       | Files (was → now) | Lines (was → now)     |
|------------|------------------:|----------------------:|
| Foundation |     105 → 479     |    22,714 → 89,381    |
| Apps       |      47 → 144     |     6,847 → 15,726    |
| **Total**  |   **152 → 627**   | **29,561 → 105,710**  |

Foundation growth is dominated by `tappaas-cicd` (269 files / 58,148 lines),
which now accounts for roughly 65% of foundation source — the Python
controllers (`opnsense-controller`, `identity-controller`, `update-tappaas`)
plus the manager and test-harness layers built out since April.
