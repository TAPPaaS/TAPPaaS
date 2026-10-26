// node.d.ts — the Node built-ins the console backend uses beyond what the
// managers need (lib/ts/src/env.d.ts): an HTTP server, asynchronous children,
// timers, crypto and the interface list. Same zero-dependency trick: no
// @types/node, every type the code touches declared here and merged into the
// lib's ambient modules.

declare function setTimeout(cb: () => void, ms: number): unknown;
declare function clearTimeout(handle: unknown): void;
declare function setInterval(cb: () => void, ms: number): unknown;
declare function clearInterval(handle: unknown): void;

declare const Buffer: {
  from(s: string, encoding?: string): NodeBuffer;
  from(bytes: number[]): NodeBuffer;
  alloc(n: number): NodeBuffer;
  concat(list: NodeBuffer[]): NodeBuffer;
  byteLength(s: string): number;
};

// Node 22's fetch: LiteLLM's API (litellm.ts) and Loki's (assistant-tools.ts).
interface FetchResponse {
  ok: boolean;
  status: number;
  text(): Promise<string>;
  json(): Promise<unknown>;
  body: AsyncIterable<Uint8Array> | null;
}
interface AbortSignal {
  readonly aborted: boolean;
  addEventListener(type: "abort", cb: () => void): void;
}
declare const AbortSignal: { timeout(ms: number): AbortSignal; any(signals: AbortSignal[]): AbortSignal };
declare class AbortController {
  readonly signal: AbortSignal;
  abort(): void;
}
declare function fetch(url: string, init?: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal }): Promise<FetchResponse>;
declare class TextDecoder {
  decode(input?: Uint8Array, opts?: { stream?: boolean }): string;
}

declare class URLSearchParams {
  get(name: string): string | null;
}
declare class URL {
  constructor(input: string, base?: string);
  pathname: string;
  searchParams: URLSearchParams;
}

declare module "http" {
  export interface Socket {
    remoteAddress?: string;
    destroy(): void;
  }
  export interface IncomingMessage {
    method?: string;
    url?: string;
    headers: Record<string, string | string[] | undefined>;
    socket: Socket;
    on(event: "data", cb: (chunk: NodeBuffer) => void): IncomingMessage;
    on(event: "end" | "close", cb: () => void): IncomingMessage;
    on(event: "error", cb: (e: Error) => void): IncomingMessage;
  }
  export interface ServerResponse {
    statusCode: number;
    headersSent: boolean;
    setHeader(name: string, value: string | number | string[]): void;
    write(data: string): boolean;
    end(data?: string | NodeBuffer): void;
    on(event: "close", cb: () => void): ServerResponse;
  }
  export interface Server {
    listen(port: number, host: string, cb?: () => void): Server;
    on(event: "connection", cb: (s: Socket) => void): Server;
    on(event: "error", cb: (e: Error) => void): Server;
    close(cb?: () => void): void;
    address(): { address: string; port: number } | string | null;
  }
  export function createServer(handler: (req: IncomingMessage, res: ServerResponse) => void): Server;
}

// A module's icon (icons.ts): its bytes, compared by content.
interface NodeBuffer {
  equals(other: NodeBuffer): boolean;
}

declare module "fs" {
  export function appendFileSync(path: string, data: string, encoding?: "utf8"): void;
  export function realpathSync(path: string): string;
  export function symlinkSync(target: string, path: string): void;
  export function writeFileSync(path: string, data: NodeBuffer): void;
  export function writeFileSync(path: string, data: string, options: { encoding?: "utf8"; mode?: number }): void;
}

declare module "path" {
  export function extname(p: string): string;
  export function isAbsolute(p: string): boolean;
  export const sep: string;
}

declare module "crypto" {
  export function timingSafeEqual(a: NodeBuffer, b: NodeBuffer): boolean;
  export function randomBytes(n: number): NodeBuffer;
  export function createHash(alg: string): { update(s: string): { digest(enc: "hex"): string } };
  export function createHmac(alg: string, key: string): { update(s: string): { digest(): NodeBuffer } };
}

declare module "os" {
  export function networkInterfaces(): Record<string, { address: string; family: string | number; internal: boolean }[] | undefined>;
}

declare module "dns" {
  export function lookup(host: string, opts: { family: number }, cb: (err: Error | null, address: string) => void): void;
}

declare module "child_process" {
  export interface ChildStream {
    on(event: "data", cb: (chunk: NodeBuffer) => void): void;
  }
  // A child's stdin: written once and closed (run.ts runWithStdin).
  export interface ChildInput {
    end(data?: string): void;
    on(event: "error", cb: (e: Error) => void): void;
  }
  export interface ChildProcess {
    stdin: ChildInput | null;
    stdout: ChildStream | null;
    stderr: ChildStream | null;
    on(event: "close", cb: (code: number | null) => void): void;
    on(event: "error", cb: (e: Error) => void): void;
  }
}
