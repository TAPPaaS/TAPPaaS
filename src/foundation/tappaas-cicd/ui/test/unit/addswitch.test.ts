// addswitch.test.ts — Add a switch (web/src/pages/AddSwitch.tsx): its four
// ways, and the controller's address read from the URL its login holds.

import { SWITCH_KINDS, hostOf } from "../../web/src/switchadd";
import { check, done } from "./check";

check(SWITCH_KINDS.map((k) => k.id).join() === "unifi-existing,unifi-install,mikrotik,manual", "four ways, in the operator's order");
check(hostOf("https://10.0.0.5:11443") === "10.0.0.5" && hostOf("https://unifi-os.lab2.home.arpa/") === "unifi-os.lab2.home.arpa" && hostOf("10.0.0.7") === "10.0.0.7", "the controller's address: the URL's host, no scheme, port or path");

done("addswitch");
