# <Module Name> — Design notes

Primary audience: **module developers** (Diataxis: *explanation*).

This document explains *how this module works and why it is built the way it is* — the
internal rationale a maintainer or contributor needs. Per ADR-013 it is **not** published
to tappaas.org: keep the end-user *what/why* in [README.md](./README.md) and the admin
*how* in [INSTALL.md](./INSTALL.md); implementation reasoning lives here.

<!-- Delete any section that does not apply to your module — do not leave empty headings.
     Keep it factual and current; a stale design note is worse than none. Real examples to
     read: apps/nextcloud/DESIGN.md, apps/deconz/DESIGN.md, apps/openwebui/DESIGN.md. -->

## Why this exists

<The problem this module solves for TAPPaaS, and why it is a separate module rather than
part of an existing one. One short paragraph.>

## Architecture

<How the module is put together: the guest (VM/LXC), the main software components, and how
they talk to each other and to the platform (reverse proxy, zones, identity, storage). A
short bullet list or diagram is enough.>

## Provided services (`provides`)

<!-- OMIT if the module provides nothing (no `provides` in its JSON). -->

| Service (`provider:service`) | What a dependent gets | Hook(s) |
|------------------------------|-----------------------|---------|
| `<module>:<service>` | <capability> | `services/<service>/{install,update}-service.sh` |

## Dependencies rationale

<Why each `dependsOn` / `integratesWith` entry is needed — the design reason, not just the
list (the list is in the JSON). Note which are soft (`integratesWith`) and what the module
does without them.>

## Configuration & install-time overrides

<The fields an installer is expected to override in `<module>.json`, plus any non-obvious
field semantics or defaults. Full field reference:
[module-fields.json](../../foundation/schemas/module-fields.json).>

## Secrets

<!-- OMIT if the module handles no secrets. -->

<What secrets the module needs, where they come from (the identity / secrets manager), and
how they reach the guest. Never commit secret values.>

## Sizing

<Why the default `cores` / `memory` / `diskSize` are what they are, and how they scale with
load.>

## Backup & restore

<What state must be backed up, via which `backup:*` service, and the restore path.>

## Alternatives considered

<!-- The in-depth rationale that README.md's "Alternatives considered" links to. OMIT if none. -->

- <alternative> — <why not chosen, a line or two>

## Deploy notes & known limitations (<version>)

<What the next operator or developer should know: rough edges, manual steps that should
eventually be automated, version-specific caveats.>

## Related documents

- [README.md](./README.md) — end-user overview (what you get)
- [INSTALL.md](./INSTALL.md) — admin install / operate
- <links to the ADRs or design docs that govern this module>
