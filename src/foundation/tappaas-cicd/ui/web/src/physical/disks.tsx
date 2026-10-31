// disks.tsx — the disks of an asset in the console (ADR-042): the bay row a
// server's card draws (one cell per disk, coloured by its health as a port is
// by its link), a disk's placements (which assets it has been in), and the
// changes asset-manager's verbs make to disks — a disk recorded in an asset
// (disk add) or the ones its CI knows adopted (disk adopt), a disk moved into
// another asset (place --in), taken out into stock (unplace), its record
// changed or removed, and disposed of with whether it was wiped. Each change
// is a Step (operate.tsx): Change → Preview (--check) → Apply.

import { useRead } from "../api";
import { assetPath } from "../details";
import { BayCell, DISK_COLOR, bayRow, healthText, placeFieldsFor, placementLines, poolText } from "../diskview";
import { OperateButton, Step } from "../operate";
import { AssetRow, AssetTreeDisk, DiskPlacement } from "../types";
import { KV, Link, ReadState, when } from "../ui";

const RM = "asset-manager";
const DISK_KINDS = ["nvme", "ssd", "hdd", "usb"];

// ── the bay row ───────────────────────────────────────────────────────

// One cell per disk in bay order; compact: small squares only (a graph
// card), else each with its bay, a click opening the disk's page.
export function BayRow({ disks, compact }: { disks: AssetTreeDisk[]; compact?: boolean }) {
  if (!disks.length) return null;
  const cells = bayRow(disks);
  if (compact) {
    return (
      <span className="bay-row bay-row-compact" aria-label={`${cells.length} disk(s)`}>
        {cells.map((c) => <i key={c.disk} className="bay-cell" style={{ background: DISK_COLOR[c.state] }} title={c.title} />)}
      </span>
    );
  }
  return (
    <>
      <h3>Storage bays</h3>
      <div className="bay-row" role="list" aria-label="storage bays">
        {cells.map((c: BayCell) => (
          <span key={c.disk} role="listitem" className="bay" title={c.title}>
            <i className="bay-cell" style={{ background: DISK_COLOR[c.state] }} />
            <Link to={assetPath(c.disk)}>{c.label}</Link>
          </span>
        ))}
      </div>
    </>
  );
}

// ── a disk's placements ──────────────────────────────────────────────

// Which assets a disk has been in, from the CMDB's history of its CIs.
export function DiskPlacements({ disk }: { disk: string }) {
  const r = useRead<DiskPlacement[]>(`assets/disk/${encodeURIComponent(disk)}/placements`, 60_000);
  const list = placementLines(r.env?.data ?? []);
  return (
    <>
      <ReadState env={r.env} failure={r.failure} what="its placements in the CMDB" />
      {r.env?.data && !list.length ? <p className="muted small">The CMDB has it in no asset yet: a disk has a CMDB record while it is in one.</p> : null}
      {list.length ? (
        <table className="table compact small">
          <thead>
            <tr>
              <th>in</th>
              <th>bay</th>
              <th>from</th>
              <th>until</th>
            </tr>
          </thead>
          <tbody>
            {list.map((p, i) => (
              <tr key={i}>
                <td>{p.asset !== "?" ? <Link to={assetPath(p.asset)}>{p.asset}</Link> : <span className="muted">?</span>}</td>
                <td className="mono">{p.bay ?? ""}</td>
                <td className="nowrap">{when(p.from)}</td>
                <td className="nowrap">{p.now ? <span className="muted">it is there now</span> : when(p.until)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : null}
    </>
  );
}

// ── the changes ───────────────────────────────────────────────────────

export function diskAddSteps(asset: string): Step[] {
  return [
    {
      title: `asset-manager disk add '${asset}' <name> --serial <serial>`,
      bin: RM,
      verb: "disk add",
      fixed: [asset],
      only: ["--serial", "--model", "--vendor", "--wwn", "--size", "--kind", "--bus", "--firmware", "--bay", "--description"],
      choices: { "--kind": DISK_KINDS },
      placeholders: { "@name": "its by-id name: ata-Samsung_SSD_870_EVO_1TB_S6P…", "--size": "960G, 4TB" },
      note: `A disk in ${asset}, recorded as the next dsk-NN with its by-id name shown. Its serial is what knows it again: one an asset records already is refused (move that disk instead). Its bay is the slot as ${asset} labels it, else its by-id name. --check previews.`,
    },
  ];
}

export function diskAdoptSteps(asset: string, which: string): Step[] {
  return [
    {
      title: `asset-manager disk adopt '${asset}'`,
      bin: RM,
      verb: "disk adopt",
      fixed: [asset],
      note: `Records every disk ${asset}'s CMDB record lists (the discovery sweep's) that no asset records, by serial, as a disk in ${asset}: ${which}. A disk without a serial is skipped (Record a disk… by hand). The preview lists what it records.`,
    },
  ];
}

export function diskMoveSteps(disk: string, hosts: string[], bay: string | null): Step[] {
  return [
    {
      title: `asset-manager place '${disk}' --in <asset>`,
      bin: RM,
      verb: "place",
      fixed: [disk],
      only: placeFieldsFor("disk").map((f) => `--${f}`),
      choices: { "--in": hosts },
      ...(bay ? { placeholders: { "--bay": bay } } : {}),
      note: "Into another asset (a server), out of stock or out of the asset it is in: the move. Its CMDB record in the old asset ends and one in the new begins, so its history shows every asset it has been in. The bay is the new asset's label for the slot, else its by-id name.",
    },
  ];
}

export function diskUnplaceSteps(disk: string, host: string): Step[] {
  return [{ title: `asset-manager unplace '${disk}'`, bin: RM, verb: "unplace", fixed: [disk], note: `It leaves ${host} and goes to stock, under its location's Not placed. Its CMDB record in ${host} ends; nothing on the node changes.` }];
}

export function diskModifySteps(disk: string): Step[] {
  return [
    {
      title: `asset-manager disk modify '${disk}'`,
      bin: RM,
      verb: "disk modify",
      fixed: [disk],
      placeholders: { "--set": "kind=ssd, size=960G, bay=2, firmware=…", "--unset": "description" },
      note: "Its display name, description, vendor, model, serial, asset tag, WWN, size, kind, bus, firmware or bay, as --set field=value, or --unset field (its serial stays). Where it is: Move to….",
    },
  ];
}

export function diskRemoveSteps(disk: string): Step[] {
  return [{ title: `asset-manager disk remove '${disk}'`, bin: RM, verb: "disk remove", fixed: [disk], note: "A record made by mistake, with its placement. A disk that leaves the site is disposed of instead: its record stays." }];
}

// Dispose…: a disk leaves the site; the form asks whether it was wiped, which
// the disposal record keeps.
export function diskDisposeSteps(disk: string): Step[] {
  return [
    {
      title: `asset-manager asset dispose '${disk}' --how <how>`,
      bin: RM,
      verb: "asset dispose",
      fixed: [disk],
      only: ["--how", "--wiped", "--when"],
      choices: { "--how": ["sold", "recycled", "returned", "lost"] },
      labels: { "--wiped": "Was it wiped?" },
      note: "Its last stage: sold, recycled, returned or lost, and when (default today). Tick Was it wiped? only when its data was erased before it left: the disposal record keeps the answer. The check refuses a disk still in an asset (Take out… first); its record stays.",
    },
  ];
}

// A disk's row on the page of the asset it is in: Move to…, Take out….
export function DiskRowOps({ d, hosts }: { d: AssetTreeDisk; hosts: string[] }) {
  return (
    <span className="toolbar">
      <OperateButton label="Move to…" title={`Move ${d.name}`} steps={() => diskMoveSteps(d.name, hosts, d.bay)} />
      {d.host ? <OperateButton label="Take out…" kind="danger" title={`Take ${d.name} out of ${d.host}`} steps={() => diskUnplaceSteps(d.name, d.host!)} /> : null}
    </span>
  );
}

// ── a disk in the Storage view's side card ────────────────────────────

// The disk's asset beside what the node says of it: its tag (its page), its
// health and pool as the CMDB has them, the assets it has been in, and its
// CMDB record. No asset: how one is recorded.
export function DiskAssetPart({ a, serial, node, openRecord }: { a: AssetRow | null; serial: string | null; node: string; openRecord: (name: string) => void }) {
  if (!a) {
    return (
      <>
        <h3>Asset</h3>
        <p className="muted small">
          No asset records this disk{serial ? ` (serial ${serial})` : ""}: on <Link to={assetPath(node)}>{node}'s page</Link>, Adopt the disks the CMDB knows… or Record a disk… records it, with its own page and history.
        </p>
      </>
    );
  }
  const d = a.asDisk;
  return (
    <>
      <h3>Asset</h3>
      <KV
        rows={[
          ["recorded as", <><Link to={assetPath(a.name)}>{a.name}</Link>{a.displayName ? <span className="muted mono"> {a.displayName}</span> : null}</>],
          ["in", a.in ? <>{a.in.asset}{a.in.bay ? <span className="muted"> · bay {a.in.bay}</span> : null}</> : <span className="muted">in no asset</span>],
          ["health", d ? <><i className="st-swatch" style={{ background: DISK_COLOR[d.state] }} /> {healthText(d)}</> : null],
          ["pool", d?.pool ? poolText(d.pool) : null],
        ]}
      />
      <p>
        <button className="hlink" onClick={() => openRecord(a.name)}>CMDB record and trace</button>
      </p>
      <h3>Has been in</h3>
      <DiskPlacements disk={a.name} />
    </>
  );
}
