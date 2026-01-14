#!/usr/bin/env python3
"""TAPPaaS update scheduler - determines which nodes to update and calls update-node."""

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

CONFIG_PATH = Path("/home/tappaas/config/configuration.json")
UPDATE_NODE_CMD = "/home/tappaas/bin/update-node"


def load_config() -> dict:
    """Load the TAPPaaS configuration file."""
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"Error loading configuration: {e}")
        return {}


def get_nodes_from_config(config: dict) -> list[str]:
    """Get list of node hostnames from configuration."""
    nodes = config.get("tappaas-nodes", [])
    return [node.get("hostname") for node in nodes if node.get("hostname")]


def get_node_number(node: str) -> int | None:
    """Extract the node number from the node name (e.g., tappaas1 -> 1)."""
    match = re.search(r"(\d+)$", node)
    if match:
        return int(match.group(1))
    return None


def should_update_node(node: str, branch: str) -> bool:
    """Determine if a node should be updated based on node number and branch.

    Rules:
    - If branch is "main" or "stable": update first week of month only
      - Even numbered nodes: Tuesday
      - Odd numbered nodes: Thursday
    - Otherwise (development branches): update daily
    """
    today = datetime.now()
    day_of_month = today.day
    weekday = today.weekday()  # 0=Monday, 1=Tuesday, ..., 6=Sunday

    # For non-stable branches, always run
    if branch not in ("main", "stable"):
        print(f"  {node}: Branch '{branch}' is not main/stable, scheduled for update")
        return True

    # For main/stable: only first week (days 1-7)
    if day_of_month > 7:
        print(f"  {node}: Day {day_of_month} is not in first week, skipping")
        return False

    node_number = get_node_number(node)
    if node_number is None:
        print(f"  {node}: Could not determine node number, scheduled for update")
        return True

    is_even = node_number % 2 == 0

    # Even nodes: Tuesday (weekday 1)
    # Odd nodes: Thursday (weekday 3)
    if is_even:
        if weekday == 1:  # Tuesday
            print(f"  {node}: Even node scheduled for Tuesday, running update")
            return True
        else:
            print(f"  {node}: Even node scheduled for Tuesday, today is not Tuesday, skipping")
            return False
    else:
        if weekday == 3:  # Thursday
            print(f"  {node}: Odd node scheduled for Thursday, running update")
            return True
        else:
            print(f"  {node}: Odd node scheduled for Thursday, today is not Thursday, skipping")
            return False


def update_node(node: str) -> bool:
    """Call update-node to perform the actual update."""
    try:
        result = subprocess.run(
            [UPDATE_NODE_CMD, node],
            text=True
        )
        return result.returncode == 0
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        print(f"Error running update-node for {node}: {e}")
        return False


def main():
    """Main entry point for update-tappaas."""
    parser = argparse.ArgumentParser(
        description="TAPPaaS update scheduler - determines which nodes to update"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force update of all nodes regardless of schedule"
    )
    parser.add_argument(
        "--node",
        help="Update only this specific node (still respects schedule unless --force is used)"
    )
    args = parser.parse_args()

    start_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"update-tappaas started: {start_time}")

    # Load configuration
    config = load_config()
    if not config:
        print("Error: Could not load configuration")
        sys.exit(1)

    branch = config.get("tappaas", {}).get("branch", "main")
    print(f"Branch: {branch}")

    # Get nodes to process
    if args.node:
        nodes = [args.node]
    else:
        nodes = get_nodes_from_config(config)

    if not nodes:
        print("Error: No nodes found in configuration")
        sys.exit(1)

    print(f"Nodes to check: {', '.join(nodes)}")
    print("")

    # Determine which nodes to update
    print("Checking update schedule:")
    nodes_to_update = []
    for node in nodes:
        if args.force or should_update_node(node, branch):
            nodes_to_update.append(node)

    print("")

    if not nodes_to_update:
        print("No nodes scheduled for update today")
        sys.exit(0)

    print(f"Nodes to update: {', '.join(nodes_to_update)}")
    print("")

    # Update each scheduled node
    failed_nodes = []
    for node in nodes_to_update:
        print(f"--- Updating {node} ---")
        if not update_node(node):
            print(f"Failed to update {node}")
            failed_nodes.append(node)
        print("")

    end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"update-tappaas completed: {end_time}")

    if failed_nodes:
        print(f"Failed nodes: {', '.join(failed_nodes)}")
        sys.exit(1)

    print("All scheduled updates completed successfully")


if __name__ == "__main__":
    main()
