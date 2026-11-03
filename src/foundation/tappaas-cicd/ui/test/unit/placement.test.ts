// placement.test.ts — Rest of foundation's placement panel: a row's action and
// how it follows a changed machine (web/src/placement.ts).

import { PlacementRow, follow, placeArgs, rowAction, rowProblem } from "../../web/src/placement";
import { check, done } from "./check";

const cicd: PlacementRow = {
  module: "tappaas-cicd",
  kind: "guest",
  installed: true,
  current: { node: "tappaas1", ha: "", storage: "local-zfs" },
  proposal: { node: "tappaas1", ha: "tappaas2", storage: "tanka1" },
  choices: {
    tappaas1: { ha: ["tappaas2", "tappaas3"], pools: { "": ["tanka1", "local-zfs"], tappaas2: ["tanka1", "local-zfs"], tappaas3: ["local-zfs"] } },
    tappaas2: { ha: ["tappaas1"], pools: { "": ["tanka1", "local-zfs"], tappaas1: ["tanka1", "local-zfs"] } },
  },
  note: null,
};
const backup: PlacementRow = { module: "backup", kind: "backup", installed: false, current: null, proposal: { node: "", ha: "", storage: "" }, choices: {}, note: "placeholder" };

check(rowAction(cicd, cicd.proposal) === "move", "an installed guest proposed elsewhere: Move");
check(rowAction(cicd, cicd.current!) === "stays", "…set back to where it is: Stays");
check(rowAction({ ...cicd, installed: false, current: null }, cicd.proposal) === "install", "not installed: Install");
check(rowAction(backup, backup.proposal) === "placeholder", "backup with no tankc pool: Placeholder");

const toThree = follow(cicd, { node: "tappaas1", ha: "tappaas3", storage: "tanka1" });
check(toThree.place.storage === "local-zfs" && /tanka1 is not on tappaas1 and tappaas3/.test(toThree.changed[0]), "an HA machine without the pool: the pool both have, and it says why");
const toTwo = follow(cicd, { node: "tappaas2", ha: "tappaas2", storage: "tanka1" });
check(toTwo.place.ha === "" && toTwo.place.storage === "tanka1" && /tappaas2 cannot be one for tappaas2/.test(toTwo.changed[0]), "the machine moved onto its HA machine: no HA machine, the pool kept");
check(follow(cicd, cicd.proposal).changed.length === 0, "a valid row changes nothing");

check(rowProblem(cicd, cicd.proposal) === null && rowProblem(cicd, { node: "tappaas9", ha: "", storage: "tanka1" }) !== null, "a machine it cannot run on is a problem");
check(rowProblem(backup, backup.proposal) === null, "…a placeholder is not");
const args = placeArgs([cicd, backup], { "tappaas-cicd": cicd.proposal, backup: backup.proposal });
check(args.length === 1 && args[0].module === "tappaas-cicd" && args[0].ha === "tappaas2", "the job gets a place for every row but a placeholder");

done("placement");
