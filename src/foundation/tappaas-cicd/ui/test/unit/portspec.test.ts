// portspec.test.ts — the Add a faceplate preview reads a port spec as
// position-manager does: web/src/physical/portspec.ts and lib/ts positions.ts
// give the same blocks, or the same refusal, for every spec here.

import { parsePortSpec as manager, blockRows as managerRows } from "../../../lib/ts/src/positions";
import { parsePortSpec as preview, blockRows as previewRows } from "../../web/src/physical/portspec";
import { check, done } from "./check";

const SPECS = [
  "24xrj45",
  "8xrj45, 2xsfp+",
  "8xsfp+/8xsfp+",
  "16xsfp+@2:sfp-sfpplus{n}[3-66], rj45:ether1/console:console[68-74]",
  "rj45:WAN+gap+4xrj45:LAN {n}",
  "2xsfp++2xrj45",
  "4xrj45:eth",
  "12xrj45[2-98]",
  "10xpoe:Port {n}+gap+2xsfp+:Port {n}[3-97]",
  " 4 x rj45 , 2xsfp28 ",
  "48xrj45@2",
  "power/power, 8xpower",
  // refused
  "",
  "24xfoo",
  "8xrj45,,2xsfp+",
  "8xrj45/",
  "rj45:a+rj45:a",
  "8xrj45[0-50], 2xsfp+",
  "8xrj45[0-60], 2xsfp+[50-70]",
  "16xsfp+@2+rj45",
  "gap:x",
  "200xrj45",
  "rj45[80-20]",
];
for (const s of SPECS) {
  const a = manager(s);
  const b = preview(s);
  check(JSON.stringify(a) === JSON.stringify(b), `the same reading: '${s}'${"error" in a ? ` (refused: ${a.error})` : ""}`);
  if (!("error" in a) && !("error" in b)) check(JSON.stringify(managerRows(a.blocks)) === JSON.stringify(previewRows(b.blocks)), `…and the same rows: '${s}'`);
}
done("portspec");
