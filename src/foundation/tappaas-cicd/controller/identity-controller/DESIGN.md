# identity-controller — design notes

## Language & build

**Python package**, built with nix. `src/` is a standard setuptools project
(`pyproject.toml`) whose only runtime dependency is `httpx`. `default.nix`
defines a `buildPythonPackage` (`identity-controller`) plus a default Python
environment that puts the CLIs on `bin/`.

`install.sh` is a compiled-component installer: it runs `nix-build -A default
default.nix` and then `ln -sfn`s the built `result/bin/<tool>` entry points into
`/home/tappaas/bin/` for both `authentik-manager` and `identity-controller`. The
relink is idempotent and needs no `nixos-rebuild`. `update.sh` just `exec`s
`install.sh`, so a code change is picked up by rebuilding and re-linking.

`pyproject.toml` `[project.scripts]` maps both names to the same entry:

```
authentik-manager   = identity_controller.authentik_cli:main
identity-controller = identity_controller.authentik_cli:main
```

## Internal structure

```
src/identity_controller/
  authentik_cli.py        # argparse CLI; one cmd_* handler per subcommand
  authentik_manager.py    # AuthentikManager — the API client / reconcile logic
  people_primitives.py    # higher-level user/role helpers
src/test/
  test_authentik_manager.py
  test_people_primitives.py
```

`authentik_cli.py` builds an argparse tree with a global parser (credentials /
URL / token / TLS) and one subparser per command, each wired to a `cmd_*`
handler that calls into `AuthentikManager`. `AuthentikManager` is the only thing
that touches the live Authentik REST API (over `httpx`), implementing the
idempotent create-or-update primitives.

## How a manager calls it

The people/identity manager owns the declarative people/role config, validates
it, and then invokes `authentik-manager` subcommands (`ensure-user`,
`ensure-role`, `add-member`, `*-app-ensure`, ...) to converge Authentik onto
that config. Because every write command is idempotent, the manager can re-run
the full set on each reconcile.

## Tests

`test.sh` builds the package with nix and runs the co-located `unittest` suite
against the freshly built environment (which provides `httpx`), exiting non-zero
on any failure.

## Pending / not yet implemented

- No `delete`/prune reconcile pass: the CLI offers per-object delete commands
  (`user-delete`, `app-delete`) but there is no single command that prunes users
  or groups absent from a desired set — the calling manager must drive removals
  explicitly.
- The controller is the API-driving arm only; orchestration policy (which users
  and roles *should* exist) lives in the manager layer above it.
