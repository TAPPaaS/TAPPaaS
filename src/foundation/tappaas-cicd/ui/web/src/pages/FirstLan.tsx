// FirstLan.tsx — Day 1's first node: which of its ports is the LAN uplink.
// The install takes the port it ran on as the WAN and guesses the LAN port; here
// the operator sees every port with its link, cables the switch, rescans, and
// confirms the port that lit up — or says the machine stands alone (its lan
// bridge has no port: a one-machine site). Moving lan to another port runs
// site-manager node network set, previewed.

import { useState } from "react";
import { post, useRead } from "../api";
import { NodeNetwork, firstLanRows, portSpeed } from "../nodeadd";
import { Step, StepView } from "../operate";
import { Dot, canOperate, useMe } from "../ui";

export function FirstLanUplink({ node, answer, onChanged }: { node: string; answer: string | undefined; onChanged: () => void }) {
  const me = useMe();
  const r = useRead<NodeNetwork>(`nodes/${encodeURIComponent(node)}/network`, 600_000);
  const net = r.env?.data ?? null;
  const [pick, setPick] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const answerIt = async (a: string | null) => {
    setMsg(null);
    const res = await post<unknown>("setup/answer", { step: "firstlan", answer: a });
    if (!res.ok) return setMsg(res.error);
    onChanged();
  };
  const operator = canOperate(me);
  const alone = operator ? <button className="btn" onClick={() => void answerIt("alone")}>This machine alone</button> : null;

  if (answer) {
    return (
      <p className="small toolbar">
        <span>{answer === "alone" ? `${node} stands alone: its LAN stays inside it.` : `${node}'s LAN uplink is confirmed.`}</span>
        {operator ? <button className="btn" onClick={() => void answerIt(null)}>Undo</button> : null}
        {msg ? <span className="ff-error small">{msg}</span> : null}
      </p>
    );
  }
  if (!r.env) return <p className="muted small">Reading {node}'s ports…</p>;
  if (!net?.live) {
    return (
      <p className="small toolbar">
        <span className="readstate readstate-fail">{node}'s ports could not be read{r.env.error ? `: ${r.env.error}` : ""}.</span>
        <button className="btn" onClick={r.reload}>Rescan</button>
        {alone}
      </p>
    );
  }
  const rows = firstLanRows(net);
  const lanNow = rows.filter((x) => x.role === "lan").map((x) => x.port.name);
  // A bonded LAN (two or more ports) is Day 2's to change: picking one port here would un-bond it.
  const bonded = lanNow.length > 1;
  const chosen = bonded ? null : rows.find((x) => x.port.name === pick && x.role !== "wan") ?? null;
  const same = chosen !== null && lanNow.length === 1 && lanNow[0] === chosen.port.name;
  const set: Step | null = chosen && !same ? {
    title: `site-manager node network set ${node}`,
    bin: "site-manager",
    verb: "node network set",
    previewOnOpen: false,
    fixed: [node],
    only: [],
    hide: ["--yes"],
    initial: { "--lan-ports": chosen.port.name, "--yes": true },
    button: `Move LAN to ${chosen.port.name}`,
    note: `The management network, every zone's VLAN and the firewall's LAN move from ${lanNow.join(", ") || "no port"} to ${chosen.port.name}. It runs under a 45-second rollback: if the mothership cannot reach ${node} on the new port, the old one comes back by itself. The WAN, and this page's connection over it, are not touched.`,
  } : null;

  return (
    <div className="setup-lan">
      <p className="small">
        Which port goes to the switch? Plug the switch's cable into the port meant for LAN and press Rescan: that port gets a green dot. The WAN is the port the install ran on, to the router.
      </p>
      <table className="table compact">
        <thead>
          <tr><th></th><th>port</th><th>link</th><th>now</th></tr>
        </thead>
        <tbody>
          {rows.map(({ port, role }) => (
            <tr key={port.mac} className={role === "wan" ? "muted" : undefined}>
              <td>
                <input type="radio" name={`lan-${node}`} aria-label={port.name} disabled={role === "wan" || bonded || !operator} checked={pick === port.name} onChange={() => setPick(port.name)} />
              </td>
              <td><span className="mono">{port.name}</span> <span className="muted small">{port.mac}</span></td>
              <td><Dot level={port.state === "up" ? "pass" : "skip"} title="" /> {port.state === "up" ? `up ${portSpeed(port.speed)}`.trim() : "no link"}{port.lldp ? <span className="muted small"> · {port.lldp.name} {port.lldp.port}</span> : null}</td>
              <td>{role === "wan" ? "WAN" : role === "lan" ? "LAN" : ""}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="small toolbar">
        <button className="btn" onClick={r.reload} title="Reads the ports again (at most every ten seconds)">Rescan</button>
        {alone}
        {msg ? <span className="ff-error small">{msg}</span> : null}
      </p>
      {chosen && same ? (
        <div className="actions">
          <button className="btn btn-primary" onClick={() => void answerIt("port")}>Confirm {chosen.port.name} as the LAN port</button>
          {chosen.port.state !== "up" ? <span className="muted small">it has no link yet: cable it first</span> : null}
        </div>
      ) : null}
      {set ? <StepView key={set.initial?.["--lan-ports"] as string} step={set} me={me} onDone={(ok) => ok && void answerIt("port")} /> : null}
      {bonded ? (
        <p className="small">LAN is a bond of {lanNow.join(" and ")}: its ports change on Day 2 (the node's network). Confirm it here as it is, or say the machine stands alone.</p>
      ) : null}
      {bonded && operator ? <div className="actions"><button className="btn btn-primary" onClick={() => void answerIt("port")}>Confirm the bond as the LAN uplink</button></div> : null}
      {!chosen && !bonded ? <p className="muted small">Choose the port the switch is on{lanNow.length ? `; LAN is on ${lanNow.join(", ")} now` : ""}.</p> : null}
    </div>
  );
}
