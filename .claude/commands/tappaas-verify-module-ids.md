Verify that `src/modules.json` is consistent with the actual module JSON files on disk.

## Verification Steps

### 1. Load the registry

Read `src/modules.json` and parse all four module lists:
- `foundationModules`
- `applicationModules`
- `proxmoxTemplates`
- `testModules`

### 2. Scan the codebase for actual module JSON files

Search for all module definition JSON files on disk:
- `src/foundation/*//*.json` — foundation and test-vm-creation modules
- `src/apps/*/*.json` — application modules

A file is a **module JSON** if it contains a `"vmid"` field. Exclude schema/reference files (`module-fields.json`, `configuration-fields.json`, `zones-fields.json`, `zones.json`).

### 3. Cross-reference and check for discrepancies

For **each entry in modules.json**, verify:
1. **File exists**: The path in `moduleJson` points to an existing file
2. **VMID matches**: The `vmid` in the registry matches the `vmid` in the actual JSON file
3. **Module name matches**: The `moduleName` matches the `vmname` (or `hostname` for firewall) in the actual JSON file
4. **Correct category**: The module is listed in the right section based on VMID range:
   - `foundationModules`: VMID 100–200
   - `applicationModules`: VMID 201–499
   - `proxmoxTemplates`: VMID 8000–9000
   - `testModules`: VMID 900–999

For **each module JSON found on disk**, verify:
1. **Registered**: The module appears in `modules.json`
2. **No duplicates**: No VMID is used by more than one module across all categories

### 4. Check VMID convention compliance

For each module, verify:
- VMID falls within one of the defined ranges (100–200, 201–499, 900–999, 8000–9000)
- Foundation and application VMIDs are allocated on multiples of 10 (the base allocation unit), except where a module intentionally shares a block (e.g., openwebui 311 shares the 310 block with litellm)

### 5. Report results

Present findings in a clear summary:

```
## Module Registry Verification Report

### Summary
- Modules in registry: X
- Modules on disk: Y
- Discrepancies found: Z

### Results by Category

#### Foundation Modules
| Module | VMID | File Exists | VMID Match | Name Match | Range OK |
|--------|------|-------------|------------|------------|----------|
| ...    | ...  | ...         | ...        | ...        | ...      |

#### Application Modules
(same table format)

#### Proxmox Templates
(same table format)

#### Test Modules
(same table format)

### Missing from Registry
(List any module JSON files on disk not found in modules.json)

### Missing from Disk
(List any registry entries whose moduleJson file does not exist)

### VMID Conflicts
(List any duplicate VMIDs across all categories)

### VMID Range Violations
(List any modules whose VMID does not match its category range)
```

If all checks pass, report: **"All module IDs verified — registry is consistent with disk."**

If discrepancies are found, list each one with a recommended fix (e.g., "Add module X to applicationModules" or "Update VMID from 199 to 200").
