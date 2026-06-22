# controller/identity-controller

The **Authentik runtime controller** for TAPPaaS (ADR-007 P10 controller —
owns runtime state on the Authentik API; no `validate.sh`).

Extracted from `opnsense-controller` in ADR-007 S2b-1 (move + repackage only,
no feature changes). It talks to the Authentik REST API directly over `httpx`
and has no OPNsense dependency.

## What it ships

- `authentik-manager` — the CLI that reconciles Authentik: users, groups,
  bindings, proxy/OIDC applications and the embedded forward-auth outpost.
- `identity-controller` — same entry point under the controller's own name.

Both are built by `nix-build -A default default.nix` and symlinked into
`/home/tappaas/bin/` by `install.sh` / `update.sh`.

## Who calls it

`people-manager` invokes `authentik-manager` to reconcile Authentik against the
declared people/role configuration.

## Credentials

`~/.authentik-credentials.txt` (key=value):

```
url=https://identity.<domain>
token=<api-token>
```
