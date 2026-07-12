# Codeberg Migration — TAPPaaS/TAPPaaS

Migrating the TAPPaaS **code** repository from GitHub to Codeberg. Tracking issue:
[#97 "Move to CodeBerg"](https://github.com/TAPPaaS/TAPPaaS/issues/97).

> The **Documentation** repo is already on Codeberg (`codeberg.org/TAPPaaS/Documentation`,
> staging.tappaas.org live). This document covers the code repo and the Community repo.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Build-image hosting | **Stay on GitHub Releases (for now)** | Codeberg has per-repo storage quotas and discourages large-binary CDN use; the qcow2 images are multi-GB. Moving them off GitHub is deferred — [#414](https://github.com/TAPPaaS/TAPPaaS/issues/414). |
| Image build pipelines | **Stay as GitHub Actions (for now)** | They rely on GitHub-Actions-only pieces (`vmactions/freebsd-vm` for UFS write, `DeterminateSystems/nix-installer-action`, `softprops/action-gh-release`). Woodpecker port deferred — [#414](https://github.com/TAPPaaS/TAPPaaS/issues/414). |
| GitHub repo fate | **Push mirror — only after a fully-tested stable 2.0** | Keeps discoverability/SEO without drift. Until then GitHub stays live but goes stale (Codeberg is the dev home). |
| "Migrated" note / archive on GitHub | **Deferred to the 2.0 cutover** | Same gate as the mirror. |
| New long-lived release branch | **Reuse `stable`** (not a new `stage`) | Promoting `ADR007` (the 2.0 manager/controller paradigm) to `stable` is the pending promote-to-stable step; existing tooling already references `stable`. |
| Release sequence | Codeberg push first, then tag `main` `v1.1` + point `stable` at it → merge `ADR007`→`main` → retest → promote staging → promote `stable` | `v1.1` is the final 1.x checkpoint (`stable` = 1.1 on Codeberg); 2.0 lands on `main` then `stable`. All release work happens on Codeberg. |

## Reference-rewrite scope

**Rewrite to Codeberg** — TAPPaaS-owned *source-code* fetches. Note the raw path scheme differs:
`raw.githubusercontent.com/TAPPaaS/TAPPaaS/<branch>/<path>` → `codeberg.org/TAPPaaS/TAPPaaS/raw/branch/<branch>/<path>`.

| File | Reference |
|------|-----------|
| `src/foundation/install.sh` | `REPO=` raw base |
| `src/foundation/cluster/install.sh` | `REPO=` raw base |
| `src/foundation/cluster/install-platform.sh` | `REPO=` raw base; clone URLs (lines ~221, ~311) |
| `src/foundation/cluster/INSTALL.md` | `REPO=` raw base |
| `src/foundation/cluster/DESIGN.md` | `REPO`/`BRANCH` default doc |
| `INSTALL.md` | `REPO=` raw base (×2) |
| `docs/design/ADR-007-migration-runbook.md` | `REPO=` raw base |
| `docs/ADR/ADR-007d - Site.md` | clone URL (line ~53) |
| `src/foundation/cluster/Create-TAPPaaS-VM.sh` | UI links (lines ~77–85; also fixes mis-cased `TAPpaas/TAPpaas`) |

**Keep on github.com** (per the image-hosting decision) — do **not** rewrite:

| File | Reference |
|------|-----------|
| `src/foundation/network/network.json:57` | `imageLocation` → opnsense release asset |
| `src/foundation/templates/tappaas-nixos.json:24` | `imageLocation` → nixos release asset |
| `src/foundation/cluster/install-platform.sh:266` | `api.github.com/.../releases/latest` |
| all third-party URLs | maurice-w opnsense base, community-scripts/ProxmoxVE, home-assistant, NixOS/nixpkgs, unifi clients, firebase/php-jwt, netbird, minisforum-repo |

**Open question** — `github.com/TAPPaaS/TAPPaaS/issues/NNN` doc links (dozens): whether these break
depends on if Forgejo's issue import preserves numbers. Decide at cutover; leave as-is for now.

## Tracker

Legend: ☐ todo · ◐ in progress · ☑ done · ⏸ deferred (post-2.0 cutover)

### Phase 0 — Pre-flight
- [x] Reconcile the 21 `main`-only commits vs `ADR007` (litellm, vllm-amd, openwebui, deconz, vaultwarden, nixos-canon C2 fixes) — confirm none are lost by the merge
- [x] Create this tracking doc and issue [#414](https://github.com/TAPPaaS/TAPPaaS/issues/414)

### Phase 1 — Push to Codeberg *(operator)* — ☑ done
- [x] Create `TAPPaaS/TAPPaaS` on Codeberg; add `codeberg` remote
- [x] Push all branches + tags to Codeberg (Codeberg becomes origin/dev-home) — from here on every change below happens **only on Codeberg**, never visible on GitHub

### Phase 2 — Release 1.1 + merge ADR007 → main *(operator commits/pushes)*
- [ ] Tag current `main` as `v1.1` (final 1.x checkpoint), push tag
- [ ] Move `stable` to the head of `main` (= `v1.1`) — so `stable` on Codeberg is the 1.1 release (the current GitHub `main` HEAD)
- [ ] Merge `ADR007` → `main` — **conflict-resolution merge** (238 vs 21 commits, many files "changed in both"); adapt the 21 app modules to the named-module paradigm
- [ ] Operator commits the resolved merge

### Phase 3 — Reference rewrite *(edits only; operator commits)*
- [ ] Rewrite source-fetch refs to Codeberg (table above)
- [ ] Verify `imageLocation` / `releases/latest` / third-party refs untouched

### Phase 4 — One more test
- [ ] Full install/test on the test system (tappaas1 → tappaas-cicd): node provisions clean, source pulled from Codeberg, images still download from GitHub Releases

### Phase 5 — Promote staging → production *(operator)*
- [ ] Promote `staging.tappaas.org` to `tappaas.org` (site production-domain cutover)

### Phase 6 — Promote `stable` *(operator)*
- [ ] Update `stable` → tested `main` (the pending ADR-007 promote-to-stable); push to Codeberg

### Phase 7 — Community repo
- [ ] Mirror `TAPPaaS/Community` to Codeberg
- [ ] Rewrite `github.com/TAPPaaS/Community` refs (e.g. `docs/ADR/ADR-004-module-catalog-config-cascade.md`)

### Deferred — post-2.0 cutover
- [ ] ⏸ Set up GitHub ← Codeberg **push mirror** (only after a fully-tested stable 2.0)
- [ ] ⏸ Add "migrated to Codeberg" note + archive/settings on GitHub
- [ ] ⏸ Move build images off GitHub — [#414](https://github.com/TAPPaaS/TAPPaaS/issues/414) (Woodpecker port, FreeBSD/UFS on Codeberg runners, image host choice)

## Risks

1. **Conflict-heavy merge** — the 21 `main`-only app commits overlap the ADR-007 refactor; new modules must be *adapted* to the named-module/manager-controller model, not merely merged. Largest effort + risk.
2. **Interim image-tag gotcha** — images stay on GitHub Actions while Codeberg is origin (mirror deferred), so image-build tags (`nixos-template-v*`, `opnsense-firewall-v*`) must be pushed to the **GitHub** remote specifically to trigger builds.
3. **Codeberg raw path scheme** — `/raw/branch/<branch>/…`, not a host swap; every `REPO=` base and its concatenation pattern changes, not just the domain.
4. **Issue-link references** — see the open question above.
5. **`stable` jumps far** — it currently sits at old PR #145; promoting it to 2.0 is a large release-line jump (intended, but wide blast radius).
