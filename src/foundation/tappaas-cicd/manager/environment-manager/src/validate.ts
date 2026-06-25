// validate.ts — the `environment validate` verb.
//
// Thin wrapper over validate-environment.sh — the CANONICAL schema gate (one
// source of truth, zero TS dependency). validate-environment.sh runs full
// JSON-Schema conformance (additionalProperties:false, pattern/enum/minLength,
// the tlsCertRefid rejection) via Python jsonschema with a jq fallback, plus the
// reference-integrity checks (network.zone in zones.json, ownerOrg in
// organizations). We do NOT re-implement a draft-2020-12 validator in TS (that
// would need an npm dependency — the env.d.ts pattern forbids deps).
//
// NOTE: config.ts still carries validateEnvironmentRefs (the reference + required
// + tlsCertRefid checks) — used as the in-process PRE-WRITE guard for add/modify
// so a write is refused before it touches disk. validate-environment.sh remains
// the authoritative full-conformance gate invoked here.

import { spawnSync } from "child_process";

const VALIDATE_BIN = process.env.VALIDATE_ENVIRONMENT_BIN ?? "validate-environment.sh";

export interface ValidateResult {
  status: number; // 0 = valid (warnings allowed), 1 = errors
  stdout: string;
  stderr: string;
}

// Run validate-environment.sh against a file/dir (default: the environments dir
// under configDir, resolved by the script itself). Returns its exit status +
// captured output so the caller can relay and set the process exit code.
export function runValidate(configDir: string, target?: string): ValidateResult {
  const args: string[] = ["--config-dir", configDir];
  if (target) args.push(target);
  const r = spawnSync(VALIDATE_BIN, args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) {
    return { status: 1, stdout: "", stderr: `${VALIDATE_BIN}: ${r.error.message}` };
  }
  return { status: r.status ?? 1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}
