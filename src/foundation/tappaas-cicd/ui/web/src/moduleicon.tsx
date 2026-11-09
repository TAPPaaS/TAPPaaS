// moduleicon.tsx — a module's icon (GET /api/v1/modules/<name>/icon: the file
// its config declares or the icon.svg / icon.png of its module directory),
// else a tile; and an object's class tile (classsymbol.ts: its symbol on its
// family's colour, its class in the operator's words as the label).

import { useState } from "react";
import { FAMILY_COLOR, classSymbol } from "./classsymbol";

const TILE = ["var(--accent)", "var(--violet-600)", "var(--cyan-600)", "var(--pink-700)", "var(--lime-700)", "var(--amber-700)", "var(--blue-700)", "var(--teal-700)"];

function tileColor(name: string): string {
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return TILE[h % TILE.length];
}

// A module without an icon of its own: the class tile of the object it is
// (cls), else its initial in a colour taken from its name.
export function ModuleIcon({ name, cls, size = 40 }: { name: string; cls?: string; size?: number }) {
  const [none, setNone] = useState(false);
  if (none) {
    if (cls) return <ClassIcon cls={cls} size={size} />;
    return (
      <span className="micon micon-tile" style={{ width: size, height: size, background: tileColor(name), fontSize: size * 0.48 }} aria-hidden>
        {name.charAt(0).toUpperCase()}
      </span>
    );
  }
  return <img className="micon" src={`/api/v1/modules/${encodeURIComponent(name)}/icon`} width={size} height={size} alt="" onError={() => setNone(true)} />;
}

// An object that is no module, or a module without an icon: its class's tile.
export function ClassIcon({ cls, size = 22 }: { cls: string; size?: number }) {
  const s = classSymbol(cls);
  return (
    <span className="micon micon-tile" style={{ width: size, height: size, background: FAMILY_COLOR[s.family], fontSize: size * 0.74, borderRadius: Math.max(3, Math.round(size * 0.22)) }} title={s.word} role="img" aria-label={s.word}>
      {s.symbol}
    </span>
  );
}
