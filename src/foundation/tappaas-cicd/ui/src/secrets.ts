// secrets.ts — the secrets the Setup wizard takes (ADR-034 D10, spike §5.12):
// written where the scripts already read them, in their own format, mode 0600,
// and never shown again — the console answers which keys are set, not their
// values. Only these declared files; nothing else under the home directory.
//
//   acme-dns   ~/.acme-dns-credentials.txt   provider=<p>, dns_<key>=<value>   (acme-setup.sh)
//   unifi      ~/.unifi-os-credentials.txt   url=, username=, password=       (the UniFi plugin)
//   wlan       ~/.wlan-secrets.txt           <SSID>=<passphrase>, one per SSID — written by
//                                            `ap-manager ssid set-passphrase <ssid>` with the
//                                            passphrase on stdin, which also marks the SSID so
//                                            the next reconcile pushes it (#889)
//   backup-keys  (no file)                   the password of the backup-key USB stick, handed
//                                            to `backup-manager key export --usb --node N
//                                            --device D --yes --password-stdin` on stdin: the
//                                            stick is the keys' copy that leaves the building

import { chmodSync, existsSync, readFileSync, renameSync, statSync, writeFileSync } from "fs";
import { join } from "path";

export type SecretName = "acme-dns" | "unifi" | "wlan" | "backup-keys" | "user-password";

interface SecretSpec {
  file: string | null; // under the home directory; null: nothing is kept on the mothership
  what: string;
  // The lines to write from the posted fields, given what the file holds now;
  // an error when the fields are not what the script reads.
  lines: (fields: Record<string, unknown>, current: Map<string, string>) => Map<string, string> | string;
  // Set by its owner's verb instead of written here: the argv (never the
  // secret), the secret on stdin, and the keys it sets.
  command?: (fields: Record<string, unknown>) => SecretCommand | string;
}

export interface SecretCommand {
  bin: string;
  args: string[];
  input: string;
  keys: string[];
  timeoutMs?: number; // a verb that formats and verifies a stick takes minutes
  where?: string; // what holds the secret when it is no file of the mothership's
}

const str = (v: unknown): string | null => (typeof v === "string" && v.length > 0 && v.length <= 4096 && !/[\r\n\u0000]/.test(v) ? v : null);

// The password of a backup-key stick (keys-to-usb.sh): 12 characters or more,
// one line. The console never keeps it: the stick and the password apart.
const DEVICE = /^\/dev\/[a-z][a-z0-9]{1,30}$/;
const NODE = /^[A-Za-z0-9_][A-Za-z0-9_-]{0,62}$/;
export const SECRETS: Record<SecretName, SecretSpec> = {
  "acme-dns": {
    file: ".acme-dns-credentials.txt",
    what: "the DNS provider's API credential acme-setup.sh reads for the wildcard certificate",
    lines: (f) => {
      const provider = str(f.provider);
      if (!provider || !/^[a-z0-9_]+$/.test(provider)) return "provider: the acme.sh DNS provider, e.g. cloudflare or gandi_livedns";
      const out = new Map([["provider", provider]]);
      const keys = (f.keys ?? {}) as Record<string, unknown>;
      for (const [k, v] of Object.entries(keys)) {
        if (!/^dns_[a-z0-9_]+$/i.test(k)) return `${k}: the provider's keys are named dns_… (acme.sh's names, e.g. dns_cf_token)`;
        const s = str(v);
        if (!s) return `${k}: a value is required`;
        out.set(k, s);
      }
      if (out.size < 2) return "at least one dns_… key";
      return out;
    },
  },
  unifi: {
    file: ".unifi-os-credentials.txt",
    what: "a local UniFi OS admin (no SSO, no MFA) the switch and AP plugins log in with",
    lines: (f) => {
      const url = str(f.url);
      const username = str(f.username);
      const password = str(f.password);
      if (!url || !/^https?:\/\//.test(url)) return "url: https://<controller>[:port]";
      if (!username || !password) return "username and password of a local UniFi OS admin";
      return new Map([["url", url], ["username", username], ["password", password]]);
    },
  },
  wlan: {
    file: ".wlan-secrets.txt",
    what: "WPA passphrases by SSID, which the AP plugin programs",
    lines: (f, current) => {
      const ssid = str(f.ssid);
      const pass = str(f.passphrase);
      if (!ssid || ssid.includes("=")) return "ssid: the SSID's name (no '=')";
      if (!pass || pass.length < 8 || pass.length > 63 || !/^[\x20-\x7e]+$/.test(pass)) return "passphrase: 8 to 63 printable characters (WPA)";
      const out = new Map(current);
      out.set(ssid, pass);
      return out;
    },
    // ap-manager owns the SSIDs: it stores the passphrase and marks the SSID.
    command: (f) => {
      const ok = SECRETS.wlan.lines(f, new Map());
      if (typeof ok === "string") return ok;
      const ssid = str(f.ssid) as string;
      return { bin: "ap-manager", args: ["ssid", "set-passphrase", ssid], input: `${str(f.passphrase)}\n`, keys: [ssid] };
    },
  },
  "backup-keys": {
    file: null,
    what: "the backup encryption keys, encrypted onto a USB stick in a node (backup-manager key export --usb)",
    lines: () => "backup-keys: written to a stick by backup-manager, never to a file here",
    command: (f) => {
      const node = str(f.node);
      const device = str(f.device);
      const password = str(f.password);
      if (!node || !NODE.test(node)) return "node: the node holding the stick";
      if (!device || !DEVICE.test(device)) return "device: the stick as site-manager node usb lists it (/dev/sdX)";
      if (!password || password.length < 12 || password.length > 1024 || !/^[\x20-\x7e]+$/.test(password)) return "password: 12 to 1024 printable characters";
      return {
        bin: "backup-manager",
        args: ["key", "export", "--usb", "--node", node, "--device", device, "--yes", "--password-stdin", ...(f.format === true ? ["--format"] : [])],
        input: `${password}\n`,
        keys: [`${node}:${device}`],
        timeoutMs: 10 * 60_000,
        where: `the USB stick ${device} in ${node}`,
      };
    },
  },
  "user-password": {
    file: null,
    what: "a user's new password, set in Authentik (identity-manager user reset-password --password-stdin)",
    lines: () => "user-password: set in Authentik by identity-manager, never kept here",
    command: (f) => {
      const user = str(f.user);
      const password = str(f.password);
      if (!user || !USER_NAME.test(user)) return "user: the user, as identity-manager lists them";
      if (!password || password.length < 8 || password.length > 1024 || !/^[\x20-\x7e]+$/.test(password)) return "password: 8 to 1024 printable characters";
      return {
        bin: "identity-manager",
        args: ["user", "reset-password", user, "--password-stdin"],
        input: `${password}\n`,
        keys: [user],
        where: `Authentik, for ${user}`,
      };
    },
  },
};

// A user name as identity-manager spells one (a local part, or a short handle).
const USER_NAME = /^[a-z0-9][a-z0-9._-]{0,62}$/i;

export function isSecretName(n: string): n is SecretName {
  return Object.prototype.hasOwnProperty.call(SECRETS, n);
}

// The file as key=value lines (split on the first '='), comments and blanks dropped.
export function parseKv(text: string): Map<string, string> {
  const m = new Map<string, string>();
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("=");
    if (i > 0) m.set(t.slice(0, i).trim(), t.slice(i + 1));
  }
  return m;
}

export interface SecretStatus {
  name: SecretName;
  file: string;
  what: string;
  present: boolean;
  keys: string[]; // the keys (or SSIDs) set — never a value
  modified: string | null;
}

export function secretStatus(home: string, name: SecretName): SecretStatus {
  const spec = SECRETS[name];
  if (spec.file === null) return { name, file: "", what: spec.what, present: false, keys: [], modified: null };
  const f = join(home, spec.file);
  if (!existsSync(f)) return { name, file: f, what: spec.what, present: false, keys: [], modified: null };
  let keys: string[] = [];
  try {
    keys = [...parseKv(readFileSync(f, "utf8")).keys()];
  } catch {
    keys = [];
  }
  let modified: string | null = null;
  try {
    modified = new Date(statSync(f).mtimeMs).toISOString();
  } catch {
    modified = null;
  }
  return { name, file: f, what: spec.what, present: true, keys, modified };
}

// Write the secret; returns the keys written, or an error for the form.
export function writeSecret(home: string, name: SecretName, fields: Record<string, unknown>): { ok: true; keys: string[]; file: string } | { ok: false; error: string } {
  const spec = SECRETS[name];
  if (spec.command || spec.file === null) return { ok: false, error: `${name} is set through its owner's verb (secretCommand), not written here` };
  const f = join(home, spec.file);
  let current = new Map<string, string>();
  try {
    if (existsSync(f)) current = parseKv(readFileSync(f, "utf8"));
  } catch {
    current = new Map();
  }
  const lines = spec.lines(fields, current);
  if (typeof lines === "string") return { ok: false, error: lines };
  const body = [...lines.entries()].map(([k, v]) => `${k}=${v}`).join("\n") + "\n";
  const tmp = `${f}.console-tmp`;
  writeFileSync(tmp, body, { encoding: "utf8", mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, f);
  return { ok: true, keys: [...lines.keys()], file: f };
}

// The verb that sets a secret its owner keeps (wlan: ap-manager), or null when
// the console writes the file itself; an error for the form.
export function secretCommand(name: SecretName, fields: Record<string, unknown>): SecretCommand | string | null {
  const spec = SECRETS[name];
  return spec.command ? spec.command(fields) : null;
}
