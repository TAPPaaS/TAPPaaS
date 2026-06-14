#!/usr/bin/env bash
#
# TAPPaaS hass — mint a durable HA Long-Lived Access Token via the WebSocket API
#
# HA 2025+ removed the REST LLAT endpoint; LLATs are minted over the WS API. This
# helper auths with an existing (short-lived) access_token, then:
#   1. revokes any prior LLAT named <client_name> (idempotent — no token sprawl),
#   2. mints a fresh durable LLAT (survives HA Core restarts),
#   3. prints ONLY the token to stdout (caller captures it).
#
# Dependency-free: a raw-socket WebSocket client (no python ws library), mirroring
# the proven migration helper. Runs on cicd, connects to the HA VM's :8123.
#
# Usage:  HA_ACCESS_TOKEN=<access_token> ha-llat.sh <ha_ip> [client_name] [lifespan_days]
# Output: the minted LLAT on stdout (stderr for diagnostics); exit 1 on failure.

set -euo pipefail

HA_IP="${1:?usage: ha-llat.sh <ha_ip> [client_name] [lifespan_days]}"
CLIENT_NAME="${2:-tappaas-cicd}"
LIFESPAN="${3:-3650}"
: "${HA_ACCESS_TOKEN:?HA_ACCESS_TOKEN env required}"
HA_PORT="${HA_PORT:-8123}"

HA_IP="${HA_IP}" HA_PORT="${HA_PORT}" CLIENT_NAME="${CLIENT_NAME}" LIFESPAN="${LIFESPAN}" \
HA_ACCESS_TOKEN="${HA_ACCESS_TOKEN}" python3 - <<'PY'
import socket, os, base64, struct, json, sys
HOST=os.environ["HA_IP"]; PORT=int(os.environ["HA_PORT"]); TOKEN=os.environ["HA_ACCESS_TOKEN"]
CLIENT=os.environ["CLIENT_NAME"]; LIFE=int(os.environ["LIFESPAN"])

def die(m): sys.stderr.write("ha-llat: "+m+"\n"); sys.exit(1)

try:
    s=socket.create_connection((HOST,PORT),timeout=15)
except OSError as e:
    die(f"cannot connect to {HOST}:{PORT}: {e}")
key=base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /api/websocket HTTP/1.1\r\nHost:{HOST}:{PORT}\r\nUpgrade:websocket\r\n"
           f"Connection:Upgrade\r\nSec-WebSocket-Key:{key}\r\nSec-WebSocket-Version:13\r\n\r\n").encode())
buf=b""
while b"\r\n\r\n" not in buf:
    chunk=s.recv(4096)
    if not chunk: die("WS handshake closed early")
    buf+=chunk
rest=buf.split(b"\r\n\r\n",1)[1]

def send(obj):
    data=json.dumps(obj).encode(); hdr=bytearray([0x81]); n=len(data); mask=os.urandom(4)
    if n<126: hdr.append(0x80|n)
    elif n<65536: hdr.append(0x80|126); hdr+=struct.pack(">H",n)
    else: hdr.append(0x80|127); hdr+=struct.pack(">Q",n)
    hdr+=mask; s.sendall(bytes(hdr)+bytes(b^mask[i%4] for i,b in enumerate(data)))

def recv():
    global rest
    def need(n):
        global rest
        while len(rest)<n:
            c=s.recv(8192)
            if not c: die("WS closed mid-frame")
            rest+=c
    need(2); ln=rest[1]&0x7f; idx=2
    if ln==126: need(4); ln=struct.unpack(">H",rest[2:4])[0]; idx=4
    elif ln==127: need(10); ln=struct.unpack(">Q",rest[2:10])[0]; idx=10
    need(idx+ln); p=rest[idx:idx+ln]; rest=rest[idx+ln:]
    return json.loads(p)

_id=1
def cmd(obj):
    global _id
    obj=dict(obj); obj["id"]=_id; send(obj)
    while True:
        r=recv()
        if r.get("id")==_id and r.get("type")=="result":
            _id+=1; return r

recv()  # auth_required
send({"type":"auth","access_token":TOKEN})
if recv().get("type")!="auth_ok": die("WS auth failed (access_token rejected)")

# 1. revoke prior LLATs with this client_name (idempotent)
r=cmd({"type":"auth/refresh_tokens"})
if r.get("success"):
    for t in r.get("result",[]):
        if t.get("client_name")==CLIENT and t.get("type")=="long_lived_access_token":
            cmd({"type":"auth/delete_refresh_token","refresh_token_id":t.get("id")})

# 2. mint a fresh durable LLAT
r=cmd({"type":"auth/long_lived_access_token","client_name":CLIENT,"lifespan":LIFE})
if not r.get("success"): die("LLAT mint failed: "+json.dumps(r.get("error",{})))
tok=r.get("result")
if not isinstance(tok,str) or not tok: die("LLAT mint returned no token")
print(tok)
s.close()
PY
