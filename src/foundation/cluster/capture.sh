#!/usr/bin/env bash
#
# capture.sh — Take a screenshot of any Proxmox VM via QMP screendump.
#
# Usage: capture.sh <vmid> [node]
#   vmid  VM ID to screenshot  (required)
#   node  Proxmox node hostname without domain (default: tappaas1)
#
# Output: prints path to a PNG saved in /tmp/
#
# Example:
#   capture.sh 8081
#   capture.sh 500 tappaas2
#
set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $(basename "$0") <vmid> [node]" >&2
    exit 1
fi

VMID="$1"
NODE="${2:-tappaas1}"

TS=$(date +%H%M%S)
PPM="/tmp/cap-${TS}.ppm"
PNG="/tmp/cap-${VMID}-${TS}.png"

ssh "root@${NODE}.mgmt.internal" \
    "printf '%s' '{\"execute\":\"qmp_capabilities\"}{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"${PPM}\"}}' \
     | socat - UNIX-CONNECT:/var/run/qemu-server/${VMID}.qmp" 2>/dev/null

scp -q "root@${NODE}.mgmt.internal:${PPM}" /tmp/cap-local.ppm 2>/dev/null
ssh "root@${NODE}.mgmt.internal" "rm -f ${PPM}" 2>/dev/null

python3 - /tmp/cap-local.ppm "${PNG}" <<'EOF'
import struct, zlib, sys
with open(sys.argv[1], 'rb') as f:
    f.readline(); w, h = map(int, f.readline().split()); f.readline(); d = f.read()
def chunk(n, b):
    c = n + b; return struct.pack('>I', len(b)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
raw = b''.join(b'\x00' + d[y*w*3:(y+1)*w*3] for y in range(h))
with open(sys.argv[2], 'wb') as f:
    f.write(b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw))
        + chunk(b'IEND', b''))
EOF

rm -f /tmp/cap-local.ppm
echo "${PNG}"
