#!/usr/bin/env bash
# TAPPaaS Module: ollama-nvidia — Test
#
# Verifies the Ollama NVIDIA module is functioning correctly.
#
# Usage: ./test.sh ollama-nvidia

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMNAME="${1:-ollama-nvidia}"
CONFIG_FILE="${SCRIPT_DIR}/${VMNAME}.json"
VMID="${TAPPAAS_VMID_OVERRIDE:-$(jq -r '.vmid' "$CONFIG_FILE")}"

_PRIMARY="tappaas1.mgmt.internal"
LXC_NODE="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${_PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
[[ -n "${LXC_NODE:-}" ]] || { echo "ERROR: cannot resolve the node hosting LXC ${VMID}"; exit 1; }
pct() { ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${LXC_NODE}.mgmt.internal" pct "$@"; }

PASS=0
FAIL=0
WARN=0

check() {
    local desc="$1"
    local result="$2"
    if [[ "$result" == "0" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

warn() {
    local desc="$1"
    echo "  WARN: $desc"
    WARN=$((WARN + 1))
}

echo ""
echo "=== Testing Ollama NVIDIA Module (VMID: ${VMID}) ==="
echo ""

# Every probed command uses the `RC=0; cmd || RC=$?` capture pattern: a bare
# `cmd; check "$?"` under set -e aborts the whole script on the first failing
# probe, so FAIL counts would never be reported.

# Test 1: Container running
echo "--- LXC Container ---"
RC=0; pct status "${VMID}" 2>/dev/null | grep -q "running" || RC=$?
check "LXC container is running" "$RC"

# Test 2: exec access
RC=0; pct exec "${VMID}" -- echo "ok" > /dev/null 2>&1 || RC=$?
check "Can exec into container" "$RC"

# Test 3: GPU device access
echo ""
echo "--- GPU Access ---"
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm; do
    RC=0; pct exec "${VMID}" -- ls "$dev" > /dev/null 2>&1 || RC=$?
    check "$dev device node present in LXC" "$RC"
done

_node() { ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${LXC_NODE}.mgmt.internal" "$@"; }
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm; do
    HEX_MAJ=$(_node stat -c '%t' "$dev" 2>/dev/null || echo "0")
    HEX_MIN=$(_node stat -c '%T' "$dev" 2>/dev/null || echo "0")
    CGROUP_RC=0
    _node grep -qF "cgroup2.devices.allow: c $((16#${HEX_MAJ})):$((16#${HEX_MIN})) rwm" "/etc/pve/lxc/${VMID}.conf" \
        > /dev/null 2>&1 || CGROUP_RC=$?
    check "$dev cgroup allow matches live major:minor ($((16#${HEX_MAJ})):$((16#${HEX_MIN})))" "$CGROUP_RC"
done

# Test 4: Docker running
echo ""
echo "--- Docker ---"
RC=0; pct exec "${VMID}" -- docker ps > /dev/null 2>&1 || RC=$?
check "Docker daemon running" "$RC"

# Test 5: Ollama container
echo ""
echo "--- Ollama Service ---"
OLLAMA_RUNNING=$(pct exec "${VMID}" -- docker ps --filter name=ollama --format "{{.Status}}" 2>/dev/null || echo "")
if [[ "$OLLAMA_RUNNING" == *"Up"* ]]; then
    check "Ollama container running" "0"

    # Test 5b: GPU compute accessible in container
    NVSMI_RC=0
    pct exec "${VMID}" -- docker exec ollama nvidia-smi > /dev/null 2>&1 || NVSMI_RC=$?
    if [[ "$NVSMI_RC" -eq 0 ]]; then
        check "GPU compute accessible in container (nvidia-smi)" "0"
    else
        check "GPU compute accessible in container (nvidia-smi)" "1"
        echo "  (Check nvidia-container-toolkit config and re-run update.sh ollama-nvidia)"
    fi
else
    check "Ollama container running" "1"
    echo "  (Start with: pct exec ${VMID} -- bash -c 'cd /opt/ollama && docker compose up -d')"
fi

# Test 6: Ollama API responding
echo ""
echo "--- API Health ---"
api() { pct exec "${VMID}" -- curl -s --connect-timeout 5 "$@" 2>/dev/null; }
HTTP_CODE=$(pct exec "${VMID}" -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:11434/api/tags" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    check "Ollama API responding (127.0.0.1:11434)" "0"

    echo ""
    echo "  Pulled models:"
    api "http://127.0.0.1:11434/api/tags" | jq -r '.models[].name' 2>/dev/null | while read -r model; do
        echo "    - $model"
    done

    # Test 7: Inference test (only if at least one model is pulled)
    echo ""
    echo "--- Inference Test ---"
    MODEL=$(api "http://127.0.0.1:11434/api/tags" | jq -r '.models[0].name' 2>/dev/null || echo "")
    if [[ -n "$MODEL" && "$MODEL" != "null" ]]; then
        RESPONSE=$(pct exec "${VMID}" -- curl -s --connect-timeout 30 --max-time 60 \
            -X POST "http://127.0.0.1:11434/v1/chat/completions" \
            -H "Content-Type:application/json" \
            -d "'{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly 3 words.\"}],\"max_tokens\":20}'" \
            2>/dev/null || true)
        if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
            check "Inference working (model: ${MODEL})" "0"
            ANSWER=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
            echo "  Response: ${ANSWER}"
        else
            check "Inference working" "1"
        fi
    else
        warn "No model pulled yet — skip inference test (run ./pull-model.sh smoke)"
    fi
else
    check "Ollama API responding (HTTP ${HTTP_CODE})" "1"
    if [[ "$OLLAMA_RUNNING" == *"Up"* ]]; then
        echo "  (Container running but API not ready — check logs: pct exec ${VMID} -- docker logs -f ollama)"
    fi
fi

# Summary
echo ""
echo "=== Test Summary ==="
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  WARN: ${WARN}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: FAIL (${FAIL} tests failed)"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi
