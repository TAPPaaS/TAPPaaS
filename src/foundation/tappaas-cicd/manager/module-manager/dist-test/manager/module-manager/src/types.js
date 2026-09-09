"use strict";
// types.ts — the module-manager entity model + the ModuleClient interface (the
// bash-script boundary the manager orchestrates through) + the validate result
// shapes.
//
// Mirrors people-manager / network-manager: the CONFIG-layer verbs (list / show
// / validate) operate on this in-process model; the LIFECYCLE verbs (add /
// modify / delete / reconcile / test / snapshot-vm) delegate to the existing
// bash scripts via the injected ModuleClient (production = CliModuleClient,
// tests = a fake). The heavy cluster logic stays in bash for this first-pass
// port — module-manager is a thin orchestration boundary.
Object.defineProperty(exports, "__esModule", { value: true });
exports.MODULE_STATUS_VALUES = void 0;
// ── Module config entity (a deployed config/<module>.json) ────────────
// A deployed module config. The shape is open (modules carry many bespoke
// fields per module-fields.json); these are the ones list/show/validate read.
// Permitted `status` values — the single TS-side source of truth, mirroring the
// `status.values` set in schemas/module-fields.json (#556). `archived` = VM
// removed via delete-module.sh --archive, config kept as the archive record
// (#215); `external` = guest managed outside TAPPaaS (#216).
exports.MODULE_STATUS_VALUES = [
    "Development",
    "Testing",
    "Production",
    "Deprecated",
    "archived",
    "external",
];
