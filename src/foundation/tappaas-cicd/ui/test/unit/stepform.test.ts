// stepform.test.ts — what a step's form makes of a verb's options: which arg is
// worth a placeholder, which option is a calendar, and what a date sends.

import { ArgvStep, buildArgv, fieldKind, formParts, missingFields, placeholderOf, tomorrow } from "../../web/src/argv";
import { ManifestVerb } from "../../web/src/types";
import { check, done } from "./check";

// ── the placeholder ──
for (const arg of ["<n>", "<t>", "D", "H", "<value>", "<text>", "<arg>"]) check(placeholderOf(arg) === null, `${arg} leaves the box blank`);
check(placeholderOf(null) === null, "no arg, no placeholder");
for (const arg of ["<file>", "<vendor/model>", "field=value", "<30m|12h|7d|ISO date>"]) check(placeholderOf(arg) === arg, `${arg} stays: it says what goes there`);

// ── the calendar ──
check(fieldKind(undefined, "--warranty-until", "<date>") === "date", "an arg of <date> is a calendar");
check(fieldKind({ "--until": "future-date" }, "--until", "<time>") === "future-date", "the step's word makes one of any other arg");
check(fieldKind({}, "--note", "<n>") === null, "anything else is text");
check(tomorrow(new Date(2026, 11, 31, 23, 30)) === "2027-01-01", "tomorrow crosses the year in the local calendar");

// ── the Ack dialog's step ──
const verb = {
  verb: "ack", keys: [["ack"]], usage: "ack <ci> [--type <t>] --note <n> [--until <time>] [--sticky]",
  positionals: [{ name: "ci", optional: false, repeatable: false }],
  options: [
    { flag: "--type", takesValue: true, arg: "<t>", choices: null, repeatable: false, description: "" },
    { flag: "--note", takesValue: true, arg: "<n>", choices: null, repeatable: false, description: "" },
    { flag: "--until", takesValue: true, arg: "<time>", choices: null, repeatable: false, description: "" },
    { flag: "--sticky", takesValue: false, arg: null, choices: null, repeatable: false, description: "" },
  ],
  disruptions: [],
} as unknown as ManifestVerb;
const step: ArgvStep & { hide: string[] } = { bin: "health-manager", fixed: ["vm/nextcloud"], hide: ["--type"] };
const fixed = { "--type": "drift" };

check(!formParts(step, verb).options.some((o) => o.flag === "--type"), "the type is not a field");
check(buildArgv(step, verb, fixed).join(" ") === "health-manager ack vm/nextcloud --type drift", "but it is passed");
check(buildArgv(step, verb, { ...fixed, "--note": "x", "--until": "2026-11-05" }).join(" ") === "health-manager ack vm/nextcloud --type drift --note x --until 2026-11-05", "a date goes as the calendar gives it");
check(!buildArgv(step, verb, { ...fixed, "--until": "" }).includes("--until"), "an empty calendar sends no --until");
check(missingFields(step, verb, fixed, buildArgv(step, verb, fixed)).join() === "--note", "only the note is still wanted");

done("stepform");
