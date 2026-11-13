// noderemove.test.ts — what the Remove a node wizard reads (web/src/noderemove.ts):
// the check's output as findings in the operator's words with their link
// targets, a lost node's losses, the switch ports and the asset's fate; the
// removal's output as what was done; and the commands it runs.

import { BACKUP_TARGET, assetFor, assetTarget, checkArgv, moduleTarget, outputLines, parseCheck, parseRemoval, removeArgv, switchTarget } from "../../web/src/noderemove";
import { check, done } from "./check";

const E = "\x1b[0;31m[Error]\x1b[m";
const I = "\x1b[32m[Info]\x1b[m";
const W = "\x1b[33m[Warning]\x1b[m";

// 1. the commands
check(checkArgv("tappaas4", "shutdown").join(" ") === "site-manager node delete tappaas4 --shutdown", "the check is the dry run, with the way");
check(removeArgv("tappaas4", "erase", "remove").join(" ") === "site-manager node delete tappaas4 --erase --asset remove --yes --apply", "the removal: the way, the asset, --yes for the typed name, --apply");
check(assetFor("lost", "keep") === "remove" && assetFor("shutdown", "keep") === "keep" && assetFor("erase", "remove") === "remove", "a lost machine's record is removed; otherwise the choice");

// 2. a clean check
const clean = [
  "[preview] node delete 'tappaas4' → /home/tappaas/TAPPaaS/src/foundation/cluster/remove-node.sh --dry-run --shutdown tappaas4",
  `${I} \x1b[1mStep 2: What tappaas4 still holds\x1b[m`,
  `${I}   \x1b[32m✓\x1b[m nothing — no guest, replication job, HA rule or PBS`,
  `${I}   power tappaas4 off and wait until it is gone (≤ 300s)`,
  `${I}   park switch port 4 on USW Pro XG 10 PoE (it was tappaas4's)`,
  `${I}   park switch port ether7 on crs-a (it was tappaas4's)`,
  `${I} \x1b[33mDRY-RUN complete — no changes made.\x1b[m`,
  "  then: its node record 'tappaas4' is deleted",
  "  then: asset srv-03 is released from tappaas4 and kept: it stays placed in rack1 U20-U21",
].join("\n");
check(outputLines(clean).some((l) => l === "✓ nothing — no guest, replication job, HA rule or PBS"), "colour codes and tags stripped");
const ok = parseCheck(clean, "tappaas4", { exit: 0 });
check(ok.state === "ok" && ok.blockers.length === 0, "nothing holds it: it can be removed");
check(ok.ports.map((p) => `${p.sw}|${p.port}`).join() === "USW Pro XG 10 PoE|4,crs-a|ether7", "the switch ports to be parked, a switch name with spaces too");
check(ok.record === "deleted" && !!ok.asset && ok.asset.key === "srv-03" && ok.asset.fate === "kept" && ok.asset.where === "rack1 U20-U21", "the record's and the asset's fate");
check(parseCheck(clean, "tappaas4", null).state === "running", "no exit yet: still running");
// Today's wording: the CIs retired, the kept asset free for its next role.
const now = parseCheck([
  "  then: retired in the CMDB: CI tappaas4 with its app pve; pools rpool, tanka1 — never reused, its history kept",
  "  then: asset srv-03 is released from tappaas4 and kept: it stays placed in rack1 U20-U21, free for its next role",
].join("\n"), "tappaas4", { exit: 0 });
check(now.retire === "CI tappaas4 with its app pve; pools rpool, tanka1 — never reused, its history kept", `the CIs to be retired (${now.retire})`);
check(now.asset?.fate === "kept" && now.asset.where === "rack1 U20-U21", `the kept asset's place, without the words after it (${now.asset?.where})`);
check(parseCheck("  then: asset srv-03 is released from tappaas4 and kept: it goes back to stock, free for its next role", "tappaas4", { exit: 0 }).asset?.where === null, "back to stock: no place");
check(ok.retire === null, "an older site-manager: no CIs named");
const removing = parseCheck("  then: asset srv-03 is released from tappaas4 and removed: its 1 recorded cable(s), its placement in rack1 U20, its record", "tappaas4", { exit: 0 });
check(removing.asset?.fate === "removed" && removing.asset.key === "srv-03", "an asset to be removed");

// 3. blockers, each with where to act
const blocked = [
  `${E}   ✗ qemu 312 (nextcloud) runs here — move it: module-manager modify nextcloud --set node=<other>, then module-manager migrate nextcloud`,
  `${E}   ✗ lxc 901 (scratch) runs here and is no module's — migrate or remove it by hand`,
  `${E}   ✗ replication job 312-0 tappaas4->tappaas2 (module nextcloud) — change the module's HANode, then site-manager update re-folds it`,
  `${E}   ✗ replication job 500-1 tappaas1->tappaas4 — change the module's HANode, then site-manager update re-folds it`,
  `${E}   ✗ HA rule ha-litellm names it (tappaas4:2,tappaas1:1) — change that module's node/HANode`,
  `${E}   ✗ the site's PBS (backup datastore) runs here — move it first (backup-manager placement)`,
  `${E} 6 thing(s) stop the removal — nothing was changed.`,
  `${E} remove-node.sh exited 1 — the node's record and its asset are unchanged`,
].join("\n");
const b = parseCheck(blocked, "tappaas4", { exit: 1 });
check(b.state === "blocked" && b.blockers.length === 6, `six blockers, the summary lines not among them (${b.blockers.length})`);
check(b.blockers[0].text === "The VM nextcloud (312) runs on tappaas4." && b.blockers[0].target?.to === "/modules/nextcloud" && b.blockers[0].hint === "move it to another node", "a module's guest: its module page, to move it");
check(/container scratch \(901\).*belongs to no module/.test(b.blockers[1].text) && !b.blockers[1].target, "a guest of no module: no link");
check(b.blockers[2].target?.to === "/modules/nextcloud" && /replicated from tappaas4/.test(b.blockers[2].text), "a replication job with its module: the module");
check(!b.blockers[3].target && /replicated to tappaas4/.test(b.blockers[3].text), "a replication job of no known module: said, no link");
check(b.blockers[4].target?.to === "/modules/litellm" && /module litellm/.test(b.blockers[4].text), "an HA rule: the module it is named after");
check(b.blockers[5].target === BACKUP_TARGET && BACKUP_TARGET.to === "/backup", "the site's PBS: the Backup page");
check(b.blockers.every((f) => !/--|module-manager|site-manager|\.json|HANode|pvecm/.test(f.text + (f.hint ?? ""))), "no flags, commands or file names in the findings");

// 4. the way does not fit the machine
const answers = parseCheck(`${E} --lost is for a node that is down — tappaas4 answers: move what it holds, then remove it with --shutdown`, "tappaas4", { exit: 1 });
check(answers.state === "blocked" && /still answers/.test(answers.blockers[0].text), "down for good, but it answers");
const down = parseCheck(`${E}   ✗ qemu 312 (nextcloud) runs here — move it: module-manager modify nextcloud --set node=<other>, then module-manager migrate nextcloud\n${E}   tappaas4 is down: if it is gone for good, --lost removes it and reports what to restore`, "tappaas4", { exit: 1 });
check(down.blockers.length === 2 && /down for good/.test(down.blockers[1].text), "a node that is down: the way that fits");
const erase = parseCheck(`${E} --erase needs the node running — tappaas4 does not answer`, "tappaas4", { exit: 1 });
check(/cannot be wiped/.test(erase.blockers[0].text), "wipe a node that does not answer");

// 5. a failure that is no blocker: the last lines
const failed = parseCheck(`${I} Step 1\n${E} something else broke`, "tappaas4", { exit: 2 });
check(failed.state === "failed" && failed.tail.join("|") === "Step 1|something else broke", "a failure shows its last lines");

// 6. a lost node: what goes with it
const lost = parseCheck([
  `${W}   qemu 312 (nextcloud) is lost with the node — restore it from backup: backup-manager restore restore nextcloud --node <node> (RESTORE.md §3.3)`,
  `${W}   replication job 312-0 tappaas4->tappaas2 (module nextcloud) — removed with the node; site-manager update re-folds HA after the restore`,
  `${W}   HA rule ha-nextcloud names it (tappaas4,tappaas2) — kept: a replacement under the same name inherits it`,
  `${W}   the site's PBS ran here — its backups are gone with it unless a copy exists elsewhere (RESTORE.md §6)`,
  "  then: asset srv-03 is released from tappaas4 and removed: its record",
].join("\n"), "tappaas4", { exit: 0 });
check(lost.state === "ok" && lost.losses.length === 4, "a lost node: losses, not blockers");
check(lost.losses[0].target?.to === "/modules/nextcloud" && /restore it/.test(lost.losses[0].hint ?? ""), "a lost guest: its module, to restore it");
check(lost.losses[3].target === BACKUP_TARGET, "the PBS lost: the Backup page");

// 7. the removal's result
const res = parseRemoval([
  `${I}   \x1b[32m✓\x1b[m pvecm delnode tappaas4`,
  `${I}   \x1b[32m✓\x1b[m USW Pro XG 10 PoE port 4 parked`,
  `${W}   could not park crs-a port ether7 — switch-manager remove-port 'crs-a' ether7`,
  `${I} \x1b[1m\x1b[32m✓\x1b[m tappaas4 is out of the cluster.\x1b[m`,
  "\x1b[32m✓\x1b[m its node record is deleted and unregistered",
  "\x1b[32m✓\x1b[m asset srv-03 released from tappaas4 and kept: it stays placed in rack1 U20-U21",
].join("\n"));
check(res.removed && res.record === "deleted", "out of the cluster, the record deleted");
check(res.parked.map((p) => `${p.sw}|${p.port}`).join() === "USW Pro XG 10 PoE|4" && res.notParked.map((p) => `${p.sw}|${p.port}`).join() === "crs-a|ether7", "parked and not parked ports");
check(res.asset?.key === "srv-03" && res.asset.fate === "kept" && res.asset.where === "rack1 U20-U21", "the asset kept, where");
const resNow = parseRemoval("\x1b[32m✓\x1b[m retired in the CMDB: CI tappaas4 with its pools tanka1 — never reused, its history kept\n\x1b[32m✓\x1b[m asset srv-03 released from tappaas4 and kept: it goes back to stock, free for its next role\n✓ asset srv-03 removed: its cables, placement and record — decommissioned, the CMDB keeps it as disposed");
check(resNow.retired === "CI tappaas4 with its pools tanka1 — never reused, its history kept", "the CIs retired");
check(resNow.asset?.fate === "removed", "the asset removed, decommissioned (today's words)");
const res2 = parseRemoval("✓ tappaas4 is out of the cluster.\n✓ asset srv-03 released from tappaas4\n✓ asset srv-03 removed: its cables, placement and record");
check(res2.asset?.fate === "removed", "the asset removed");
const res2d = parseRemoval("✓ tappaas4 is out of the cluster.\n✓ asset srv-03 released from tappaas4\n✓ asset srv-03 removed: its cables, placement and record and its 3 disks' records");
check(res2d.asset?.fate === "removed" && res2d.asset.key === "srv-03", "the asset removed with its disks");
check(parseCheck("  then: asset srv-03 is released from tappaas4 and removed: its placement in rack1 U20, its record and its 2 disks' records", "tappaas4", { exit: 0 }).asset?.fate === "removed", "an asset to be removed with its disks");
const res3 = parseRemoval("✓ tappaas4 is out of the cluster.\n[Warning] asset srv-03 is not removed: asset-manager unplace srv-03: refused — run the rest by hand");
check(!!res3.assetTrouble && /asset page/.test(res3.assetTrouble), "an asset step that failed: finish it on its page");

// 8. link targets
check(moduleTarget("nextcloud").to === "/modules/nextcloud", "a module's page");
check(assetTarget("srv-03").to === "/site/assets/srv-03", "an asset's page");
check(switchTarget("USW Pro XG 10 PoE").to === "/site/physical?select=USW%20Pro%20XG%2010%20PoE", "a switch, selected in the Physical view");

done("noderemove");
