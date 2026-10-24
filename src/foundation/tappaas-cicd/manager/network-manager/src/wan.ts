// wan.ts — the WAN's IPv6 router (#875): `wan ipv6-relearn --check|--apply`.
//
// OPNsense learns its IPv6 router once, from the advertisement answering its
// own solicitation; an ISP that replaces its router leaves the firewall routing
// IPv6 to an address nobody answers (health-manager's ipv6-egress gate says
// so). The re-learn is the opnsense controller's (`ipv6-manager relearn`, the
// steps and their order in its wan6.py); this is its front door.

import { stream } from "../../../lib/ts/src/exec";
import { die } from "../../../lib/ts/src/cli";

// Overridable for tests / relocations, like SNAT_BIN (read per call: tests set it late).
const ipv6Bin = (): string => process.env.NM_IPV6_BIN ?? "ipv6-manager";

export function relearnArgs(apply: boolean, configDir: string): string[] {
  return ["relearn", "--config-dir", configDir, "--no-ssl-verify", ...(apply ? [] : ["--check-mode"])];
}

export function cmdWan(rest: string[], o: { apply: boolean; check: boolean; configDir: string }): number {
  if (rest[0] !== "ipv6-relearn") die(`wan: unknown sub-command '${rest[0] ?? ""}' (wan ipv6-relearn --check|--apply)`);
  if (o.apply && o.check) die("wan ipv6-relearn: --check or --apply, not both");
  return stream(ipv6Bin(), relearnArgs(o.apply, o.configDir));
}
