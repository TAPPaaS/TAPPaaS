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
VMID=$(jq -r '.vmid' "$CONFIG_FILE")

PASS=0
FAIL=0
WARN=0

check() {
    local desc="$1"
    local result="$2"
    if [[ "$result" == "0" ]]; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

warn() {
    local desc="$1"
    echo "  WARN: $desc"
    ((WARN++))
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
echo ""
echo "--- GPU Access ---"
pct exec "${VMID}" -- ls /dev/kfd > /dev/null 2>&1
check "/dev/kfd accessible" "$?"

pct exec "${VMID}" -- ls /dev/dri/renderD128 > /dev/null 2>&1
check "/dev/dri/renderD128 accessible" "$?"

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
else
    check "vLLM container running" "1"
    echo "  (Start with: pct exec ${VMID} -- bash -c 'cd /opt/vllm && docker compose up -d')"
fi

# Test 6: vLLM API responding
echo ""
echo "--- API Health ---"
CONTAINER_IP=$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}')

if [[ -n "$CONTAINER_IP" ]]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${CONTAINER_IP}:8000/v1/models" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        check "vLLM API responding (http://${CONTAINER_IP}:8000)" "0"

        # Show loaded models
        echo ""
        echo "  Loaded models:"
        curl -s "http://${CONTAINER_IP}:8000/v1/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null | while read -r model; do
            echo "    - $model"
        done

        # Test 7: Inference test
        echo ""
        echo "--- Inference Test ---"
        MODEL=$(curl -s "http://${CONTAINER_IP}:8000/v1/models" 2>/dev/null | jq -r '.data[0].id' 2>/dev/null || echo "")
        if [[ -n "$MODEL" ]]; then
            RESPONSE=$(curl -s --connect-timeout 30 --max-time 60 \
                -X POST "http://${CONTAINER_IP}:8000/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly 3 words.\"}],\"max_tokens\":20}" \
                2>/dev/null)
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
else
    check "Container has IP address" "1"
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
