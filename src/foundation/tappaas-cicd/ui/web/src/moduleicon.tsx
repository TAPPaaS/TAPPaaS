// moduleicon.tsx — a module's icon (GET /api/v1/modules/<name>/icon: the file
// its config declares or the icon.svg / icon.png of its module directory),
// else a tile with its initial in a colour taken from its name.

import { useState } from "react";

const TILE = ["#3b6fd4", "#7c3aed", "#0891b2", "#be185d", "#4d7c0f", "#b45309", "#1d4ed8", "#0f766e"];

function tileColor(name: string): string {
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return TILE[h % TILE.length];
}

export function ModuleIcon({ name, size = 40 }: { name: string; size?: number }) {
  const [none, setNone] = useState(false);
  if (none) {
    return (
      <span className="micon micon-tile" style={{ width: size, height: size, background: tileColor(name), fontSize: size * 0.48 }} aria-hidden>
        {name.charAt(0).toUpperCase()}
      </span>
    );
  }
  return <img className="micon" src={`/api/v1/modules/${encodeURIComponent(name)}/icon`} width={size} height={size} alt="" onError={() => setNone(true)} />;
}

// An object that is no module: a tile for its class, by the same rule.
const CLASS_LETTER: Record<string, string> = { machine: "M", vm: "V", lxc: "C", device: "D", site: "◆", environment: "E", cluster: "◎", zone: "Z", datastore: "B", "storage-pool": "P", port: "·", disk: "◍", user: "U", group: "G" };

export function ClassIcon({ cls, size = 22 }: { cls: string; size?: number }) {
  return (
    <span className="micon micon-tile" style={{ width: size, height: size, background: tileColor(cls), fontSize: size * 0.52 }} title={cls} aria-hidden>
      {CLASS_LETTER[cls] ?? cls.charAt(0).toUpperCase()}
    </span>
  );
}
