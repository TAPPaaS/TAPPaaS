# controller/TEMPLATE

Skeleton **controller**. Copy this directory to scaffold a new controller, then
replace the stubs with the real CLI and verb logic.

A controller owns **runtime / device state**: it talks directly to a live API
or device (a firewall, a hypervisor, a switch, an identity server) and
converges the real state onto a desired state. It does **not** own config files
and has **no** `validate` operation (no config of its own to validate) — that is
a *manager*'s job. A manager owns the declarative config, validates it, and
**calls a controller** to apply it.

## The verb contract

The TAPPaaS mothership drives every component generically through three fixed
verb scripts. Implement all three; each must be **idempotent** (running it
twice is safe and produces the same result):

| Verb         | What it must do |
|--------------|-----------------|
| `install.sh` | First-time setup: build the artifact (compiled components) and place the CLI entry point(s) on `PATH`. |
| `update.sh`  | Re-run after a code change: rebuild + re-link so new code goes live. Normally just `exec install.sh`. |
| `test.sh`    | Run this component's self-contained tests; exit non-zero on any failure. |

Controllers have **no** `validate` operation (no config of their own to
validate). The parent `controller/{install,update,test}.sh` dispatcher runs each
child's verb script and **skips `TEMPLATE/`**, so these stubs never run in place.

### Fast vs deep tests

Keep `test.sh`'s default run **fast and non-disruptive** (schema/CLI checks and
mocked logic). Gate any disruptive or live-device tests behind an opt-in:

```bash
if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    # live / disruptive checks here
fi
```

## The compiled-component rule

`install.sh` and `update.sh` must **(re)build a compiled artifact, not just
copy source**, then re-link the bin entry point. The right way depends on the
implementation language:

- **TypeScript / Python (compiled package):** rebuild the package, then refresh
  the bin symlink so it points at the freshly built artifact. Use `ln -sf` (or
  `ln -sfn`) so the relink is idempotent. Example (Python via nix):

  ```bash
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ( cd "${here}" && nix-build -A default default.nix >/dev/null )
  ln -sfn "${here}/result/bin/my-controller" /home/tappaas/bin/my-controller
  ```

  For TypeScript the build step is your bundler (`npm ci && npm run build` or
  equivalent) followed by the same relink. `update.sh` does the same as
  `install.sh` — a rebuild is a no-op when inputs are unchanged.

- **Bash:** nothing to compile. `install.sh` just symlinks the entry script(s)
  onto `PATH`:

  ```bash
  ln -sfn "$(pwd)/my-controller" /home/tappaas/bin/my-controller
  ```

## How a manager calls a controller

A manager never re-implements device logic. It validates its config, works out
the desired state, and then invokes the controller's CLI — the same CLI an
operator would run by hand — typically in a dry-run/check mode first and then
with an apply flag once it is satisfied. Because the controller is idempotent,
the manager can call `reconcile` (or the equivalent) on every run without
worrying about duplicate state.

## Preferred implementation language

When building a new controller, prefer, in order:

1. **TypeScript** — first choice for new controllers.
2. **Python** — when an ecosystem library makes it the pragmatic choice (e.g. an
   existing API client).
3. **Bash** — for thin device/CLI orchestration where shelling out to existing
   tools (`ssh`, `qm`, `jq`, vendor CLIs) is the natural fit.

## Files in this skeleton

| File          | Purpose |
|---------------|---------|
| `controller.sh` | Placeholder main entry. Rename to `<name>` / `<name>.sh` and replace with the real CLI. |
| `install.sh`  | Build artifact + place bin symlink (idempotent). |
| `update.sh`   | Rebuild + re-link (idempotent). |
| `test.sh`     | Self-contained tests; non-zero exit on failure. |
