#!/usr/bin/env python3
"""TAPPaaS update scheduler - determines which nodes to update and calls update-node."""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

CONFIG_PATH = Path("/home/tappaas/config/configuration.json")
UPDATE_NODE_CMD = "/home/tappaas/bin/update-node"

WEEKDAYS = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}


def load_config() -> dict:
    """Load the TAPPaaS configuration file."""
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"Error loading configuration: {e}")
        return {}


def get_nodes_from_config(config: dict) -> list[dict]:
    """Get list of node configurations from configuration."""
    return config.get("tappaas-nodes", [])


def parse_schedule(schedule: list) -> tuple[str, int | None, int]:
    """Parse updateSchedule list into (frequency, weekday, hour).

    Args:
        schedule: List of [frequency, weekday, hour]

    Returns:
        Tuple of (frequency, weekday_number, hour)
        weekday_number is None for daily frequency
    """
    if not schedule or len(schedule) < 3:
        # Default: daily at 2am
        return ("daily", None, 2)

    frequency = schedule[0].lower()
    weekday_str = schedule[1].lower() if schedule[1] else None
    hour = int(schedule[2]) if schedule[2] is not None else 2

    weekday = WEEKDAYS.get(weekday_str) if weekday_str else None

    return (frequency, weekday, hour)


def should_update_node(node_config: dict, current_hour: int) -> bool:
    """Determine if a node should be updated based on its updateSchedule.

    Args:
        node_config: Node configuration dict containing hostname and updateSchedule
        current_hour: Current hour of the day (0-23)

    Returns:
        True if the node should be updated now, False otherwise
    """
    hostname = node_config.get("hostname", "unknown")
    schedule = node_config.get("updateSchedule", [])

    frequency, scheduled_weekday, scheduled_hour = parse_schedule(schedule)

    today = datetime.now()
    current_weekday = today.weekday()  # 0=Monday, 1=Tuesday, ..., 6=Sunday
    day_of_month = today.day

    # Check hour first - must match for all frequencies
    if current_hour != scheduled_hour:
        print(f"  {hostname}: Scheduled for hour {scheduled_hour}, current hour is {current_hour}, skipping")
        return False

    if frequency == "daily":
        print(f"  {hostname}: Daily schedule at hour {scheduled_hour}, running update")
        return True

    elif frequency == "weekly":
        if scheduled_weekday is None:
            print(f"  {hostname}: Weekly schedule but no weekday specified, skipping")
            return False

        weekday_name = list(WEEKDAYS.keys())[scheduled_weekday].capitalize()
        if current_weekday == scheduled_weekday:
            print(f"  {hostname}: Weekly schedule on {weekday_name}, running update")
            return True
        else:
            current_day_name = list(WEEKDAYS.keys())[current_weekday].capitalize()
            print(f"  {hostname}: Weekly schedule on {weekday_name}, today is {current_day_name}, skipping")
            return False

    elif frequency == "monthly":
        # Monthly: first week of month (days 1-7) on specified weekday
        if scheduled_weekday is None:
            print(f"  {hostname}: Monthly schedule but no weekday specified, skipping")
            return False

        weekday_name = list(WEEKDAYS.keys())[scheduled_weekday].capitalize()

        if day_of_month > 7:
            print(f"  {hostname}: Monthly schedule, day {day_of_month} is not in first week, skipping")
            return False

        if current_weekday == scheduled_weekday:
            print(f"  {hostname}: Monthly schedule on first {weekday_name}, running update")
            return True
        else:
            current_day_name = list(WEEKDAYS.keys())[current_weekday].capitalize()
            print(f"  {hostname}: Monthly schedule on {weekday_name}, today is {current_day_name}, skipping")
            return False

    else:
        print(f"  {hostname}: Unknown frequency '{frequency}', skipping")
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

    now = datetime.now()
    current_hour = now.hour
    start_time = now.strftime("%Y-%m-%d %H:%M:%S")
    print(f"update-tappaas started: {start_time}")

    # Load configuration
    config = load_config()
    if not config:
        print("Error: Could not load configuration")
        sys.exit(1)

    # Get nodes to process
    all_nodes = get_nodes_from_config(config)

    if args.node:
        # Filter to specific node
        nodes = [n for n in all_nodes if n.get("hostname") == args.node]
        if not nodes:
            print(f"Error: Node '{args.node}' not found in configuration")
            sys.exit(1)
    else:
        nodes = all_nodes

    if not nodes:
        print("Error: No nodes found in configuration")
        sys.exit(1)

    node_names = [n.get("hostname", "unknown") for n in nodes]
    print(f"Nodes to check: {', '.join(node_names)}")
    print("")

    # Determine which nodes to update
    print("Checking update schedule:")
    nodes_to_update = []
    for node_config in nodes:
        hostname = node_config.get("hostname")
        if not hostname:
            continue
        if args.force or should_update_node(node_config, current_hour):
            nodes_to_update.append(hostname)

    print("")

    if not nodes_to_update:
        print("No nodes scheduled for update at this time")
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
