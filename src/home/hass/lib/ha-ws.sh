#!/usr/bin/env bash
#
# TAPPaaS hass — run a single authenticated HA WebSocket API command
#
# HA 2025+ exposes core operations (e.g. config/core/update) only over the WS API.
# This is a small, dependency-free raw-socket WS client: it authenticates with the
# given token, sends ONE command (id auto-added), prints its result JSON to stdout,
# and exits 0 on success / 1 on failure.
#
# Usage:  HA_TOKEN=<llat> ha-ws.sh <ha_ip> '<json command without id>'
# Example: HA_TOKEN=$LLAT ha-ws.sh 10.2.20.5 '{"type":"config/core/update","external_url":"https://x"}'
#
# NB: shares the WS framing with ha-llat.sh — candidate to unify into one helper.

set -euo pipefail

HA_IP="${1:?usage: ha-ws.sh <ha_ip> '<json-command>'}"
WS_CMD="${2:?json command required}"
: "${HA_TOKEN:?HA_TOKEN env required}"
HA_PORT="${HA_PORT:-8123}"

HA_IP="${HA_IP}" HA_PORT="${HA_PORT}" HA_TOKEN="${HA_TOKEN}" WS_CMD="${WS_CMD}" python3 - <<'PY'
import socket, os, base64, struct, json, sys
HOST=os.environ["HA_IP"]; PORT=int(os.environ["HA_PORT"]); TOKEN=os.environ["HA_TOKEN"]
def die(m): sys.stderr.write("ha-ws: "+m+"\n"); sys.exit(1)
try:
    cmd=json.loads(os.environ["WS_CMD"])
except Exception:
    die("invalid command JSON")
try:
    s=socket.create_connection((HOST,PORT),timeout=15)
except OSError as e:
    die(f"cannot connect to {HOST}:{PORT}: {e}")
key=base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /api/websocket HTTP/1.1\r\nHost:{HOST}:{PORT}\r\nUpgrade:websocket\r\n"
           f"Connection:Upgrade\r\nSec-WebSocket-Key:{key}\r\nSec-WebSocket-Version:13\r\n\r\n").encode())
buf=b""
while b"\r\n\r\n" not in buf:
    c=s.recv(4096)
    if not c: die("WS handshake closed early")
    buf+=c
rest=buf.split(b"\r\n\r\n",1)[1]
def send(o):
    d=json.dumps(o).encode(); h=bytearray([0x81]); n=len(d); m=os.urandom(4)
    if n<126: h.append(0x80|n)
    elif n<65536: h.append(0x80|126); h+=struct.pack(">H",n)
    else: h.append(0x80|127); h+=struct.pack(">Q",n)
    h+=m; s.sendall(bytes(h)+bytes(b^m[i%4] for i,b in enumerate(d)))
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
recv()  # auth_required
send({"type":"auth","access_token":TOKEN})
if recv().get("type")!="auth_ok": die("WS auth failed (token rejected)")
cmd=dict(cmd); cmd["id"]=1; send(cmd)
while True:
    r=recv()
    if r.get("id")==1 and r.get("type")=="result":
        print(json.dumps(r.get("result")))
        sys.exit(0 if r.get("success") else 1)
PY
