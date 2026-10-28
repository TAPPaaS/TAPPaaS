// NodeUplinks.tsx — Add node's stages 5a and 5b: a node's lan uplink (a
// second leg, bonded, then the failover test) and its WAN port. Each says
// what the node has now, offers the ports it has and the switch ports they
// can go to, and runs site-manager node network set — the switch side first,
// then the node — previewed.

import { useMemo, useState } from "react";
import { useRead } from "../api";
import { Step, StepView } from "../operate";
import { NodeNetwork, NodePort, lanCandidates, lldpSwitchPort, portLabel, switchPortChoices, wanCandidates, wanPort } from "../nodeadd";
import { Topology } from "../types";
import { Dot, useMe } from "../ui";

function useNetwork(node: string): NodeNetwork | null | undefined {
  const r = useRead<NodeNetwork>(`nodes/${encodeURIComponent(node)}/network`, 10_000);
  return r.env ? r.env.data : undefined;
}

function PortLine({ p, role }: { p: NodePort; role: string }) {
  return (
    <li>
      <Dot level={p.state === "up" ? "pass" : "skip"} /> {role}: <span className="mono">{p.name}</span> <span className="muted small">{p.mac}</span> — {portLabel(p).split(" · ").slice(1).join(" · ") || "no link"}
    </li>
  );
}

// 5a: lan — its ports now, then one more leg: the bond's mode, the node port,
// the switch port it is cabled to. Apply sets up the switch port and the node;
// the failover test is the last step.
export function LanUplink({ node, onDone }: { node: string; onDone: (ok: boolean) => void }) {
  const me = useMe();
  const net = useNetwork(node);
  const topo = useRead<Topology>("topology").env?.data;
  const choices = useMemo(() => switchPortChoices(topo?.switches ?? [], node), [topo, node]);
  const [mode, setMode] = useState<string | null>(null);
  const [port, setPort] = useState<string>("");
  const [sw, setSw] = useState<string | null>(null);
  const [applied, setApplied] = useState(false);
  if (net === undefined) return <p className="muted small">reading {node}'s ports…</p>;
  if (!net?.live) return <p className="muted small">{node}'s ports could not be read (site-manager node network show {node}).</p>;
  const members = net.live.lan.members;
  const candidates = lanCandidates(net);
  const picked = candidates.find((p) => p.name === port);
  const lanMode = mode ?? (net.live.lan.mode === "lacp" ? "lacp" : "active-backup");
  const swPort = sw ?? lldpSwitchPort(picked, choices) ?? "";
  const set: Step = {
    title: `site-manager node network set ${node}`,
    bin: "site-manager",
    verb: "node network set",
    fixed: [node],
    only: [],
    hide: ["--yes"],
    initial: {
      "--lan-ports": [...members.map((m) => m.name), port].join(","),
      "--lan-mode": lanMode,
      ...(swPort ? { "--switch-port": swPort } : {}),
      "--yes": true,
    },
    note: (
      <p>
        The preview declares the uplink in the node's config on the mothership and checks it on the node, which it does not change. Apply sets up the switch port first ({node}'s node trunk), then moves lan onto both ports: the node is drained (its HA guests move away), the change runs under a 45-second rollback, the mothership confirms it, and the node comes back.
        {lanMode === "lacp" ? " For lacp the two switch ports must also be one LAG: set it on the switch (Site › Device, the switch's ports) before the test." : ""}
      </p>
    ),
  };
  const test: Step = {
    title: `site-manager node network test ${node}`,
    bin: "site-manager",
    verb: "node network test",
    fixed: [node],
    only: [],
    hide: ["--yes"],
    initial: { "--yes": true },
    note: "The last step: proof that losing either port keeps the node reachable. Apply drains the node, then takes each lan port down for ten seconds in turn; the management network and the cluster link must stay up throughout. A timer on the node brings a port back after 30 seconds whatever happens.",
  };
  return (
    <div>
      <p className="small"><b>lan on {node} now</b> — {members.length > 1 ? `${net.live.lan.mode}, ${members.length} ports` : "one port"}:</p>
      <ul className="plain small checks">{members.map((p) => <PortLine key={p.mac} p={p} role="lan" />)}</ul>
      {!applied ? (
        candidates.length ? (
          <>
            <label className="form-row">
              <span>lan mode</span>
              <select value={lanMode} onChange={(e) => setMode(e.target.value)}>
                <option value="active-backup">active-backup — one leg carries traffic, the other takes over; any switches, any speeds</option>
                <option value="lacp">lacp — both legs carry traffic; equal speeds, the two switch ports one LAG</option>
              </select>
            </label>
            <label className="form-row">
              <span>add a lan port</span>
              <select value={port} onChange={(e) => { setPort(e.target.value); setSw(null); }}>
                <option value="">— choose one of {node}'s ports</option>
                {candidates.map((p) => <option key={p.mac} value={p.name}>{portLabel(p)}</option>)}
              </select>
              <small className="muted">Cable it first: a port with a link, and the switch port LLDP sees behind it, are shown.</small>
            </label>
            {port ? (
              <label className="form-row">
                <span>its switch port</span>
                <select value={swPort} onChange={(e) => setSw(e.target.value)}>
                  <option value="">— none: on a switch TAPPaaS does not program, set by hand</option>
                  {choices.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
                </select>
                <small className="muted">Made {node}'s node trunk on the switch before the node changes.</small>
              </label>
            ) : null}
            {port ? <StepView key={`${port}|${lanMode}|${swPort}`} step={set} me={me} onDone={(ok) => ok && setApplied(true)} /> : null}
          </>
        ) : <p className="muted small">{node} has no other port for lan: one port it stays.</p>
      ) : null}
      {applied ? <StepView step={test} me={me} onDone={(ok) => ok && onDone(true)} /> : null}
      {!applied ? <p className="small"><button className="btn" onClick={() => onDone(false)}>Keep one lan port →</button> <span className="muted">(site-manager node network set later)</span></p> : null}
    </div>
  );
}

// 5b: the WAN port — for a node that may carry the firewall. Declared already:
// shown, and the stage is complete. Else a port and, optionally, the switch
// port that becomes an access port in the WAN zone.
export function WanUplink({ node, onDone }: { node: string; onDone: (ok: boolean) => void }) {
  const me = useMe();
  const net = useNetwork(node);
  const topo = useRead<Topology>("topology").env?.data;
  const choices = useMemo(() => switchPortChoices(topo?.switches ?? [], node), [topo, node]);
  const [port, setPort] = useState("");
  const [sw, setSw] = useState("");
  if (net === undefined) return <p className="muted small">reading {node}'s ports…</p>;
  if (!net?.live) return <p className="muted small">{node}'s ports could not be read (site-manager node network show {node}).</p>;
  const has = wanPort(net);
  if (has) {
    return (
      <div>
        <ul className="plain small checks"><PortLine p={has} role="WAN" /></ul>
        <p className="small">{node}'s WAN port is set: nothing to apply here. {has.state !== "up" ? <span className="muted">It has no link — cable it to the WAN (an access port in the WAN zone) before the firewall's failover moves here. </span> : null}<span className="muted">Another port: site-manager node network set {node} --wan-port &lt;port&gt;.</span></p>
        <p className="small"><button className="btn btn-primary" onClick={() => onDone(true)}>Continue →</button></p>
      </div>
    );
  }
  const set: Step = {
    title: `site-manager node network set ${node} --wan-port ${port || "<port>"}`,
    bin: "site-manager",
    verb: "node network set",
    fixed: [node],
    only: [],
    hide: ["--yes"],
    initial: { "--wan-port": port, ...(sw ? { "--wan-switch-port": sw } : {}), "--yes": true },
    note: "The wan bridge takes the port, so the firewall's WAN can fail over to this node (with the network module's HANode). Apply sets up the switch port first, as an access port in the WAN zone, then the node, under the same rollback as lan.",
  };
  return (
    <div>
      <p className="small">{node} has no WAN port: it cannot carry the firewall's WAN. Give it one only if it should be the firewall's failover node.</p>
      <label className="form-row">
        <span>WAN port</span>
        <select value={port} onChange={(e) => setPort(e.target.value)}>
          <option value="">— choose one of {node}'s ports</option>
          {wanCandidates(net).map((p) => <option key={p.mac} value={p.name}>{portLabel(p)}</option>)}
        </select>
      </label>
      {port ? (
        <label className="form-row">
          <span>its switch port</span>
          <select value={sw} onChange={(e) => setSw(e.target.value)}>
            <option value="">— none: cabled to the WAN directly, or set by hand</option>
            {choices.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
          </select>
          <small className="muted">Optional: made an access port in the WAN zone on the switch.</small>
        </label>
      ) : null}
      {port ? <StepView key={`${port}|${sw}`} step={set} me={me} onDone={(ok) => ok && onDone(true)} /> : null}
      <p className="small"><button className="btn" onClick={() => onDone(false)}>No WAN port →</button></p>
    </div>
  );
}
