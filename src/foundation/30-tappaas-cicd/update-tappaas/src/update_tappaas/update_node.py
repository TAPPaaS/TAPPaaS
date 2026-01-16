#!/usr/bin/env python3
"""TAPPaaS update-node - performs the actual update of a single node and its modules."""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

CONFIG_DIR = Path("/home/tappaas/config")
TAPPAAS_DIR = Path("/home/tappaas/TAPPaaS")
FOUNDATION_DIR = TAPPAAS_DIR / "src" / "foundation"
MODULES_DIR = TAPPAAS_DIR / "src" / "modules"

# Files to ignore when scanning for module JSONs
IGNORED_JSONS = {"configuration.json", "zones.json"}


def get_node_fqdn(node: str) -> str:
    """Get the fully qualified domain name for a node."""
    return f"{node}.mgmt.internal"


def check_ssh_access(node: str) -> bool:
    """Check if SSH access to the node is available."""
    fqdn = get_node_fqdn(node)
    try:
        result = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", f"root@{fqdn}", "echo", "ok"],
            capture_output=True,
            text=True,
            timeout=10
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        return False


def run_apt_update(node: str) -> bool:
    """Run apt update on the remote node."""
    fqdn = get_node_fqdn(node)
    try:
        result = subprocess.run(
            ["ssh", f"root@{fqdn}", "apt", "update"],
            text=True,
            timeout=300
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, subprocess.SubprocessError) as e:
        print(f"Error running apt update: {e}")
        return False


def run_apt_upgrade(node: str) -> bool:
    """Run apt upgrade --assume-yes on the remote node."""
    fqdn = get_node_fqdn(node)
    try:
        result = subprocess.run(
            ["ssh", f"root@{fqdn}", "apt", "upgrade", "--assume-yes"],
            text=True,
            timeout=600
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, subprocess.SubprocessError) as e:
        print(f"Error running apt upgrade: {e}")
        return False


def find_module_dir(module_name: str) -> Path | None:
    """Find the directory containing the module's update.sh.

    Searches in foundation directories (numbered prefixes) and modules directory.
    """
    # Search in foundation directories (e.g., 10-firewall, 30-tappaas-cicd)
    for dir_path in FOUNDATION_DIR.iterdir():
        if dir_path.is_dir():
            # Check if directory name ends with the module name
            dir_name = dir_path.name
            # Handle numbered prefixes like "10-firewall" -> "firewall"
            if "-" in dir_name:
                suffix = dir_name.split("-", 1)[1]
                if suffix == module_name:
                    return dir_path
            elif dir_name == module_name:
                return dir_path

    # Search in modules directory
    if MODULES_DIR.exists():
        module_path = MODULES_DIR / module_name
        if module_path.is_dir():
            return module_path

    return None


def run_module_update(module_name: str) -> bool:
    """Run update.sh for a module."""
    module_dir = find_module_dir(module_name)

    if module_dir is None:
        print(f"  Warning: Could not find directory for module '{module_name}'")
        return False

    update_script = module_dir / "update.sh"

    if not update_script.exists():
        print(f"  Warning: No update.sh found for module '{module_name}' in {module_dir}")
        return False

    print(f"  Running update.sh for {module_name}...")
    try:
        result = subprocess.run(
            ["bash", str(update_script)],
            cwd=str(module_dir),
            text=True,
            timeout=1800  # 30 minutes timeout for module updates
        )
        if result.returncode == 0:
            print(f"  {module_name} update completed successfully")
            return True
        else:
            print(f"  {module_name} update failed with exit code {result.returncode}")
            return False
    except subprocess.TimeoutExpired:
        print(f"  Error: {module_name} update timed out")
        return False
    except subprocess.SubprocessError as e:
        print(f"  Error running {module_name} update: {e}")
        return False


def get_modules_for_node(node: str) -> list[str]:
    """Get list of modules installed on the specified node.

    Reads all JSON files in CONFIG_DIR (except ignored ones) and returns
    module names where the 'node' field matches the specified node.
    Default node is 'tappaas1' if not specified in the JSON.
    """
    modules = []

    if not CONFIG_DIR.exists():
        print(f"Warning: Config directory {CONFIG_DIR} does not exist")
        return modules

    for json_file in CONFIG_DIR.glob("*.json"):
        if json_file.name in IGNORED_JSONS:
            continue

        try:
            with open(json_file) as f:
                config = json.load(f)

            # Get node from config, default to tappaas1
            module_node = config.get("node", "tappaas1")
            module_name = json_file.stem  # filename without .json extension

            if module_node == node:
                modules.append(module_name)

        except (json.JSONDecodeError, IOError) as e:
            print(f"Warning: Could not read {json_file}: {e}")
            continue

    return modules


def main():
    """Main entry point for update-node."""
    parser = argparse.ArgumentParser(description="Update a single TAPPaaS node and its modules")
    parser.add_argument(
        "node",
        help="Name of the TAPPaaS node to update (e.g., tappaas1)"
    )
    parser.add_argument(
        "--skip-modules",
        action="store_true",
        help="Skip module updates, only update the node itself"
    )
    args = parser.parse_args()

    node = args.node
    start_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"starting update {node}: {start_time}")

    # Check SSH access
    print(f"Checking SSH access to {node}...")
    if not check_ssh_access(node):
        print(f"Error: Cannot connect to {node} via SSH")
        sys.exit(1)
    print(f"SSH access to {node} confirmed")

    # Run apt update
    print(f"Running apt update on {node}...")
    if not run_apt_update(node):
        print(f"Error: apt update failed on {node}")
        sys.exit(1)

    # Run apt upgrade
    print(f"Running apt upgrade on {node}...")
    if not run_apt_upgrade(node):
        print(f"Error: apt upgrade failed on {node}")
        sys.exit(1)

    print(f"Node {node} system update complete")

    if args.skip_modules:
        end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"update {node} complete (modules skipped): {end_time}")
        return

    # Update modules
    print("")
    print("=" * 50)
    print("Updating modules...")
    print("=" * 50)

    failed_modules = []

    # 1. Update tappaas-cicd module first
    print("\n[1/3] Updating tappaas-cicd module...")
    if not run_module_update("tappaas-cicd"):
        failed_modules.append("tappaas-cicd")

    # 2. Update firewall module
    print("\n[2/3] Updating firewall module...")
    if not run_module_update("firewall"):
        failed_modules.append("firewall")

    # 3. Update other modules installed on this node
    print(f"\n[3/3] Updating other modules on {node}...")
    node_modules = get_modules_for_node(node)

    # Filter out tappaas-cicd and firewall as they're already updated
    node_modules = [m for m in node_modules if m not in ("tappaas-cicd", "firewall")]

    if node_modules:
        print(f"Found {len(node_modules)} module(s) on {node}: {', '.join(node_modules)}")
        for module in node_modules:
            print(f"\nUpdating module: {module}")
            if not run_module_update(module):
                failed_modules.append(module)
    else:
        print(f"No additional modules found on {node}")

    # Summary
    print("")
    print("=" * 50)
    end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"update {node} complete: {end_time}")

    if failed_modules:
        print(f"Warning: The following modules failed to update: {', '.join(failed_modules)}")
        sys.exit(1)
    else:
        print("All modules updated successfully")


if __name__ == "__main__":
    main()
