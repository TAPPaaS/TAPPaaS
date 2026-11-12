# The console's fixtures

Two sets, for two readers.

- **This directory** is what `capture.sh` recorded from hrossen (see `CAPTURED`: when, where, which commit). Fixture mode (`ui/fixture-server.sh`, `src/fixtures.ts`) serves it. A refresh replaces it.
- **`2026-10-17/`** is frozen: the unit tests assert on what the site held then (`PIN` in `test/unit/fake-site.ts`), so a refresh never breaks a test. The files that sit here and nowhere else are hand-kept for the tests too: `health-site.json` (built by hand, the Health view's cases), `litellm-exchange.json`, `setup/`, `wizards/`, `zones.json`, `topology-positions.json`, `update-tappaas.failures`.

## Refreshing

```bash
ui/test/fixtures/capture.sh
```

Read verbs only, redacted before they land here, in one ssh session to `cicd-hrossen` (`--host` for another, `--out` for another directory). About three minutes. It prints every verb that exited non-zero; `validate` exits 1 when a gate fails, and `backup-manager coverage` of a module with no guest does too. Both are answers.

| Path | What |
|---|---|
| `modules.json`, `topology.json`, `validate.json`, `backup.json`, `backup-runs.json`, `guests.json`, `storage-inventory.json`, `environments.json`, `aps.json`, `ssids.json` | the reads the fakes name |
| `sweep-journal.txt` | the last 3000 lines of the sweep's journal |
| `reads/<slug>.out`, `.rc` | every other verb, one file per argv (`<slug>` is `fixtureSlug`); the managers' manifests are here too |
| `cmdb/` | `objects.json`, `relations.json`, `classes.json`, `sweep.json`; `show/` and `history/` for the classes a page opens, a history cut to its latest 20 rows. Other objects' records are derived |
| `config/` | the records the console reads directly: named files, never the whole directory |
| `jobs/<slug>.preview.txt`, `.apply.txt` | hand-kept, not captured: what a job says in fixture mode. `<slug>` is the argv without `--apply`, `--check`, `--dry-run`, `--json`, or a prefix of it. A `.pace` beside one (`<first> <ms>`) says it line by line. The flows (`web/e2e/flows`) read them: tappaas4's removal, tappaas5's add, litellm's update |

## What the files hold

The repository is public, so `capture.sh` runs `redact.py` over a capture in a temporary directory before anything reaches this one, and stops if a real value survives it. The same pass has been run over the frozen set. Rerun it by hand with `python3 redact.py <dir>`; a second pass changes nothing.

| What | Rule |
|---|---|
| E-mail addresses | The address in `config/site.json` becomes `operator@example.org`; the others, sorted, `user1@example.org`, `user2@example.org`, ... Upper and lower case count as one. `example.*` and `git@` stay. |
| Public IPv4 | Every global address. Each /24, sorted, becomes `192.0.2`, `198.51.100`, `203.0.113`, then `198.18.<n>`; the last octet stays, so a network and its gateway still match. |
| Public IPv6 | Every global address. Each /48, sorted, becomes `2001:db8:<n>`; the subnet and the host stay, so a zone's /64 is still its zone's. A prefix written without its tail goes the same way. |
| Kept | Public resolvers (`KEEP` in `redact.py`: Cloudflare, Google, Quad9), which are the world's. A 4-part version number that looks like a global address is rewritten too: it costs nothing and nothing slips through by looking like a version. |
| The vulnerability scan | Never leaves the site: `capture.sh` does not run it. `reads/health-manager-report-security-json.out` is a copy of `security-scan.synthetic.json`, the report's shape with made-up CVE ids (`CVE-0000-*`) and packages, and its risk scores (`score`) computed by health-manager's own `site-score.ts` over this set's zones and module placement, with seven days of made-up history. |
| Performance | Synthetic, not captured (hrossen ran no metrics store at the capture): `perf/metrics.json` (written by `perf/make-metrics.py`) describes each series of the fixture store; `config/site.json` `size` and `performance`, `config/nextcloud.json` and `config/environments/test.json` `performance`, a `performance` condition on `tankc1`, `karakeep` and `nomad` in `cmdb/objects.json`, four changes in `cmdb/history/`, `reads/health-manager-perf-list-json.out`, the `perf` verbs in `reads/health-manager-help-json.out` and `jobs/health-manager-perf*.apply.txt` were added by hand for ADR-046's Performance menu; a refresh drops them unless carried over. `variants/off/` is the same site at `small` with no level. |

The numbering follows the sort, so a new /24 or user can shift a later one on a refresh. Within a refresh the mapping is one everywhere; joins between files hold.

No password, token or key is in the set: `capture.sh` copies no credential file, and the managers print `secretsEnv` paths and masked values only (checked with a pattern scan on 2026-11-01; repeat it after a refresh that adds a verb).

Not redacted: host names and internal addresses. Node and guest names, `*.mgmt.internal`, the public domain `hrossen.dk`, `10.x` addresses, MACs and disk serials are in nearly every file, most in `topology.json`, `storage-inventory.json`, `cmdb/objects.json`, `config/site.json`, `config/zones.json` and `config/positions.json`. People's names and user names are in `config/identities/users/`, `reads/identity-manager-user-*` and the `user` CIs in `cmdb/`.
