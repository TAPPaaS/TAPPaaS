// healthlive.ts — the graph read's freshness and the Health view's live feed
// (ADR-041 D5). The read is cached until the CMDB's change stream says
// something changed; a burst of reports (a sweep) is one read again. What moved
// is fanned out the way a job's output is: server-sent events (server.ts
// health/stream). While the stream is down the cache falls back on a timer, so
// a site whose CMDB comes and goes is at worst minutes behind.

import { Cached, Entry } from "./cache";
import { CmdbChange } from "./cmdb";
import { HealthGraph, HealthPatch, diffHealth } from "./health";

export const FALLBACK_MS = 5 * 60_000;

export interface ChangeFeed {
  subscribe(onChange: (c: CmdbChange) => void, onLink: (up: boolean) => void): () => void;
}

export class HealthLive {
  private readonly subs = new Set<(p: HealthPatch) => void>();
  private stopFeed: (() => void) | null = null;
  private timer: unknown = null;
  private again = false;
  private running = false;
  private shown: HealthGraph | null = null;
  linked = false;

  constructor(
    private readonly graph: Cached<HealthGraph>,
    private readonly feed: ChangeFeed | null,
    private readonly log: (line: string) => void = () => undefined,
    private readonly debounceMs = 1000,
    private readonly now: () => number = Date.now,
  ) {}

  start(): void {
    if (!this.feed || this.stopFeed) return;
    this.stopFeed = this.feed.subscribe(
      () => this.changed(),
      (up) => {
        this.linked = up;
        // What passed while away is unknown: read again.
        if (up) this.changed();
      },
    );
  }

  stop(): void {
    this.stopFeed?.();
    this.stopFeed = null;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }

  // The answer for a page: the cache, read again only when no stream keeps it.
  async read(): Promise<Entry<HealthGraph>> {
    const e = this.graph.peek();
    if (!this.linked && e.at !== null && this.now() - e.at >= FALLBACK_MS) void this.settle();
    return this.graph.get();
  }

  // Something changed: read again once the burst has passed.
  changed(): void {
    if (this.timer !== null) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.settle();
    }, this.debounceMs);
  }

  // One read at a time; a change during a read means one more after it.
  async settle(): Promise<void> {
    if (this.running) {
      this.again = true;
      return;
    }
    this.running = true;
    do {
      this.again = false;
      await this.graph.refreshAfterChange();
      const e = this.graph.peek();
      if (e.value) {
        const patch = diffHealth(this.shown, e.value);
        this.shown = e.value;
        if (patch) this.tell(patch);
      } else if (e.error) this.log(`health graph: ${e.error}`);
    } while (this.again);
    this.running = false;
  }

  private tell(p: HealthPatch): void {
    for (const cb of this.subs) cb(p);
  }

  subscribe(cb: (p: HealthPatch) => void): () => void {
    this.subs.add(cb);
    return () => {
      this.subs.delete(cb);
    };
  }
}
