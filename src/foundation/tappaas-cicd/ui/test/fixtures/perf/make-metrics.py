#!/usr/bin/env python3
"""make-metrics.py — writes metrics.json, the synthetic metrics store of fixture
mode (src/perffixture.ts): a description per series, not samples. A site at
basic, nextcloud at service, identity under a trace investigation (so its route
has the service numbers), the test environment off (deconz-test: nothing), and
tankc1 on tappaas3 slow since about 46 hours before the capture.

    python3 test/fixtures/perf/make-metrics.py   # from ui/
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.dirname(HERE)
objects = json.load(open(os.path.join(FIX, "cmdb", "objects.json")))
modules = {m["name"]: m for m in json.load(open(os.path.join(FIX, "modules.json")))["modules"]}
live = [o for o in objects if not o.get("ended")]
by_name = lambda cls, name: next(o for o in live if o["class"] == cls and o["name"] == name)

series = []
def s(signal, labels, base, daily=0, noise=0, steps=None, mx=None):
    d = {"signal": signal, "labels": labels, "base": base, "daily": daily, "noise": noise}
    if steps: d["steps"] = steps
    if mx is not None: d["max"] = mx
    series.append(d)

machines = {"tappaas1": (34, 71), "tappaas2": (22, 58), "tappaas3": (41, 83)}
for name, (cpu, mem) in machines.items():
    m = by_name("machine", name)
    ci = {"tappaas_ci_id": m["id"]}
    s("node.cpu", ci, cpu, 12, 4, mx=100)
    s("node.memory", ci, mem, 3, 1, mx=100)
    s("node.mem_pressure", ci, 1.5 if name != "tappaas3" else 4, 1, 0.8, mx=100)
    s("node.io_pressure", ci, 3 if name != "tappaas3" else 9, 2, 1.5,
      steps=[{"hoursAgo": 46, "add": 14}] if name == "tappaas3" else None, mx=100)

seen = 0
for o in live:
    if o["class"] not in ("vm", "lxc") or o["name"] not in modules: continue
    if modules[o["name"]]["environment"] == "test": continue  # its environment is off
    seen += 1
    ci = {"tappaas_ci_id": o["id"]}
    k = (seen * 7) % 11
    on3 = o["name"] in ("karakeep", "nomad", "unifi-os", "vaultwarden")
    s("vm.cpu", ci, 6 + k * 3, 4 + k, 2, mx=100)
    if o["name"] == "litellm":  # its working set close to its limit since its last update
        s("vm.memory", ci, 86, 3, 1.5, steps=[{"hoursAgo": 20, "add": 6}], mx=100)
    else:
        s("vm.memory", ci, 48 + k * 3.5, 2, 1, mx=100)
    s("vm.mem_pressure", ci, 0.4 + k * 0.2, 0.3, 0.3, mx=100)
    s("vm.io_pressure", ci, 1 + k * 0.4, 0.8, 0.6, steps=[{"hoursAgo": 46, "add": 22 if o["name"] in ("karakeep", "nomad") else 6}] if on3 else None, mx=100)
    s("vm.disk_write", ci, 0.6 + k * 0.5, 0.4, 0.3)

for node in ("tappaas1", "tappaas2", "tappaas3"):
    host = by_name("machine", node)["id"]
    s("pool.write_wait", {"pool": "tanka1", "tappaas_ci_id": host}, 3.5, 1.5, 1)
    s("pool.read_wait", {"pool": "tanka1", "tappaas_ci_id": host}, 1.8, 0.6, 0.5)
host3 = by_name("machine", "tappaas3")["id"]
s("pool.write_wait", {"pool": "tankc1", "tappaas_ci_id": host3}, 9, 6, 3, steps=[{"hoursAgo": 46, "add": 29}])
s("pool.read_wait", {"pool": "tankc1", "tappaas_ci_id": host3}, 4, 2, 1.5, steps=[{"hoursAgo": 46, "add": 7}])

for route, p95, err, rate in (("cloud.hrossen.dk", 640, 0.4, 3.2), ("identity.hrossen.dk", 210, 1.6, 7.5)):
    ci = {"tappaas_ci_id": by_name("proxy-route", route)["id"]}
    s("svc.p95", ci, p95, p95 * 0.35, p95 * 0.15, steps=[{"hoursAgo": 46, "add": p95 * 0.9}] if route == "cloud.hrossen.dk" else None)
    s("svc.errors", ci, err, err * 0.5, err * 0.4, mx=100)
    s("svc.rate", ci, rate, rate * 0.7, rate * 0.2)
    s("svc.probe", ci, p95 * 0.3, p95 * 0.05, p95 * 0.05)
    s("svc.up", ci, 0, 0, 0)

doc = {"note": "Synthetic: written by make-metrics.py, read by src/perffixture.ts.", "measuredSeries": 2140, "series": series}
json.dump(doc, open(os.path.join(HERE, "metrics.json"), "w"), indent=1)
print(f"{len(series)} series")
