#!/usr/bin/env bash
# TAPPaaS Test - CI/CD and Foundation System Validation
# This script performs a series of tests to validate the TAPPaaS CI/CD pipeline and the overall foundation system setup. It includes checks for VM creation, NixOS configuration, and HA functionality.
# Usage: ./test.sh  

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "Starting TAPPaaS CI/CD and Foundation System Tests..."

# Test 1: Create VMs and verify installation
echo -e "\nTest 1: Creating Debian and NixOS VMs..."
cd test-vm-creation
./test.sh
cd ..

