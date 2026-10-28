// usbsticks.tsx — a USB stick in a cluster node, picked for writing: the node
// (the mothership is a VM and sees no USB port), then the sticks site-manager
// node usb lists in it, read again every few seconds while the picker is open
// so a stick just inserted shows up. A stick in use (mounted, in a pool) is
// shown but cannot be picked. Used by the backup-key stick (Day 2) and the
// installer stick (Add a node, stage 0).

import { useEffect } from "react";
import { useRead } from "./api";
import { Dot } from "./ui";

export interface UsbStick {
  device: string;
  size: number;
  vendor: string | null;
  model: string | null;
  serial: string | null;
  inUse: boolean;
  why: string | null;
  keyStick: boolean;
}
export interface NodeUsb {
  node: string;
  reachable: boolean;
  sticks: UsbStick[];
}

export const gb = (bytes: number): string => `${(bytes / 1e9).toFixed(1)} GB`;

// A stick, in words: /dev/sdb · 31.0 GB · SanDisk Ultra (key stick).
export function stickText(s: UsbStick): string {
  const name = [s.vendor, s.model].filter(Boolean).join(" ");
  if (s.size === 0) return `${s.device}${name ? ` · ${name}` : ""} · ejected: unplug it and plug it in again`;
  return `${s.device} · ${gb(s.size)}${name ? ` · ${name}` : ""}${s.keyStick ? " · a TAPPaaS key stick" : ""}${s.inUse ? ` · in use (${s.why ?? "mounted"})` : ""}`;
}

export function UsbStickPicker({ nodes, node, setNode, device, setDevice, disabled, onSticks }: {
  nodes: string[];
  node: string;
  setNode: (n: string) => void;
  device: string;
  setDevice: (d: string) => void;
  disabled?: boolean;
  onSticks?: (sticks: UsbStick[]) => void;
}) {
  const read = useRead<NodeUsb>(node ? `nodes/${encodeURIComponent(node)}/usb` : null, disabled ? 600_000 : 5_000);
  const usb = read.env?.data ?? null;
  const sticks = usb?.sticks ?? [];
  useEffect(() => {
    onSticks?.(sticks);
    // The picked stick is gone (pulled out): forget it.
    if (device && !sticks.some((s) => s.device === device)) setDevice("");
  }, [usb]);
  return (
    <>
      <label className="form-row">
        <span>node *</span>
        <select value={node} disabled={disabled} onChange={(e) => { setNode(e.target.value); setDevice(""); }}>
          {nodes.map((n) => (
            <option key={n} value={n}>{n}</option>
          ))}
        </select>
        <small className="muted">The node the stick is plugged into: the mothership is a VM and has no USB port.</small>
      </label>
      <label className="form-row">
        <span>USB stick *</span>
        <select value={device} disabled={disabled || !sticks.length} onChange={(e) => setDevice(e.target.value)}>
          <option value="">{sticks.length ? "— pick one" : `— no USB stick in ${node || "the node"}`}</option>
          {sticks.map((s) => (
            <option key={s.device} value={s.device} disabled={s.inUse}>{stickText(s)}</option>
          ))}
        </select>
        <small className="muted">
          {read.env?.error || read.failure ? <><Dot level="fail" /> site-manager node usb could not be read: {read.env?.error ?? read.failure} </> : usb && !usb.reachable ? <><Dot level="fail" /> {node} is not reachable. </> : null}
          Insert the stick into {node || "the node"}; the list is read again every few seconds{read.loading ? " (reading…)" : ""}. A stick in use is listed but cannot be written.
        </small>
      </label>
    </>
  );
}
