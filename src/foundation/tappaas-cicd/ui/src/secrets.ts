// secrets.ts — the secrets the Setup wizard takes (ADR-034 D10, spike §5.12):
// written where the scripts already read them, in their own format, mode 0600,
// and never shown again — the console answers which keys are set, not their
// values. Only these declared files; nothing else under the home directory.
//
//   acme-dns   ~/.acme-dns-credentials.txt   provider=<p>, dns_<key>=<value>   (acme-setup.sh)
//   unifi      ~/.unifi-os-credentials.txt   url=, username=, password=       (the UniFi plugin)
//   wlan       ~/.wlan-secrets.txt           <SSID>=<passphrase>, merged by SSID (ap-manager)

import { chmodSync, existsSync, readFileSync, renameSync, statSync, writeFileSync } from "fs";
import { join } from "path";

export type SecretName = "acme-dns" | "unifi" | "wlan";

interface SecretSpec {
  file: string; // under the home directory
  what: string;
  // The lines to write from the posted fields, given what the file holds now;
  // an error when the fields are not what the script reads.
  lines: (fields: Record<string, unknown>, current: Map<string, string>) => Map<string, string> | string;
}

const str = (v: unknown): string | null => (typeof v === "string" && v.length > 0 && v.length <= 4096 && !/[\r\n\u0000]/.test(v) ? v : null);

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
      if (!pass || pass.length < 8 || pass.length > 63) return "passphrase: 8 to 63 characters (WPA)";
      const out = new Map(current);
      out.set(ssid, pass);
      return out;
    },
  },
};

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
