// faceplateform.tsx — Add a faceplate…: a plate the site adds for a model the
// catalog lacks (position-manager faceplate add). The form takes its key, its
// units and width, what it is and its ports as a port spec, explains the spec
// and draws the plate as the fields change, with the code position-manager
// reads the spec with (portspec.ts). Change → Preview (--check) → Apply.

import { ManifestVerb, PlatePort, ResolvedPlate } from "../types";
import { Step, Values } from "../operate";
import { PlateSvg, Placed, R } from "./rack";
import { CatalogPort, blockRows, parsePortSpec } from "./portspec";

const RM = "position-manager";
const KINDS = ["other", "server", "switch", "ap", "patch-panel", "pdu", "modem"];
const WIDTHS = ["full", "half", "third"];
const KEY_RE = /^[a-z0-9][a-z0-9-]*\/[a-z0-9][a-z0-9.+-]*$/;
// The examples a click puts in the ports field.
const EXAMPLES: [string, string][] = [
  ["24xrj45", "24 ports in one row, 1-24"],
  ["8xrj45, 2xsfp+", "eight RJ45, a gap, two SFP+ (9, 10)"],
  ["8xsfp+/8xsfp+", "two rows of eight: 1-8 over 9-16"],
  ["16xsfp+@2:sfp-sfpplus{n}[3-66]", "sixteen cages odd over even, in the left two thirds"],
  ["rj45:WAN+gap+4xrj45:LAN {n}", "WAN, a gap, LAN 1-4"],
];

// The plate the fields describe, as the rack draws it; or what is wrong with the spec.
export function previewPlate(values: Values, keyName = "@vendor/model"): { plate: ResolvedPlate } | { error: string } {
  const str = (k: string) => (typeof values[k] === "string" ? (values[k] as string).trim() : "");
  const spec = parsePortSpec(str("--ports"));
  if ("error" in spec) return spec;
  const units = Number(str("--units") || "1");
  if (!Number.isInteger(units) || units < 1 || units > 10) return { error: "units is 1 to 10 rack units" };
  const rows = Math.max(...spec.blocks.map((b) => b.rows.length));
  if (rows > 3 * units) return { error: `${rows} rows of ports do not fit ${units}U: at most ${3 * units}` };
  const port = (c: CatalogPort | null): PlatePort | null => (c ? { id: c.name, name: c.name, kind: c.kind, up: null, disabled: false, lag: null, zones: [] } : null);
  const blocks = spec.blocks.map((b) => ({ from: b.from, to: b.to, rows: b.rows.map((r) => r.map(port)) }));
  const key = str(keyName) || "vendor/model";
  const [vendor, model] = key.split("/");
  const width = (WIDTHS.includes(str("--width")) ? str("--width") : "full") as ResolvedPlate["width"];
  return {
    plate: {
      key,
      vendor: str("--vendor") || vendor || "vendor",
      model: str("--display-name") || model || "model",
      kind: str("--kind") || "other",
      units,
      width,
      passive: values["--passive"] === true,
      rows: blockRows(blocks),
      blocks,
      labels: [],
      site: true,
    },
  };
}

// The plate drawn as the rack draws it: at its width of a 19in rack, its units high.
function Preview({ values, keyName }: { values: Values; keyName: string }) {
  const r = previewPlate(values, keyName);
  if ("error" in r) return <p className="readstate readstate-warn">The ports: {r.error}</p>;
  const { plate } = r;
  const w = plate.width === "full" ? R.w19 : plate.width === "half" ? R.w19 / 2 : R.w19 / 3;
  const h = plate.units * R.u - 2;
  const p: Placed = { device: "new plate", kind: plate.passive ? "passive" : "device", plate, box: { x: R.rail + 1, y: 6, w, h }, up: null, title: plate.key, sub: `${plate.vendor} ${plate.model}`, rack: null };
  const n = plate.rows.flat().filter(Boolean).length;
  return (
    <div className="faceplate-preview">
      <svg viewBox={`0 0 ${R.w19 + 2 * R.rail} ${h + 12}`} width="100%" role="img" aria-label="the plate as it will be drawn">
        <rect x={0} y={2} width={R.rail} height={h + 8} fill="#cbd5e1" />
        <rect x={R.w19 + R.rail} y={2} width={R.rail} height={h + 8} fill="#cbd5e1" />
        <PlateSvg p={p} on={false} portOn={() => false} onPlate={() => undefined} onPort={() => undefined} />
      </svg>
      <small className="muted">
        {n} port{n === 1 ? "" : "s"}, as the rack will draw them — hover a port for its name. Ports: {plate.rows.flat().filter(Boolean).map((x) => x!.name).join(", ")}
      </small>
    </div>
  );
}

function FaceplateFields({ values, set, verb }: { values: Values; set: (v: Values) => void; verb: ManifestVerb }) {
  const keyName = `@${verb.positionals[0]?.name ?? "vendor/model"}`;
  const v = (k: string) => (typeof values[k] === "string" ? (values[k] as string) : "");
  const put = (k: string, x: string | boolean | string[]) => set({ ...values, [k]: x });
  const key = v(keyName);
  return (
    <div className="form">
      <label className="form-row">
        <span>vendor/model *</span>
        <input type="text" placeholder="acme/nas-4" value={key} onChange={(e) => put(keyName, e.target.value)} />
        <small className={key && !KEY_RE.test(key) ? "readstate-warn" : "muted"}>Lower case: the vendor, a slash, the model (letters, digits, dashes; the model also . and +). A placement and a recorded device name the plate by it.</small>
      </label>
      <label className="form-row">
        <span>units *</span>
        <input type="number" min={1} max={10} value={v("--units")} onChange={(e) => put("--units", e.target.value)} />
        <small className="muted">Its height in rack units.</small>
      </label>
      <label className="form-row">
        <span>width</span>
        <select value={v("--width") || "full"} onChange={(e) => put("--width", e.target.value)}>
          {WIDTHS.map((x) => (
            <option key={x} value={x}>{x === "full" ? "full width" : `${x} width`}</option>
          ))}
        </select>
      </label>
      <label className="form-row">
        <span>kind</span>
        <select value={v("--kind") || "other"} onChange={(e) => put("--kind", e.target.value)}>
          {KINDS.map((x) => (
            <option key={x} value={x}>{x}</option>
          ))}
        </select>
      </label>
      <label className="form-check">
        <input type="checkbox" checked={values["--passive"] === true} onChange={(e) => put("--passive", e.target.checked)} />
        passive <small className="muted">— nothing sees it (a patch panel, a PDU): placed without a device the topology knows</small>
      </label>
      <label className="form-row">
        <span>ports *</span>
        <input type="text" className="mono" placeholder="24xrj45" value={v("--ports")} onChange={(e) => put("--ports", e.target.value)} />
        <small className="muted">
          Groups side by side, a <b>comma</b> between them (a gap on the plate); rows within a group, top to bottom, a <b>slash</b> between them; items within a row, a <b>plus</b> between them, each <span className="mono">[count x]kind[:name]</span>. A kind is rj45, sfp+, sfp28, poe, console, power, or gap (an empty place); after sfp+ the next item takes its own plus (2xsfp++rj45). Ports are numbered 1, 2, … unless named; <span className="mono">{"{n}"}</span> in a name is its number. <span className="mono">16xsfp+@2</span> stacks sixteen in two rows, odd over even. A group may end in its place in percent of the width, <span className="mono">[3-66]</span>: give every group one, or none.
        </small>
        <span className="faceplate-examples">
          {EXAMPLES.map(([s, what]) => (
            <button type="button" key={s} className="btn btn-small" title={what} onClick={() => put("--ports", s)}>
              <span className="mono">{s}</span>
            </button>
          ))}
        </span>
      </label>
      <Preview values={values} keyName={keyName} />
      <label className="form-row">
        <span>matches</span>
        <input type="text" placeholder="NAS-4X, NAS4X-RM" value={Array.isArray(values["--match"]) ? (values["--match"] as string[]).join(", ") : ""} onChange={(e) => put("--match", e.target.value.split(",").map((x) => x.trim()))} />
        <small className="muted">The models or names the switches and inventories report it by, comma-separated: the plate is then suggested for those devices.</small>
      </label>
      <label className="form-row">
        <span>display name</span>
        <input type="text" placeholder={key.split("/")[1] ?? ""} value={v("--display-name")} onChange={(e) => put("--display-name", e.target.value)} />
        <small className="muted">The model as drawn; unset, the key's.</small>
      </label>
      <label className="form-row">
        <span>description</span>
        <input type="text" value={v("--description")} onChange={(e) => put("--description", e.target.value)} />
      </label>
    </div>
  );
}

// Add a faceplate…: one step, its own form (the verb's options are its fields).
export function faceplateAddSteps(): Step[] {
  return [
    {
      title: "position-manager faceplate add <vendor/model>",
      bin: RM,
      verb: "faceplate add",
      only: [],
      initial: { "--units": "1", "--width": "full", "--kind": "other", "--ports": "24xrj45" },
      render: (values, set, verb) => <FaceplateFields values={values} set={set} verb={verb} />,
      note: "A plate for a device model the catalog lacks, kept in config/positions.json with the site's other records and offered wherever a plate or a model is chosen (Place…, Record a device…). A key the catalog already has gives the site its own plate in place of the shipped one. Devices without a plate keep the generic one for their kind.",
    },
  ];
}
