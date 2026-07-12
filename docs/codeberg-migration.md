# Codeberg Migration — TAPPaaS/TAPPaaS

Migrating the TAPPaaS **code** repository from GitHub to Codeberg. Tracking issue:
[#97 "Move to CodeBerg"](https://github.com/TAPPaaS/TAPPaaS/issues/97).

> The **Documentation** repo is already on Codeberg (`codeberg.org/TAPPaaS/Documentation`,
> staging.tappaas.org live). This document covers the code repo and the Community repo.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Build-image hosting | **Stay on GitHub Releases (for now)** | Codeberg has per-repo storage quotas and discourages large-binary CDN use; the qcow2 images are multi-GB. Moving them off GitHub is deferred — [#414](https://github.com/TAPPaaS/TAPPaaS/issues/414). |
| Image build pipelines | **Hybrid**: nixos-template build ported to Codeberg Woodpecker (`.woodpecker/build-nixos-template-image.yaml`, publishes to GitHub Releases via a PAT secret); OPNsense build **stays GitHub Actions** | The OPNsense image needs a FreeBSD VM to write UFS2 (`mdconfig`/`growfs`) — impossible on container-based shared Woodpecker runners; its `opnsense-firewall-v*` tags are pushed to the `github` remote. Full port (self-hosted KVM agent) tracked in [#414](https://github.com/TAPPaaS/TAPPaaS/issues/414). The GHA nixos workflow is kept as fallback until the Woodpecker pipeline produces one good release. |
| GitHub repo fate | **Push mirror — only after a fully-tested stable 2.0** | Keeps discoverability/SEO without drift. Until then GitHub stays live but goes stale (Codeberg is the dev home). |
| "Migrated" note / archive on GitHub | **Deferred to the 2.0 cutover** | Same gate as the mirror. |
| New long-lived release branch | **Reuse `stable`** (not a new `stage`) | Promoting `ADR007` (the 2.0 manager/controller paradigm) to `stable` is the pending promote-to-stable step; existing tooling already references `stable`. |
| Release sequence | Codeberg push first, then tag `main` `v1.1` + point `stable` at it → merge `ADR007`→`main` → retest → promote staging → promote `stable` | `v1.1` is the final 1.x checkpoint (`stable` = 1.1 on Codeberg); 2.0 lands on `main` then `stable`. All release work happens on Codeberg. |

## Reference-rewrite scope

**Rewrite to Codeberg** — TAPPaaS-owned *source-code* fetches. Note the raw path scheme differs:
`raw.githubusercontent.com/TAPPaaS/TAPPaaS/<branch>/<path>` → `codeberg.org/TAPPaaS/TAPPaaS/raw/branch/<branch>/<path>`.

All raw bases become `https://codeberg.org/TAPPaaS/TAPPaaS/raw/branch/` — it composes with the
existing `${REPO}${BRANCH}/<path>` pattern unchanged (and fixes the latent missing-repo-segment
in the two `…/TAPPaaS/`-only defaults). Rewritten (☑ = done in Phase 3):

| File | Reference |
|------|-----------|
| `src/foundation/install.sh` | ☑ `REPO=` raw base |
| `src/foundation/cluster/install.sh` | ☑ `REPO=` raw base |
| `src/foundation/cluster/install-platform.sh` | ☑ `REPO=` raw base; clone URLs (×2) |
| `src/foundation/network/config-firewall.sh` | ☑ `REPO=` raw base *(found in Phase-3 sweep)* |
| `src/foundation/tappaas-cicd/bootstrap.sh` | ☑ default clone URL *(found in sweep)* |
| site-manager `create-configuration.sh` / `create-site.sh` / `repository.sh` | ☑ default `--upstream-git` + examples/comment *(found in sweep)* |
| site-manager `test/fixtures/configuration.json`, `test/unit/reconcile.test.ts`, `test-repository/test.sh`, `scripts/README.md` | ☑ fixtures/tests/docs of the same default |
| `src/foundation/cluster/INSTALL.md` | ☑ `REPO=` raw base |
| `src/foundation/cluster/DESIGN.md` | ☑ `REPO`/`BRANCH` default doc |
| `INSTALL.md` | ☑ `REPO=` raw base (×2) |
| `docs/design/ADR-007-migration-runbook.md` | ☑ `REPO=` raw base |
| `docs/ADR/ADR-007d - Site.md` | ☑ clone URL |
| `docs/design/ADR-007-implementation.md`, `docs/ADR/ADR-004…` | ☑ example repo URLs (Community ref stays for Phase 7) |
| `docs/SERVE-CODE-LOCALLY.md` | ☑ prose + clone URL (release-download refs kept on GitHub) |
| `src/foundation/cluster/Create-TAPPaaS-VM.sh` | ☑ UI links → Codeberg repo + issues (fixes mis-cased `TAPpaas`); **Discussions still → GitHub** (Forgejo has no Discussions — revisit at Community migration) |

**Keep on github.com** (per the image-hosting decision) — do **not** rewrite:

| File | Reference |
|------|-----------|
| `src/foundation/network/network.json:57` | `imageLocation` → opnsense release asset |
| `src/foundation/templates/tappaas-nixos.json:24` | `imageLocation` → nixos release asset |
| `src/foundation/cluster/install-platform.sh:266` | `api.github.com/.../releases/latest` |
| all third-party URLs | maurice-w opnsense base, community-scripts/ProxmoxVE, home-assistant, NixOS/nixpkgs, unifi clients, firebase/php-jwt, netbird, minisforum-repo |

**Resolved** — the Codeberg import **preserved issue numbers**, so `…/issues/NNN` links map 1:1.
The 14 `github.com/TAPPaaS/TAPPaaS/issues/NNN` doc links are left on GitHub (it stays live);
they can be mass-rewritten to `codeberg.org/...` any time.

## Tracker

Legend: ☐ todo · ◐ in progress · ☑ done · ⏸ deferred (post-2.0 cutover)

### Phase 0 — Pre-flight
- [x] Reconcile the 21 `main`-only commits vs `ADR007` (litellm, vllm-amd, openwebui, deconz, vaultwarden, nixos-canon C2 fixes) — confirm none are lost by the merge
- [x] Create this tracking doc and issue [#414](https://github.com/TAPPaaS/TAPPaaS/issues/414)

### Phase 1 — Push to Codeberg *(operator)* — ☑ done
- [x] Create `TAPPaaS/TAPPaaS` on Codeberg; add `codeberg` remote
- [x] Push all branches + tags to Codeberg (Codeberg becomes origin/dev-home) — from here on every change below happens **only on Codeberg**, never visible on GitHub

### Phase 2 — Release 1.1 + merge ADR007 → main — ☑ done *(on Codeberg)*
- [x] Tag current `main` as `v1.1` (final 1.x checkpoint), push tag — `v1.1` → `889c61a`
- [x] Move `stable` to the head of `main` (= `v1.1`) — `stable`: `fda21af`→`889c61a` (fast-forward); `stable` on Codeberg is now the 1.1 release
- [x] Merge `ADR007` → `main` — **fast-forward** (`889c61a`→`30b6b87`): `main` was already an ancestor of `ADR007` after the Phase-0 reconcile, so no conflicts here; the 21 app modules were adapted during that reconcile
- [x] Resolved merge already committed in the reconcile (`369cab6` + `b734fca`)

### Phase 3 — Reference rewrite + build pipelines *(edits only; operator commits)*
- [x] Rewrite source-fetch refs to Codeberg (expanded table above — sweep found 8 more files than first scoped)
- [x] Verify `imageLocation` / `releases/latest` / third-party refs untouched (grep-verified; composed raw URL live-probed → HTTP 200)
- [x] Port the nixos-template image build to Codeberg Woodpecker (`.woodpecker/build-nixos-template-image.yaml`) — publishes to GitHub Releases; GHA copy kept as fallback until first good Woodpecker release
- [ ] Enable Woodpecker CI for the repo on Codeberg + add the `github_release_token` secret (PAT, contents:write) *(operator, web UI)*
- [ ] OPNsense image build: stays on GitHub Actions (FreeBSD/UFS2 constraint) — tags go to the `github` remote; Woodpecker port needs a self-hosted KVM agent ([#414](https://github.com/TAPPaaS/TAPPaaS/issues/414))
- [x] **Documentation repo** (`codeberg.org/TAPPaaS/Documentation`, staging.tappaas.org) — same rewrite: `scripts/sync-source.py` now pulls the source tarball from Codeberg (`…/archive/<ref>.tar.gz`), rewrites synced links to `src/branch`/`raw/branch`, and pins **ref `main`** (was `ADR007`; flip to `stable` at Phase 6); `mkdocs.yml` repo button + social link, `overrides/home.html` "Source code" button, and all content deep-links (`blob|tree/ADR007` → `src/branch/main`, issues/milestones/org/LICENSE) → Codeberg. Sync **live-verified against Codeberg@main**; rewritten link styles probe HTTP 200 (incl. `/milestones`). Discussions links stay on GitHub (Forgejo has none — revisit at Phase 7). Next staging build regenerates `docs/generated/` from the promoted 2.0 `main`.

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
2. **Interim image-tag gotcha** — `nixos-template-v*` tags now go to **Codeberg** (Woodpecker builds, publishes to GitHub Releases — needs the `github_release_token` secret + one live validation of runner disk limits); `opnsense-firewall-v*` tags must still be pushed to the **`github`** remote (FreeBSD/UFS2 build stays on GitHub Actions).
3. **Codeberg raw path scheme** — `/raw/branch/<branch>/…`, not a host swap; every `REPO=` base and its concatenation pattern changes, not just the domain.
4. **Issue-link references** — see the open question above.
5. **`stable` jumps far** — it currently sits at old PR #145; promoting it to 2.0 is a large release-line jump (intended, but wide blast radius).
