// cache.ts — the console's read cache (ADR-034 D1). Each read has its own timer
// (health every 10 minutes, the module list and the topology every 5, drift on
// demand); a page is served from the last answer, never by waiting on a verb
// that has already answered once. A failed refresh keeps the last good value
// and says so. The cache holds what the managers said and nothing else.

export interface Entry<T> {
  value: T | null;
  at: number | null; // ms epoch of the value
  error: string | null; // the last refresh's failure, if it failed
  loading: boolean;
}

export class Cached<T> {
  private entry: Entry<T> = { value: null, at: null, error: null, loading: false };
  private inflight: Promise<void> | null = null;
  private timer: unknown = null;

  constructor(
    readonly name: string,
    readonly ttlMs: number, // 0: on demand only
    private readonly load: () => Promise<T>,
    private readonly now: () => number = Date.now,
  ) {}

  // Refresh now (coalesced: a refresh already running is the one awaited).
  refresh(): Promise<void> {
    if (this.inflight) return this.inflight;
    this.entry = { ...this.entry, loading: true };
    this.inflight = this.load()
      .then((v) => {
        this.entry = { value: v, at: this.now(), error: null, loading: false };
      })
      .catch((e: unknown) => {
        this.entry = { ...this.entry, error: e instanceof Error ? e.message : String(e), loading: false };
      })
      .then(() => {
        this.inflight = null;
      });
    return this.inflight;
  }

  // The current answer. The first call waits for the first load; afterwards a
  // stale value is served while the refresh runs behind it.
  async get(): Promise<Entry<T>> {
    if (this.entry.at === null && this.entry.error === null) await this.refresh();
    else if (this.stale()) void this.refresh();
    return { ...this.entry };
  }

  peek(): Entry<T> {
    return { ...this.entry };
  }

  stale(): boolean {
    if (this.entry.at === null) return true;
    return this.ttlMs > 0 && this.now() - this.entry.at >= this.ttlMs;
  }

  // The per-read timer: refresh every ttl, so the next page is already current.
  start(): void {
    if (this.ttlMs <= 0 || this.timer !== null) return;
    this.timer = setInterval(() => void this.refresh(), this.ttlMs);
  }

  stop(): void {
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
  }
}

// Per-key caches (a module's show, resolve, drift): made on first use.
export class CachedMap<T> {
  private readonly map = new Map<string, Cached<T>>();
  constructor(
    readonly name: string,
    readonly ttlMs: number,
    private readonly load: (key: string) => Promise<T>,
    private readonly now: () => number = Date.now,
  ) {}
  of(key: string): Cached<T> {
    let c = this.map.get(key);
    if (!c) {
      c = new Cached<T>(`${this.name}:${key}`, this.ttlMs, () => this.load(key), this.now);
      this.map.set(key, c);
    }
    return c;
  }
  clear(): void {
    this.map.clear();
  }
}

// The envelope every read answers in: the data, how old it is, and whether the
// last attempt to refresh it failed.
export function envelope<T>(e: Entry<T>, now: number = Date.now()): Record<string, unknown> {
  return {
    data: e.value,
    at: e.at === null ? null : new Date(e.at).toISOString(),
    ageSeconds: e.at === null ? null : Math.round((now - e.at) / 1000),
    refreshing: e.loading,
    error: e.error,
  };
}
