Regenerate the dependency documentation for src/foundation/:

1. **Analyze all files** in src/foundation/ including:
   - Shell scripts (.sh)
   - Python files (.py)
   - Nix files (.nix)
   - JSON configuration files (.json)
   - PHP files (.php)
   - pyproject.toml files

2. **For each file, identify direct dependencies**:
   - Shell scripts: `source`, `.` commands, script calls, referenced binaries
   - Python files: imports, subprocess calls, file path references
   - Nix files: imports, fetchFromGitHub, package dependencies
   - JSON files: note which scripts/code reference them

3. **Create DEPENDENCIES.csv** with columns:
   - File name
   - Location (relative path)
   - Direct dependencies (semicolon-separated list)
   - Group files by directory with comment headers

4. **Create DEPENDENCIES.md** with:
   - Summary table of directories and file counts
   - Key dependency chains (5 main flows)
   - Most connected files table
   - Top-level entry points (files nothing depends on)
   - Mermaid dependency graphs for each major entry point:
     - Bootstrap flow (05-ProxmoxNode/install.sh)
     - CICD installation flow (30-tappaas-cicd/install1.sh)
     - Update scheduler flow (update-tappaas)
     - OPNsense controller build (opnsense-controller/default.nix)
     - VM creation flow (Create-TAPPaaS-VM.sh)
     - Generic module install pattern
     - Firewall update flow (10-firewall/update.sh)
     - Caddy setup flow (setup-caddy.sh)
   - File reference tables (Root configs, Shell scripts, Python modules, Nix files)
   - External dependencies table (system tools, Python libraries, remote hosts)

5. **Mermaid syntax notes**:
   - Escape `@` symbols using `#64;` and wrap in quotes: `["user#64;host"]`
   - Use quotes for labels with special characters
   - Keep node IDs simple (single letters or short names)

Output both files to src/foundation/.
