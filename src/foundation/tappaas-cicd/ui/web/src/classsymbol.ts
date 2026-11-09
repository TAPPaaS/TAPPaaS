// classsymbol.ts — a CMDB class as the console draws it: its symbol, family and
// label come from the metamodel (classsymbol.gen.ts, written by the cmdb
// controller's metamodel/gen-symbols.mjs); the family's colour is the console's.
// moduleicon.tsx draws it; nothing else picks a symbol.

import { CLASSES, Family } from "./classsymbol.gen";

export type { Family };

// Drawing palette tokens only (.interface-design/system.md, Drawing palette).
export const FAMILY_COLOR: Record<Family, string> = {
  compute: "var(--blue-700)",
  assets: "var(--orange-700)",
  network: "var(--teal-700)",
  storage: "var(--amber-700)",
  software: "var(--violet-600)",
  identity: "var(--pink-700)",
  places: "var(--lime-700)",
  collections: "var(--cyan-600)",
  other: "var(--slate-500)",
};

export interface ClassSymbol {
  symbol: string;
  family: Family;
  word: string;
}

const S = (symbol: string, family: Family, word: string): ClassSymbol => ({ symbol, family, word });

export const CLASS_SYMBOL: Record<string, ClassSymbol> = Object.fromEntries(Object.entries(CLASSES).map(([k, c]) => [k, S(c.symbol, c.family, c.label)]));

// A class the table does not know yet: its first letter on the neutral tile.
export function classSymbol(cls: string): ClassSymbol {
  return CLASS_SYMBOL[cls] ?? S(cls.charAt(0).toUpperCase() || "?", "other", cls);
}

// An asset's kind (the asset record's) as its CMDB class.
const KIND_CLASS: Record<string, string> = { server: "server", switch: "network-device", "access-point": "network-device", modem: "appliance", ont: "appliance", ups: "appliance", "patch-panel": "passive-device", pdu: "passive-device", other: "other-device", disk: "disk" };
export const assetClassOf = (kind: string): string => KIND_CLASS[kind] ?? "asset";
