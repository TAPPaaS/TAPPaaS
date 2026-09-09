"use strict";
// help.ts — shared --help renderer for the TAPPaaS TypeScript managers.
//
// SHARED via lib/ts (ADR-007 post-implementation refactor, Phase 3) — the
// former per-manager vendored copies are gone; every manager imports this
// one file so --help renders the SAME way everywhere.
//
// A manager declares a HelpSpec (its verbs + per-verb options) and prints
// `renderHelp(spec)`. Layout (matches the network-manager reference):
//
//   <name> <version> — <tagline>
//
//   Usage:
//     <name> <verb.usage>            (one line per verb)
//
//   <verb> options:                  (one block per verb that HAS options)
//     --flag <arg>   description     (one line per option)
//
//   common:                          (options shared by every verb)
//     --flag <arg>   description
//     -h, --help     Show this help
//
//   <notes...>                       (optional free-text trailing paragraphs)
Object.defineProperty(exports, "__esModule", { value: true });
exports.renderHelp = renderHelp;
exports.renderVerbHelp = renderVerbHelp;
function deriveName(usage) {
    const out = [];
    for (const tok of usage.split(/\s+/)) {
        if (tok.startsWith("<") || tok.startsWith("[") || tok.startsWith("-"))
            break;
        out.push(tok);
    }
    return out.join(" ") || usage;
}
function renderOptions(opts) {
    if (opts.length === 0)
        return [];
    const w = Math.max(...opts.map(([f]) => f.length));
    return opts.map(([f, d]) => `  ${f.padEnd(w)}  ${d}`);
}
function renderHelp(s) {
    const lines = [`${s.name} ${s.version} — ${s.tagline}`, "", "Usage:"];
    for (const v of s.verbs) {
        lines.push(`  ${s.name} ${v.usage}${v.note ? `   ${v.note}` : ""}`);
    }
    for (const v of s.verbs) {
        if (!v.options || v.options.length === 0)
            continue;
        lines.push("", `${v.name ?? deriveName(v.usage)} options:`);
        lines.push(...renderOptions(v.options));
    }
    const common = [...(s.common ?? []), ["-h, --help", "Show this help"]];
    lines.push("", "common:", ...renderOptions(common));
    for (const n of s.notes ?? [])
        lines.push("", n);
    return lines.join("\n");
}
// renderVerbHelp — the usage + options for ONE verb (what `<cli> <verb> --help`
// should print). Falls back to the full renderHelp() when the token is not a
// known verb (e.g. `<cli> --help` with no verb, or a typo), so a help request
// always prints SOMETHING useful and exits 0.
function renderVerbHelp(s, verbName) {
    const v = s.verbs.find((x) => (x.name ?? deriveName(x.usage)) === verbName);
    if (!v)
        return renderHelp(s);
    const lines = [
        `${s.name} ${s.version} — ${s.tagline}`,
        "",
        "Usage:",
        `  ${s.name} ${v.usage}${v.note ? `   ${v.note}` : ""}`,
    ];
    if (v.options && v.options.length > 0) {
        lines.push("", `${v.name ?? deriveName(v.usage)} options:`);
        lines.push(...renderOptions(v.options));
    }
    const common = [...(s.common ?? []), ["-h, --help", "Show this help"]];
    lines.push("", "common:", ...renderOptions(common));
    return lines.join("\n");
}
