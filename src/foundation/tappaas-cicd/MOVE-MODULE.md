# Moving a module's source

Primary audience: TAPPaaS module developers.

A module's source lives at `src/<stack>/<module>/` in a repository (ADR-004, *Where a module's
directory is*). When a module changes stack, changes repository (Community → TAPPaaS), or is
renamed, its directory moves — and every installed site must follow, because each site's config
records where its modules come from (`moduleSource`). Don't move a module with a bare `git mv`:
use **`move-module.sh`**, which moves the files and writes the config migration that takes the
sites along (#500, [ADR-025](../../../docs/ADR/ADR-025%20-%20Config%20migrations%20and%20the%20upgrade%20path.md) D14).

## Run it

From the root of a TAPPaaS checkout — the repository whose migrations every site runs:

```bash
src/foundation/tappaas-cicd/scripts/move-module.sh TAPPaaS:src/misc/foo TAPPaaS:src/home/foo
src/foundation/tappaas-cicd/scripts/move-module.sh Community:src/foo TAPPaaS:src/home/foo --checkout Community=~/src/Community
src/foundation/tappaas-cicd/scripts/move-module.sh TAPPaaS:src/home/old TAPPaaS:src/home/new --rename
```

Name the repository on both sides as a site's `site.json` names it (`repositories[].name`:
`TAPPaaS`, `Community`, …). Each site resolves the name to its own checkout when the migration
runs.

| Option | Meaning |
|---|---|
| `--checkout <Repo>=<dir>` | Where another repository is checked out here; repeat per repository |
| `--this-repo <Repo>` | The name of the checkout you run it in (default `TAPPaaS`) |
| `--rename` | The last part of the path changes, so the module gets a new name — required, and refused while another module names the old one in `dependsOn`/`integratesWith` |
| `--new` | Start a new migration even if one from this session is still uncommitted |

## What it does

1. **Moves the files** — `git mv` within one checkout; copy, `git add` and `git rm` between two
   checkouts it knows. With only one end checked out, it tells you what to move by hand.
2. **Updates the catalogue**, `src/module-catalog.json`, in each checkout it knows: the entry's
   `moduleJson` (and `moduleName` on `--rename`), or out of the old repository's catalogue and
   into the new one's.
3. **Writes the migration** — adds the move to
   [`migrations/NNNN-modules-moved.sh`](migrations/README.md), with its fixture test and a row in
   the migrations table. While that migration is uncommitted, every further run adds to it; once
   committed it is sealed and the next move starts a new number (a number never changes meaning,
   ADR-025 D1).

On a rename, files inside the module that carry the old name (`<old>.json`, scripts) are yours to
rename; the tool says so.

## What you still do by hand

- **A change of stack.** Within one repository the tool does not touch the module's `stack`.
  Set `stack` in the module's JSON and in its catalogue entry to the stack it moved into — which
  also sets its scope (ADR-022e) — then regenerate the stack documents:

  ```bash
  python3 src/foundation/tappaas-cicd/scripts/gen-stack-readme.py
  ```

  The release boundary refuses stale stack documents (`gen-stack-readme.py --check`).
- **Commit together**: the move, the catalogue(s) and the migration — in both repositories when
  the module changed repository.

## What happens on each site

The next update runs the migration, which points every config using a moved module at the
module's new place in that site's checkout. It stops the update, rather than guess, when the
target repository is not registered on the site (`site-manager repository add …` fixes that),
when the target directory is missing, or when a renamed module is still named in another config's
`dependsOn`/`integratesWith`.

## See also

- [Config migrations](migrations/README.md) — how migrations are written, tested and run.
- The tool's own header, `scripts/move-module.sh`, and its test,
  `scripts/test/test-move-module.sh`.
