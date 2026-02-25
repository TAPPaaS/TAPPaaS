Generate code and documentation statistics for `src/` and write/update `src/STATISTICS.md`.

## Steps

### 1. Count lines in `src/foundation/`

Run the following shell commands to count non-blank lines by file type under `src/foundation/` (excluding `src/foundation/Attic/`):

```bash
# Bash (.sh)
find src/foundation/ -path "*/Attic/*" -prune -o -name "*.sh" -print | xargs wc -l 2>/dev/null | tail -1

# Python (.py)
find src/foundation/ -path "*/Attic/*" -prune -o -name "*.py" -print | xargs wc -l 2>/dev/null | tail -1

# NixOS (.nix)
find src/foundation/ -path "*/Attic/*" -prune -o -name "*.nix" -print | xargs wc -l 2>/dev/null | tail -1

# Documentation (.md)
find src/foundation/ -path "*/Attic/*" -prune -o -name "*.md" -print | xargs wc -l 2>/dev/null | tail -1

# Also count number of files (not lines) for each type
find src/foundation/ -path "*/Attic/*" -prune -o -name "*.sh" -print | grep -c "\.sh$"
find src/foundation/ -path "*/Attic/*" -prune -o -name "*.py" -print | grep -c "\.py$"
find src/foundation/ -path "*/Attic/*" -prune -o -name "*.nix" -print | grep -c "\.nix$"
find src/foundation/ -path "*/Attic/*" -prune -o -name "*.md" -print | grep -c "\.md$"
```

### 2. Count lines in `src/apps/`

Run the same commands under `src/apps/` (excluding `src/apps/00-Template/`):

```bash
find src/apps/ -path "*/00-Template/*" -prune -o -name "*.sh" -print | xargs wc -l 2>/dev/null | tail -1
find src/apps/ -path "*/00-Template/*" -prune -o -name "*.py" -print | xargs wc -l 2>/dev/null | tail -1
find src/apps/ -path "*/00-Template/*" -prune -o -name "*.nix" -print | xargs wc -l 2>/dev/null | tail -1
find src/apps/ -path "*/00-Template/*" -prune -o -name "*.md" -print | xargs wc -l 2>/dev/null | tail -1

find src/apps/ -path "*/00-Template/*" -prune -o -name "*.sh" -print | grep -c "\.sh$"
find src/apps/ -path "*/00-Template/*" -prune -o -name "*.py" -print | grep -c "\.py$"
find src/apps/ -path "*/00-Template/*" -prune -o -name "*.nix" -print | grep -c "\.nix$"
find src/apps/ -path "*/00-Template/*" -prune -o -name "*.md" -print | grep -c "\.md$"
```

### 3. Count installed apps

Count the number of non-template app modules in `src/apps/` (directories, excluding `00-Template` and `README.md`):

```bash
find src/apps/ -mindepth 1 -maxdepth 1 -type d ! -name "00-Template" | wc -l
```

### 4. Count foundation modules and scripts

```bash
# Foundation subdirectories (modules)
find src/foundation/ -mindepth 1 -maxdepth 1 -type d | wc -l

# Total scripts installed to /home/tappaas/bin (from PROGRAMS.csv as reference)
grep -c "^[^#]" src/foundation/PROGRAMS.csv
```

### 5. Compute totals

For each area, sum the line counts across all types to get a total lines figure.
Grand total = foundation total + apps total.

### 6. Write `src/STATISTICS.md`

Read `src/STATISTICS.md` first (if it exists), then write the complete updated file.

The file must contain:

```markdown
# TAPPaaS Source Statistics

Generated: <today's date>

## Foundation (`src/foundation/`)

> Excludes `Attic/` (archived code).

| File Type       | Files | Lines |
|-----------------|------:|------:|
| Bash (.sh)      |     N |     N |
| Python (.py)    |     N |     N |
| NixOS (.nix)    |     N |     N |
| Documentation (.md) | N |     N |
| **Total**       | **N** | **N** |

## Apps (`src/apps/`)

> Excludes `00-Template/` (template scaffolding). Covers N installed app modules.

| File Type       | Files | Lines |
|-----------------|------:|------:|
| Bash (.sh)      |     N |     N |
| Python (.py)    |     N |     N |
| NixOS (.nix)    |     N |     N |
| Documentation (.md) | N |     N |
| **Total**       | **N** | **N** |

## Grand Total

| Area            | Files | Lines |
|-----------------|------:|------:|
| Foundation      |     N |     N |
| Apps            |     N |     N |
| **Total**       | **N** | **N** |
```

Replace all `N` placeholders with the actual counts gathered in steps 1–5.

### 7. Report

Tell the user:
- The path to the written file
- The grand total line count
- How many app modules are covered
