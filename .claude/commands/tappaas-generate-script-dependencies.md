Regenerate the dependency documentation for src/foundation/:

1. **Analyze all files** in src/foundation/ including:
   - Shell scripts (.sh)
   - Python files (.py)
   - configuration.json and zones.json
   - PHP files (.php)
   - pyproject.toml files

2. **list executable programs/scripts, identify where the installed programs exists**:
   - Most programs will be installed in /home/tappaas/bin under tappaas-cicd
   - exception is Create-TAPPAaS-VM.sh installed in the root account of every TAPPaaS node
   - create a file that lists all the executable: PRPGRAMS.csv
   - for each program list what are the source files for the program (for scripts it is the script itself, but identify location of the source)

2. **For each program/script, identify direct dependencies**:
   - Shell scripts: `source`, `.` commands, script calls
   - Programs based on Python files: list other TAPPaaS programs/scripts it calls
   - also list if the program/script is dependent on configuration.json or zones.json

3. **Create DEPENDENCIES.csv** with columns:
   - File name
   - Location (relative path)
   - Direct dependencies (semicolon-separated list)
   - Group files by directory with comment headers

4. **Create DEPENDENCIES.md** with:
   - Summary table of directories and file counts
   - Key dependency chains (5 main flows)
   - Most connected files table
   - Top-level entry points (programs nothing depends on)
   - mermaid dependency graph for each top level entry

5. **Mermaid syntax notes**:
   - Escape `@` symbols using `#64;` and wrap in quotes: `["user#64;host"]`
   - Use quotes for labels with special characters
   - Keep node IDs simple (single letters or short names)

Output all three files to src/foundation/.
