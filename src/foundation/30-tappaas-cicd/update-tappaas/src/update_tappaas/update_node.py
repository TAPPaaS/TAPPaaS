#!/usr/bin/env python3
"""TAPPaaS update-node - performs the actual update of a single node."""

import argparse
import subprocess
import sys
from datetime import datetime


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


def main():
    """Main entry point for update-node."""
    parser = argparse.ArgumentParser(description="Update a single TAPPaaS node")
    parser.add_argument(
        "node",
        help="Name of the TAPPaaS node to update (e.g., tappaas1)"
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

    end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"update {node} complete: {end_time}")


if __name__ == "__main__":
    main()
