// setupallow.test.ts — the install LAN install-access.sh opens (ADR-037 D3):
// config/console-setup-allow adds networks the console accepts with the setup token.

import { mkdtempSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { extraSetupAllow } from "../../src/main";
import { check, done } from "./check";

const dir = mkdtempSync(join(tmpdir(), "setupallow-"));
check(extraSetupAllow(join(dir, "absent")).length === 0, "no file: nothing added");
const f = join(dir, "console-setup-allow");
writeFileSync(f, "192.168.0.0/20\n\n  10.1.2.0/24  \nnot a network\n0.0.0.0/0x\n");
check(extraSetupAllow(f).join() === "192.168.0.0/20,10.1.2.0/24", "one CIDR per line, anything else ignored");

done("setupallow");
