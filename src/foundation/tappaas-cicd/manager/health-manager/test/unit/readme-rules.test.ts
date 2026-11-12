// readme-rules.test.ts — the README beside the core records carries every core
// record as a sentence, generated as `rules list --origin core --markdown` does.
// It fails when the block and the files differ; HM_WRITE_README=1 rewrites it.

import { readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { markdownList } from "../../src/rules";
import { coreRecords } from "./assess-fixture";

const CICD = process.env.HM_CICD_DIR ?? join(__dirname, "../../../../../../..");
const README = join(CICD, "controller/cmdb-controller/metamodel/health/README.md");
const text = readFileSync(README, "utf8");
const begin = text.indexOf("<!-- standard-rules:begin");
const end = text.indexOf("<!-- standard-rules:end -->");
const head = text.slice(0, text.indexOf("\n", begin) + 1);
const want = ["", ...markdownList(coreRecords())].join("\n");
const have = text.slice(head.length, end);
let ok = begin >= 0 && end > begin && have === want;
if (!ok && process.env.HM_WRITE_README === "1" && begin >= 0 && end > begin) {
  writeFileSync(README, head + want + text.slice(end));
  ok = true;
  console.log("  ✓ the standard-rules block rewritten");
}
console.log(ok ? "  ✓ the README's standard-rules block matches the core records" : "  ✗ the README's standard-rules block differs from the core records (HM_WRITE_README=1 rewrites it)");
console.log(`\nResults: ${ok ? 1 : 0} passed, ${ok ? 0 : 1} failed`);
process.exit(ok ? 0 : 1);
