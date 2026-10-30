// node.d.ts — the Node built-ins cmdb-controller uses beyond what the managers
// need (lib/ts/src/env.d.ts): a socket to PostgreSQL, an HTTP server on a
// Unix socket and on loopback, timers, bytes. The console's trick (ui/src/
// node.d.ts): no @types/node, every type the code touches declared here and
// merged into the lib's ambient modules.

declare function setTimeout(cb: () => void, ms: number): unknown;
declare function clearTimeout(handle: unknown): void;
declare function setInterval(cb: () => void, ms: number): unknown;
declare function clearInterval(handle: unknown): void;

interface NodeBuffer {
  readonly [index: number]: number;
  readInt32BE(offset: number): number;
  readInt16BE(offset: number): number;
  writeInt32BE(value: number, offset: number): number;
  writeInt16BE(value: number, offset: number): number;
  indexOf(value: number, byteOffset?: number): number;
  toString(encoding: string, start: number, end: number): string;
  equals(other: NodeBuffer): boolean;
}

declare const Buffer: {
  from(s: string, encoding?: string): NodeBuffer;
  alloc(n: number): NodeBuffer;
  concat(list: NodeBuffer[]): NodeBuffer;
  byteLength(s: string): number;
};

declare module "net" {
  export interface Socket {
    write(data: NodeBuffer | string): boolean;
    end(): void;
    destroy(): void;
    on(event: "data", cb: (chunk: NodeBuffer) => void): Socket;
    on(event: "error", cb: (e: Error) => void): Socket;
    on(event: "close", cb: () => void): Socket;
    once(event: "connect", cb: () => void): Socket;
    once(event: "error", cb: (e: Error) => void): Socket;
  }
  export function createConnection(path: string): Socket;
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
    flushHeaders(): void;
    write(data: string): boolean;
    end(data?: string): void;
    on(event: "close", cb: () => void): ServerResponse;
  }
  export interface Server {
    listen(path: string, cb?: () => void): Server;
    listen(port: number, host: string, cb?: () => void): Server;
    on(event: "error", cb: (e: Error) => void): Server;
    close(cb?: () => void): void;
    address(): { address: string; port: number } | string | null;
  }
  export function createServer(handler: (req: IncomingMessage, res: ServerResponse) => void): Server;
}

declare module "crypto" {
  export function timingSafeEqual(a: NodeBuffer, b: NodeBuffer): boolean;
}

declare class URLSearchParams {
  get(name: string): string | null;
  getAll(name: string): string[];
  keys(): IterableIterator<string>;
}
declare class URL {
  constructor(input: string, base?: string);
  pathname: string;
  searchParams: URLSearchParams;
}

// A rescan source runs alongside the server: it reports back to it.
declare module "child_process" {
  export interface ChildProcess {
    on(event: "close", cb: (code: number | null) => void): void;
    on(event: "error", cb: (e: Error) => void): void;
  }
}
