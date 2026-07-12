#!/usr/bin/env bash
# TAPPaaS Module: vllm-amd — Test
#
# Verifies vLLM AMD iGPU module is functioning correctly
#
# Usage: ./test.sh vllm-amd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMNAME="${1:-vllm-amd}"
CONFIG_FILE="${SCRIPT_DIR}/${VMNAME}.json"
# vmid may be overridden to test a non-default instance (issue #196).
VMID="${TAPPAAS_VMID_OVERRIDE:-$(jq -r '.vmid' "$CONFIG_FILE")}"

# `pct` only exists on PVE nodes, but this test is invoked on tappaas-cicd.
# Resolve the node hosting the LXC and route every `pct` call there over ssh.
_PRIMARY="tappaas1.mgmt.internal"
LXC_NODE="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${_PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
[[ -n "${LXC_NODE:-}" ]] || { echo "ERROR: cannot resolve the node hosting LXC ${VMID}"; exit 1; }
# -n: do not read the script's stdin (otherwise ssh consumes it and derails the
# remaining test, and breaks any `... | while read` loops below).
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
echo "=== Testing vLLM AMD Module (VMID: ${VMID}) ==="
echo ""

# Test 1: Container running
echo "--- LXC Container ---"
pct status "${VMID}" | grep -q "running"
check "LXC container is running" "$?"

# Test 2: SSH / exec access
pct exec "${VMID}" -- echo "ok" > /dev/null 2>&1
check "Can exec into container" "$?"

# Test 3: GPU device access
# Part A: device node presence via ls (verifies the bind-mount exists inside the LXC).
# Part B: cgroup allow-list check — run directly on the Proxmox host, not via pct exec.
#   ls passes even when the cgroup deny blocks open(); this check catches the
#   "stale major after reboot" failure mode (VLLM-004/005) by comparing the LIVE
#   device major against what is actually in the LXC conf.
echo ""
echo "--- GPU Access ---"

pct exec "${VMID}" -- ls /dev/kfd > /dev/null 2>&1
check "/dev/kfd device node present in LXC" "$?"

pct exec "${VMID}" -- ls /dev/dri/renderD128 > /dev/null 2>&1
check "/dev/dri/renderD128 device node present in LXC" "$?"

_node() { ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${LXC_NODE}.mgmt.internal" "$@"; }

KFD_HEX=$(_node stat -c '%t' /dev/kfd 2>/dev/null || echo "0")
KFD_CGROUP_RC=0
_node grep -qF "cgroup2.devices.allow: c $((16#${KFD_HEX})):0 rwm" "/etc/pve/lxc/${VMID}.conf" \
    > /dev/null 2>&1 || KFD_CGROUP_RC=$?
check "/dev/kfd cgroup allow matches live major ($((16#${KFD_HEX})):0)" "$KFD_CGROUP_RC"

REN_MAJ=$(_node stat -c '%t' /dev/dri/renderD128 2>/dev/null || echo "0")
REN_MIN=$(_node stat -c '%T' /dev/dri/renderD128 2>/dev/null || echo "0")
REN_CGROUP_RC=0
_node grep -qF "cgroup2.devices.allow: c $((16#${REN_MAJ})):$((16#${REN_MIN})) rwm" "/etc/pve/lxc/${VMID}.conf" \
    > /dev/null 2>&1 || REN_CGROUP_RC=$?
check "/dev/dri/renderD128 cgroup allow matches live major:minor ($((16#${REN_MAJ})):$((16#${REN_MIN})))" "$REN_CGROUP_RC"

# Test 4: Docker running
echo ""
echo "--- Docker ---"
pct exec "${VMID}" -- docker ps > /dev/null 2>&1
check "Docker daemon running" "$?"

# Test 5: vLLM container
echo ""
echo "--- vLLM Service ---"
VLLM_RUNNING=$(pct exec "${VMID}" -- docker ps --filter name=vllm --format "{{.Status}}" 2>/dev/null || echo "")
if [[ "$VLLM_RUNNING" == *"Up"* ]]; then
    check "vLLM container running" "0"

    # Test 5b: GPU HIP compute — check via rocm-smi (no shell quoting issues through
    # SSH→pct chain; python3 -c with semicolons breaks because the remote shell splits on ';').
    # rocm-smi queries /dev/kfd directly; exit non-zero if cgroup or device unavailable.
    ROCM_RC=0
    pct exec "${VMID}" -- docker exec vllm rocm-smi > /dev/null 2>&1 || ROCM_RC=$?
    if [[ "$ROCM_RC" -eq 0 ]]; then
        check "GPU HIP compute accessible in container (rocm-smi)" "0"
    elif pct exec "${VMID}" -- docker exec vllm which rocm-smi > /dev/null 2>&1; then
        check "GPU HIP compute accessible in container (rocm-smi)" "1"
        echo "  (Run patch-host-gpu.sh vllm-amd on tappaas2 and restart the container)"
    else
        warn "rocm-smi not in container PATH — GPU compute validated by inference test below"
    fi
else
    check "vLLM container running" "1"
    echo "  (Start with: pct exec ${VMID} -- bash -c 'cd /opt/vllm && docker compose up -d')"
fi

# Test 6: vLLM API responding
echo ""
echo "--- API Health ---"
# Query the vLLM API from INSIDE the container (127.0.0.1) via pct exec, so the
# test does not depend on cicd→LXC network reachability.
api() { pct exec "${VMID}" -- curl -s --connect-timeout 5 "$@" 2>/dev/null; }
HTTP_CODE=$(pct exec "${VMID}" -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:8000/v1/models" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    check "vLLM API responding (127.0.0.1:8000)" "0"

    # Show loaded models
    echo ""
    echo "  Loaded models:"
    api "http://127.0.0.1:8000/v1/models" | jq -r '.data[].id' 2>/dev/null | while read -r model; do
        echo "    - $model"
    done

    # Test 7: Inference test
    echo ""
    echo "--- Inference Test ---"
    MODEL=$(api "http://127.0.0.1:8000/v1/models" | jq -r '.data[0].id' 2>/dev/null || echo "")
    if [[ -n "$MODEL" ]]; then
        # The pct() wrapper forwards args over ssh: the remote shell re-parses the
        # joined command, so an unquoted JSON body gets brace-expanded (commas in
        # {...}) and emptied → curl posts nothing (HTTP 400 "JSON decode error").
        # Wrap the payload in LITERAL single quotes so the remote shell passes it
        # through verbatim. `|| true` keeps a transient inference failure from
        # aborting the script (set -e) before the summary prints.
        RESPONSE=$(pct exec "${VMID}" -- curl -s --connect-timeout 30 --max-time 60 \
            -X POST "http://127.0.0.1:8000/v1/chat/completions" \
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
        warn "No model loaded — skip inference test"
    fi
else
    check "vLLM API responding (HTTP ${HTTP_CODE})" "1"
    if [[ "$VLLM_RUNNING" == *"Up"* ]]; then
        echo "  (Container running but API not ready — model may still be loading)"
        echo "  (Check logs: pct exec ${VMID} -- docker logs -f vllm)"
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
