# Backup install.sh Parameter Passing Fix

## Problem

Lines 44-46 in `src/foundation/35-backup/install.sh` were sourcing scripts incorrectly:

```bash
pushd $TEMP_DIR >/dev/null

# Source common routines (expects $1 to be module name)
. /home/tappaas/bin/copy-update-json.sh
. /home/tappaas/bin/common-install-routines.sh
check_json /home/tappaas/config/$1.json || exit 1
```

**Root Cause**: 
- `copy-update-json.sh` has `main "$@"` at the end, which executes immediately when sourced
- `main` expects `./${module}.json` to exist in the current directory
- But the script had already changed to `$TEMP_DIR`, so the JSON file wasn't found
- Parameters WERE being passed correctly, but the working directory was wrong

## Solution

Call `copy-update-json.sh` as a standalone script BEFORE changing directories:

```bash
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

# Get the directory where this script resides (the module directory)
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy and update JSON config from module directory
cd "$MODULE_DIR"
/home/tappaas/bin/copy-update-json.sh "$@"

# Source common routines (just function definitions, no execution)
. /home/tappaas/bin/common-install-routines.sh

# Validate the JSON config
check_json /home/tappaas/config/$1.json || exit 1

# Now change to temp directory for the rest of the installation
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null
```

## Key Changes

1. **Determine module directory**: `MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
2. **Change to module directory**: `cd "$MODULE_DIR"` 
3. **Call (not source) copy-update-json.sh**: `/home/tappaas/bin/copy-update-json.sh "$@"`
4. **Source common-install-routines**: `. /home/tappaas/bin/common-install-routines.sh` (no execution, just function definitions)
5. **Then change to temp directory**: After JSON is copied and validated

## Why This Matters

**Sourcing vs Calling**:
- **Sourcing** (`. script.sh`): Runs in current shell, can access parent variables
- **Calling** (`./script.sh "$@"`): Runs in subshell, needs explicit parameter passing

`copy-update-json.sh` is designed to be **called**, not sourced, because:
- It has `main "$@"` that executes immediately
- It expects to run from the module directory
- It modifies files and exits on errors

`common-install-routines.sh` is designed to be **sourced** because:
- It only defines functions
- No code executes when sourced
- Functions need to be available in parent shell

## Files Modified

- `/home/tappaas/TAPPaaS/src/foundation/35-backup/install.sh` (lines 36-46)

## Testing

To test:
```bash
cd /home/tappaas/TAPPaaS/src/foundation/35-backup
./install.sh backup
```

Should now:
1. ✅ Find backup.json in the module directory
2. ✅ Copy it to /home/tappaas/config/backup.json
3. ✅ Set the location field correctly
4. ✅ Validate the JSON
5. ✅ Proceed with installation

---

**Status**: ✅ Fixed
**Date**: 2026-02-16
