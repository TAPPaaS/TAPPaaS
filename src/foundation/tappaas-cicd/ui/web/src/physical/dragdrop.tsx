// dragdrop.tsx — dragging a device in the Physical view (pointer events, so
// the same gesture works from the Unplaced tray's list and from a plate in the
// SVG drawing): a press on a tray entry or a plate, a move of a few pixels
// starts the drag; the rack drawing (rack.tsx) turns the pointer into a target
// and highlights it (dragplace.ts says whether it takes the device); a release
// on a valid target runs the place or place-modify job (the check, then the
// apply, as one job), whose state and output the dragged device's side panel
// shows. Escape or a release elsewhere drops nothing. The Place… and Change
// placement… dialogs stay for the keyboard.

import { MutableRefObject, PointerEvent as ReactPointerEvent, useCallback, useEffect, useRef, useState } from "react";
import { applyNowJob } from "../api";
import { Command, JobOutput, JobStatusLine } from "../jobs";
import { Job } from "../types";
import { Drop, Dragged } from "./dragplace";

export interface DragState {
  d: Dragged;
  grab: number; // the row of the device the pointer holds it by (0: its top)
  x: number; // the pointer, in client pixels
  y: number;
}

// A drop's job: the device, where it was dropped, what it ran, the job (or why
// it did not start). closed: its card is closed; the job is still watched.
export interface DropJob {
  device: string;
  d: Dragged;
  drop: Drop;
  closed?: boolean;
  what: string;
  argv: string[];
  id: string | null;
  error: string | null;
}

const THRESHOLD = 5;

export function useDragPlace(onDrop: (d: Dragged, drop: Drop) => void): {
  drag: DragState | null;
  dropRef: MutableRefObject<Drop | null>;
  begin: (e: ReactPointerEvent, d: Dragged, grab: number) => void;
} {
  const [drag, setDrag] = useState<DragState | null>(null);
  const dropRef = useRef<Drop | null>(null);
  const cleanup = useRef<(() => void) | null>(null);
  const dropCb = useRef(onDrop);
  dropCb.current = onDrop;
  useEffect(() => () => cleanup.current?.(), []);

  const begin = useCallback((e: ReactPointerEvent, d: Dragged, grab: number) => {
    if (e.button !== 0 || e.ctrlKey || e.metaKey) return;
    cleanup.current?.();
    const x0 = e.clientX;
    const y0 = e.clientY;
    let active = false;
    dropRef.current = null;
    const move = (ev: PointerEvent) => {
      if (!active && Math.hypot(ev.clientX - x0, ev.clientY - y0) < THRESHOLD) return;
      if (!active) {
        active = true;
        document.body.classList.add("dragging-place");
        window.getSelection()?.removeAllRanges();
      }
      ev.preventDefault();
      setDrag({ d, grab, x: ev.clientX, y: ev.clientY });
    };
    // The click that ends a drag selects nothing and clears no selection.
    const swallow = (ev: MouseEvent) => {
      ev.stopPropagation();
      ev.preventDefault();
    };
    const end = (drop: boolean) => {
      const was = active;
      const target = dropRef.current;
      stop();
      if (!was) return;
      window.addEventListener("click", swallow, { capture: true, once: true });
      setTimeout(() => window.removeEventListener("click", swallow, { capture: true }), 0);
      if (drop && target?.ok) dropCb.current(d, target);
    };
    const up = () => end(true);
    const cancel = () => end(false);
    const key = (ev: KeyboardEvent) => {
      if (ev.key === "Escape") end(false);
    };
    const stop = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", cancel);
      window.removeEventListener("keydown", key);
      document.body.classList.remove("dragging-place");
      dropRef.current = null;
      cleanup.current = null;
      setDrag(null);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", cancel);
    window.addEventListener("keydown", key);
    cleanup.current = stop;
  }, []);

  return { drag, dropRef, begin };
}

// The dragged device beside the pointer, with what a release there does.
export function DragGhost({ drag, drop }: { drag: DragState; drop: Drop | null }) {
  const cls = drop?.ok ? "drag-ghost drag-ok" : drop && !drop.same ? "drag-ghost drag-bad" : "drag-ghost";
  return (
    <div className={cls} style={{ left: drag.x + 14, top: drag.y + 12 }} aria-hidden>
      <b>{drag.d.device}</b> <span className="muted">{drag.d.height}U{drag.d.width !== "full" ? ` ${drag.d.width}` : ""}</span>
      <div className="small">{drop ? drop.text : "onto a rack's units or into a room"}</div>
    </div>
  );
}

// A drop as it starts: no job yet.
export const dropJobOf = (d: Dragged, drop: Drop): DropJob => ({ device: d.device, d, drop, what: `${d.from ? "Move" : "Place"} ${d.device}: ${drop.text}`, argv: drop.argv ?? [], id: null, error: null });

// Run a valid drop: one job, the check, then the apply.
export async function runDrop(d: Dragged, drop: Drop): Promise<DropJob> {
  const job = dropJobOf(d, drop);
  const r = await applyNowJob(job.argv);
  if (!r.data || r.status >= 400) return { ...job, error: r.error ?? `HTTP ${r.status}` };
  return { ...job, id: r.data.id, error: r.error };
}

// The drop's job in the dragged device's side panel: its status line, its
// output as it arrives. j: the job as the page watches it, so the positions
// are read again when it ends whatever the side panel shows by then.
export function DropJobPanel({ job, j, close }: { job: DropJob; j: Job | null; close: () => void }) {
  return (
    <div className="drop-job">
      <div className="drop-job-head">
        <b className="small">{job.what}</b>
        <button className="btn-x" onClick={close} aria-label="close">×</button>
      </div>
      <Command argv={j?.ran ?? job.argv} />
      {job.error && !job.id ? <p className="readstate readstate-fail">{job.error}</p> : null}
      {job.id ? (
        j ? (
          <>
            <JobStatusLine job={j} label="The job" />
            {j.refused ? <p className="readstate readstate-fail">{j.refused}</p> : null}
            <JobOutput job={j} />
          </>
        ) : (
          <p className="muted small">starting the job…</p>
        )
      ) : !job.error ? (
        <p className="muted small">starting the job…</p>
      ) : null}
    </div>
  );
}
