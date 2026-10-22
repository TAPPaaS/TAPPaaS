// deviceview.tsx — the Device view's graph: one plain card per physical
// device (devicegraph.ts), one line per pair of devices a cable joins. A
// click selects the device; the side panel has the rest.

import { useMemo } from "react";
import { GEdge, GNode, Graph } from "../graph";
import { Topology } from "../types";
import { DevLabel, linkStyle, linkText } from "./devicecard";
import { deviceGraph, deviceState, selectedDevice } from "./devicegraph";
import { Sel } from "./layout";
import { STATE_COLOR, stateClass } from "./state";

export function DeviceGraph({ t, sel, pick, labels }: { t: Topology; sel: Sel | null; pick: (s: Sel) => void; labels: boolean }) {
  const { nodes, edges } = useMemo(() => {
    const g = deviceGraph(t);
    const on = selectedDevice(g, sel);
    const nodes: GNode[] = g.nodes.map((d) => {
      const s = deviceState(t, d);
      return { id: d.id, w: 58 + d.name.length * 8, h: 36, accent: STATE_COLOR[s.state], className: `${stateClass(s.state)}${on === d.id ? " gcard-on" : ""}`, onClick: () => pick(d.sel), content: <DevLabel d={d} s={s} /> };
    });
    const edges: GEdge[] = g.links.map((l) => {
      const st = linkStyle(l, t);
      return { source: l.a, target: l.b, color: st.stroke, dashed: !!st.dash, label: labels ? linkText(l) : undefined };
    });
    return { nodes, edges };
  }, [t, sel, pick, labels]);
  return <Graph nodes={nodes} edges={edges} rankdir="LR" height="100%" nodesep={26} ranksep={110} />;
}
