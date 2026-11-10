// The output pane's fold counts lines as the pane shows them.
import { foldedCount, lastLines } from "../../web/src/wizards";
import { check, done } from "./check";

const one = "[Error] EROFS: read-only file system, open '/var/lib/tappaas/vlan-reach.json.tmp'\n";
check(foldedCount(one, 4) === 0, "one line and its newline fold nothing (no empty '1 earlier line')");
check(foldedCount("a\n\nb\n\n\n", 1) === 1, "blank lines are not counted as hidden");
const six = "1\n2\n3\n4\n5\n6\n";
check(foldedCount(six, 4) === 2 && lastLines(six, 4).join() === "3,4,5,6", "six lines folded to four hide two");
done("outputfold");
