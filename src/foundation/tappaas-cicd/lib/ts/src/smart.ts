// smart.ts — a disk's SMART as Proxmox answers it (pvesh /nodes/<n>/disks/smart),
// and the thresholds a disk is judged by. storage-manager's inventory and
// site-manager's sweep read SMART through this parser; health-manager judges a
// disk CI by the same thresholds. Pure.

export interface Smart {
  read: boolean; // false under --no-smart, or when the read failed
  health: "passed" | "failed" | "unknown";
  temperature: number | null; // °C
  reallocated: number | null; // sectors (ATA 5, SCSI grown defects)
  pending: number | null; // sectors (ATA 197)
  uncorrectable: number | null; // sectors (ATA 198) or reported (ATA 187)
  mediaErrors: number | null; // NVMe media and data integrity errors
  criticalWarning: number | null; // NVMe critical warning bits
  powerOnHours: number | null;
}

// The thresholds behind a disk's colour: % of rated life left, and °C by kind.
export const WEAR_WARN = 20;
export const WEAR_FAIL = 10;
export const TEMP_WARN: Record<"hdd" | "ssd" | "nvme" | "unknown", number> = { hdd: 60, ssd: 60, nvme: 70, unknown: 60 };

// The pvesh SMART reply (/nodes/<n>/disks/smart): ATA attributes, or the text
// smartctl prints for NVMe and SCSI.
export function parseSmart(doc: Record<string, unknown> | null): Smart {
  const s: Smart = {
    read: doc !== null,
    health: "unknown",
    temperature: null,
    reallocated: null,
    pending: null,
    uncorrectable: null,
    mediaErrors: null,
    criticalWarning: null,
    powerOnHours: null,
  };
  if (!doc) return s;
  s.health = smartHealth(doc.health);
  const firstInt = (raw: unknown): number | null => {
    const m = /^\s*(\d+)/.exec(String(raw ?? ""));
    return m ? Number(m[1]) : null;
  };
  if (Array.isArray(doc.attributes)) {
    const attr = new Map<number, unknown>();
    for (const a of doc.attributes as Record<string, unknown>[]) attr.set(Number(String(a.id).trim()), a.raw);
    const get = (id: number): number | null => (attr.has(id) ? firstInt(attr.get(id)) : null);
    s.reallocated = get(5);
    s.pending = get(197);
    s.uncorrectable = get(198) ?? get(187);
    // Some SSDs report 0 in attribute 194: no sensor, not a cold disk.
    s.temperature = get(194) || get(190) || null;
    s.powerOnHours = get(9);
  }
  const text = typeof doc.text === "string" ? doc.text : "";
  if (text) {
    const field = (re: RegExp): number | null => {
      const m = re.exec(text);
      return m ? Number(m[1].replace(/,/g, "")) : null;
    };
    s.temperature ??= field(/^Temperature:\s+(\d+) Celsius/m) ?? field(/^Current Drive Temperature:\s+(\d+) C/m);
    s.mediaErrors = field(/^Media and Data Integrity Errors:\s+([\d,]+)/m);
    const cw = /^Critical Warning:\s+(0x[0-9a-fA-F]+)/m.exec(text);
    s.criticalWarning = cw ? parseInt(cw[1], 16) : null;
    s.powerOnHours ??= field(/^Power On Hours:\s+([\d,]+)/m) ?? field(/^\s*Accumulated power on time, hours:minutes\s+([\d,]+)/m);
    s.reallocated ??= field(/^Elements in grown defect list:\s+([\d,]+)/m);
  }
  return s;
}

export function smartHealth(v: unknown): Smart["health"] {
  const h = String(v ?? "").toUpperCase();
  if (h === "PASSED" || h === "OK") return "passed";
  if (h === "FAILED" || h.startsWith("FAIL")) return "failed";
  return "unknown";
}

