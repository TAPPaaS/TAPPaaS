// HealthChecks.tsx — Day 1's "Status and health checks", after Rest of
// foundation: the modules running, the nodes answering and in quorum, the
// internet from the mothership, and — with more than one node — every zone's
// VLAN reaching from each node to the others (health-manager vlan-reach). A VLAN
// that does not cross says which ports must carry it, and that managing the
// switches is the easier way. All well: congratulations, and what comes next.

import { refreshAll, reloadAll } from "../api";
import { Step, StepView } from "../operate";
import { Dot, Level, canOperate, useMe } from "../ui";
import type { SetupDoc } from "./Setup";

type Gate = { name: string; status: string; detail: string };
const LEVEL: Record<string, Level> = { pass: "pass", warn: "warn", fail: "fail", skip: "skip" };

function Line({ label, gates }: { label: string; gates: (Gate | null)[] }) {
  const got = gates.filter((g): g is Gate => g !== null);
  const worst = got.find((g) => g.status === "fail") ?? got.find((g) => g.status === "warn") ?? got[0] ?? null;
  return (
    <li>
      <Dot level={worst ? LEVEL[worst.status] ?? "skip" : "skip"} title="" /> <b>{label}</b>: {got.length ? got.map((g) => g.detail).join("; ") : <span className="muted">not checked yet</span>}
    </li>
  );
}

export function HealthChecks({ doc, done }: { doc: SetupDoc | null; done: boolean | null }) {
  const me = useMe();
  const h = doc?.inputs.health;
  const gate = (n: string) => h?.gates?.find((g) => g.name === n) ?? null;
  const nodes = doc?.inputs.siteNodes ?? [];
  const r = h?.reach ?? null;
  const bad = (r?.vlans ?? []).filter((v) => v.missing.length);
  const involved = [...new Set(bad.flatMap((v) => v.missing.flatMap((m) => [m.from, m.to])))].sort();
  const probe: Step = {
    title: "health-manager vlan-reach",
    bin: "health-manager",
    verb: "vlan-reach",
    hide: ["--json", "--config-dir"],
    button: "Test the VLANs across the nodes",
    note: "Each node gets a probe interface on its LAN bridge for every zone's VLAN for a few seconds, pings the other nodes on it, and removes it. No guest, route or address of the site is touched.",
  };
  return (
    <>
      <ul className="small plain">
        <Line label="Modules" gates={[gate("service-liveness")]} />
        <Line label="Nodes" gates={[gate("quorum")]} />
        <Line label="Internet" gates={[gate("internet")]} />
        <li>
          <Dot level={nodes.length < 2 ? "pass" : !r ? "skip" : r.ok ? "pass" : "fail"} title="" /> <b>VLANs across the nodes</b>:{" "}
          {nodes.length < 2
            ? "one node: no VLAN crosses a switch"
            : !r
              ? <span className="muted">not tested yet</span>
              : r.error
                ? r.error
                : r.ok
                  ? `every zone's VLAN reaches every node (${r.vlans.length} VLANs)`
                  : bad.map((v) => `VLAN ${v.vid} (${v.zone}): ${v.missing.map((m) => `${m.from} does not reach ${m.to}`).join(", ")}`).join("; ")}
        </li>
      </ul>
      <p className="small toolbar">
        <button className="btn" onClick={() => void refreshAll()} title="Runs the health checks again and reads the results">Check again</button>
      </p>
      {nodes.length > 1 && canOperate(me) ? <StepView step={probe} me={me} onDone={() => { void refreshAll(); setTimeout(reloadAll, 1500); }} /> : null}
      {bad.length ? (
        <div className="small">
          <p>
            Carry VLAN{bad.length > 1 ? "s" : ""} <b>{bad.map((v) => `${v.vid} (${v.zone})`).join(", ")}</b> tagged on the switch ports these nodes' LAN ports are cabled to, and on every link between those switches:
          </p>
          <ul>
            {involved.map((n) => <li key={n}>{n}: LAN port {(r?.lanPorts[n] ?? []).join(", ") || "(not recorded)"}</li>)}
          </ul>
          <p>Easier: bring the switches under management (Switch fabric, below), and TAPPaaS sets these ports itself.</p>
        </div>
      ) : null}
      {done ? (
        <p className="small">
          <b>Congratulations — you have a working system.</b> The rest is optional, but you are encouraged to install some application stacks to make the system useful, and to make it public with DNS records.
        </p>
      ) : null}
    </>
  );
}
