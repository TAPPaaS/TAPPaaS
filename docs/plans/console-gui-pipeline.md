# Console GUI: a systematic way to develop and test it

Status: accepted by the operator 2026-11-01 (O1–O3 decided below); in implementation. Scope: the console (`src/foundation/tappaas-cicd/ui`, "ui" below), its web app (`ui/web`), and how Claude sessions work on it. Answers the eight points of the operator's direction of 2026-11-01.

## 0. Where we stand

- **Tests.** ~52 pure unit tests in `ui/test/unit` (server routes, jobs, reads, wizards, stepform, health graph, assets, …), run by `ui/test.sh` against a fake `Runner` fed with JSON captured from hrossen (`ui/test/fixtures`, recorded 2026-10-17). "There is no DOM here" (README): the web app's logic modules are tested as pure functions; nothing renders, nothing clicks. No browser, end-to-end or screenshot test exists; `web/package.json` has only dev, build and typecheck.
- **Fixtures.** `CONSOLE_FIXTURES` is read only by test code. The running server always runs real managers. So every visual check this month went through hrossen: build the dist in a nix scratch copy, commit it, push, refresh, look in the browser pane. That loop costs a push per look and a screenshot per question.
- **Dry runs.** Every console verb has a manifest `preview.kind`: `apply-flag` (the verb without `--apply` is the plan), `dry-run-flag` (`--check`/`--dry-run`) or `none` (no dry run; the preview just states the argv). The jobs layer runs the preview before the apply and stops on a refusal; destructive verbs need the name typed. `TAPPAAS_CMDB=off` only silences CMDB reporting. No variable stopped writes before `TAPPAAS_SIMULATE` (§6).
- **Reverse pairs** already in the console: node add/delete, asset add/remove (+place/unplace, dispose), cable add/remove, ssid add/remove, room/rack/location add/delete, ack/unack, zone enable/disable, identity add/delete, module modify (set the old value back). Module add/install has no console reverse; node add costs ~40 minutes.
- **Style.** One stylesheet (`web/src/styles.css`, 729 lines) with 16 colour tokens on `:root`, status colours again in `colors.ts`, no spacing scale, no theme, breakpoints by hand at 640, 700, 900, 1100, 1250 px; one `matchMedia(700)` in Health. No `.interface-design/` anywhere.

The week's GUI bugs (a disabled button with no job, an output panel not following the last line, a wizard step collapsing on select, "bay" without its heading, a spurious model-made word) are all of the kind a rendered, scripted check finds and a pure unit test cannot.

## 1. Sessions and models: who does what

| Work | Who | Why |
|---|---|---|
| Design decisions, wording, review of diffs and screenshots, merges to `adr-041`, talking to the operator | the parent session (this one) | keeps the context and the taste; the costly model is spent on judgement, not on typing |
| Coding a GUI change, with its unit test and its visual check | one Opus session per change, own worktree cut from `adr-041` (`start_session`, model opus) | the standing rule; a coding session that also runs the loop of §2 hands back a change that is already seen |
| Surveys, reading logs, capturing fixtures, running the capture and diff scripts, copying a dist | Sonnet subagents (`Agent`, model sonnet) | mechanical, read-mostly, long output that must not land in the parent's context |
| Grepping, chmod, tar pipes, one-line checks | Haiku subagents or a plain Bash call | no judgement needed |

Rules that save tokens:

- **A screenshot is the last resort.** `read_page` / `get_page_text` first (text and structure, a few hundred tokens); `zoom` on a region for an icon; a full screenshot only for layout, at `scale 0.5` unless pixels are the question. One screenshot per page and viewport, never one per step.
- **Diffs, not pages.** The pipeline of §2 writes images to disk and compares them by script; only the *diff* image (and only when the diff is above threshold) is shown to a model, at the smallest scale that answers the question.
- **One brief, named files.** A sub-session's brief names the pages, the fixtures, the viewports and the done-criterion ("the capture shows no diff outside `pages/Overview.tsx`'s routes"). No "based on the findings".
- **No same-model subagents** for coding (memory rule). A fork only when the task needs this conversation; otherwise fresh.
- **The fixture server, not hrossen,** for anything that does not need a live Proxmox: the loop runs on the Mac in seconds and costs no push.

## 2. The closed-loop visual pipeline

```
edit web/src  ──►  vite build (Mac, ~10 s)  ──►  console server in fixture mode (Mac)
     ▲                                                     │
     │                                           playwright capture: routes × viewports
     │                                                     │
     │                                           pixel diff against baseline/  ──► report.md + diff/*.png
     │                                                     │
     └──── the coding session reads report.md, looks only at diff images, fixes ────┘
```

Pieces, all under `ui/`:

1. **Fixture mode for the running server** (done; the keystone; `ui/README.md`, `ui/test/fixtures/README.md`). `CONSOLE_RUNNER=fixtures` (with `CONSOLE_FIXTURES=<dir>`) makes `main.ts` build the server on a `FixtureRunner` and CMDB promoted from the test fakes into `src/fixtures.ts`. Reads answer from the captured JSON; a *preview* answers with `fixtures/jobs/<slug>.preview.txt` when there is one, else the argv line; an *apply* with `fixtures/jobs/<slug>.apply.txt`, else "applied (fixture)", exit 0; and every call goes to a journal the test can assert on (`CONSOLE_FIXTURES_JOURNAL`). Nothing is executed. Sign-in: fixture mode trusts the `X-Console-Actor` header (default `operator`), so no Authentik is needed. `CONSOLE_NOW` stops the server's clock. Started on the Mac with `ui/fixture-server.sh [--port] [--fixtures]`; the unit tests keep a frozen set in `fixtures/2026-10-17/`, so a refresh breaks none of them.
2. **Capture script** `web/e2e/capture.ts` (done; Playwright, see §3): for each route in `web/e2e/routes.json` (every page, each side panel opened by a `?select=`, each wizard at step 1) and each viewport of §4, load, wait for network idle, fail on any console error or 4xx/5xx, write `shots/<viewport>/<route>.png` and `shots/<viewport>/<route>.txt` (the accessibility text, cheap to diff and to read).
3. **Compare script** `web/e2e/compare.ts` (done; pixelmatch): against `baseline/`, writes `diff/<viewport>/<route>.png` only where the mismatch is above 0.1 % of pixels, and `report.md`: a table of route × viewport with the mismatch and a link, plus the text diffs. The report is what the model reads.
4. **Flows** `web/e2e/flows/*.spec.ts` (done): the wizards and operate buttons as scripted clicks against fixture mode: Remove node (pick, Continue, check, radio, typed name, Remove, output visible, step 3 wording), Add node step 1, Ack dialog (type fixed, note blank, date picker, quoted `--until`), the Output panel's stick-to-last-line. Each asserts on text and on the recorded argv, which is exactly the class of bug found this week.
5. **One command** (done): `ui/web/e2e/run.sh [--update-baseline] [--routes …] [--viewports …]` does build, serve, capture, compare, and prints the report path. The coding session's loop is: edit, `run.sh`, read `report.md`, open a diff, fix.

Baselines are regenerated on purpose (`--update-baseline`) after the operator has accepted a look, and committed (see §7 for size).

## 3. Which browser

Three are available and they do not compete:

| | Built-in browser pane | Claude in Chrome | Playwright (script, in `web/e2e`) |
|---|---|---|---|
| Who sees it | the operator, live, signed in to hrossen | the operator's own Chrome | nobody; files on disk |
| Cost per step | a tool call plus a page read or screenshot | the same | zero model tokens; the script runs |
| Determinism | window size of the pane; shared profile | the user's window | exact viewport, fresh context, repeatable |
| Use for | reviewing with the operator on hrossen ("look at health?select=…"), exploratory checks, anything that needs a real sign-in | when the operator asks for it by name | the pipeline of §2, regression (§7), every automated capture |

Decision: **Playwright as a dev dependency of `ui/web`** (`@playwright/test`, Chromium only), driven by scripts, is the testing browser. Not the Playwright MCP server from the plugin catalog: an MCP step costs a model turn per click, a spec file costs none; the MCP server stays optional for ad-hoc driving of a page the scripts do not cover. The built-in pane keeps its role for review with the operator. On hrossen, Chromium comes from nixpkgs (`playwright-driver.browsers`) when the suite runs there; on the Mac `npx playwright install chromium` once.

## 4. Viewports

Named sizes, used by the capture, the flows and the CSS:

| Name | Size | Stands for | Today's breakpoint it maps to |
|---|---|---|---|
| `phone` | 390 × 844 | a phone held upright; the Health check on the go | ≤ 640 (Overview, forms), 700 (`phone()`) |
| `tablet` | 820 × 1180 | an iPad in the rack room, the Physical view's drag and drop | 900 (`.two` collapses) |
| `laptop` | 1366 × 768 | the common laptop; the dense target | 1100 (drawer margin) |
| `desktop` | 1920 × 1080 | the operator's screen; graphs and the rack view | ≥ 1250 |

The six hand-written breakpoints become four tokens (`--bp-sm: 640px`, `--bp-md: 900px`, `--bp-lg: 1100px`, `--bp-xl: 1250px`) and the 700 px `phone()` moves to `--bp-sm`; this is a mechanical change with the capture as its proof (no diff at the four sizes, or only the intended one). Every page is captured at all four; flows run at `phone` and `laptop`. `resize_window` in the built-in pane uses the same four names for reviews.

## 5. The design system file: `.interface-design/system.md`

The interface-design plugin (community, `Dammyjay93/interface-design`; not in the org catalog, added with `/plugin marketplace add Dammyjay93/interface-design`) keeps the structural constraints in `.interface-design/system.md` and loads it in every session; `/interface-design:extract` seeds it from existing code, `/interface-design:audit` checks code against it. Plan:

- Direction **Precision & Density** (tight, technical, monochrome; dev tools and admin dashboards): a cool slate foundation, borders-only depth, a 4 px spacing scale. That is what the console already is, with the status colours as the only chroma.
- Tokens: extract the 16 `:root` colours from `styles.css` (and fold `colors.ts` into them, one source), add the spacing scale (4/8/12/16/24/32), the two radii (controls 4 px, panels 8 px), the type scale, the four breakpoints of §4, and the status semantics (pass/warn/fail/skip with their `-bg` pairs).
- Patterns: the side panel with "Details" at the top, the wizard step (`StepRow`, `ActStep`, `CheckStep`, `DecideStep`), the job output panel, the tile grid of Overview, the tree of Assets. Each with its one place in the code.
- Wording rules live there too, since they are constraints on new components as much as colours are: the operator's words (the machine's asset record, the primary location), no flags or internals in a wizard, one button per step, a Continue after a selection.
- The file sits at the repository root (the plugin reads `.interface-design/` from the working directory; sessions on the console run from the repo root or a worktree of it) and says in its first line that it covers the console only. `audit` runs in the loop of §2 before the capture.

## 6. Non-destructive testing on hrossen

Three layers, cheapest first; a test uses the lowest layer that answers it.

**Layer A: fixture mode (no hrossen at all).** §2.1. Covers every look, every wording, every flow's click path and the argv it produces. The fixtures are refreshed by a Sonnet subagent with `ui/test/fixtures/capture.sh` (new: runs the read verbs on hrossen and stores their JSON; the current ones date from 2026-10-17 and predate ADR-040/041/042). Cost: seconds, no tokens beyond the report.

**Layer B: hrossen, nothing changes: `TAPPAAS_SIMULATE=1`.** The operator's idea, placed where it is enforceable: not in every manager, but in the two choke points every console job goes through.

- `ui/src/jobs.ts`: with `TAPPAAS_SIMULATE=1` in the console's environment, an *apply* runs the verb's **preview** argv instead (the plan, `--check`, or for `none` nothing) and reports it as "simulated: would run `<argv>`" with exit 0; the preview itself runs as today. Reads are untouched. The journal and the job list show the job as simulated. This gives the real system's real plan (the preview is the real manager reading the real site) with no write.
- `lib/ts/src/exec.ts` and `lib/common-install-routines.sh` (the shared exec wrappers): with `TAPPAAS_SIMULATE=1`, a command whose first words are on the mutator list (`pvesh set|create|delete`, `qm`/`pct` state verbs, `ssh … apply`, `nixos-rebuild`, `zfs create|destroy`, writes under `config/` through the config helpers) is logged as `[simulate] <argv>` and returns 0 with empty output; everything else runs. This is the safety net under layer A's assumption that previews never write; a manager that writes in its preview is found by this list, not by the operator.
- What it cannot do: produce the *output* of a real apply (a job's result lines). That is layer A's recorded transcript, or layer C.

Built (step 5). The operator's switch is `/etc/tappaas/console.env`, read by `tappaas-console.service` without a rebuild (`ui/README.md`, "Simulate mode"). The list is `lib/simulate-mutators.txt`, one file both wrappers read, with bash's commands shadowed by functions because the scripts call `qm` and `ssh` directly; a script on the stdin of `ssh … bash -s` is judged too. Reads on a listed tool stay runnable: `zpool`, `pvesm` and `ha-manager` list their writing verbs, not the whole command, so `zpool list` still answers a plan. Secrets are refused on all three routes; the CMDB gets no report and no spool. Proof on hrossen 2026-11-01, from a scratch build: `asset-manager asset add zz-sim-test` printed `[simulate] write …/positions.json` and `[simulate] cmdb report change`; all 526 config files, the last sweep (11183) and the empty spool stayed as they were, and `ssh root@tappaas1 'qm stop 99999'` was logged and skipped by both wrappers while `qm list` ran.

**Gaps.** The first choke point is the guarantee: an apply never runs, only its preview. The net under it holds a preview that writes through the wrappers. These do not go through them, so a preview that used one would write.

- TS spawning directly: `lib/ts/src/cluster.ts`, `cli.ts`; `site-manager` `main.ts`, `provision.ts`, `storage.ts`, `usb.ts`, `media.ts`, `client.ts`, `nodeasset.ts`, `port.ts`; `backup-manager` `main.ts`; `health-manager` `main.ts`, `security.ts`, `client.ts`; `identity-manager` `primitives.ts`; `network-manager` `planes.ts`; `switch-controller`; `cmdb-controller` `rescan.ts`. Most start another manager or a bash script, which is gated on its own, or only read. Those that reach a mutator directly: `site-manager` `storage.ts`, `usb.ts`, `provision.ts` (ssh).
- Config written around `writeJsonAtomic`: `backup-manager` `modify.ts`, `peers.ts`; `environment-manager` `bootstrap.ts`, `clients.ts`, `config.ts`, `main.ts`; `health-manager` `emit.ts`, `security.ts`; `identity-manager` `entity.ts`; `network-manager` `zonesmerge.ts`; `site-manager` `hold.ts`, `unitrun.ts`, `provision.ts`; `storage-manager` `store.ts`; `module-manager` `main.ts`; `switch-controller`.
- Bash writing `${CONFIG_DIR}` directly: `rename-instance.sh`, `migrate-firewall-to-network.sh`, `notify-update-failure.sh`, `tappaas-self-prepare.sh`.
- 34 of the 113 bash scripts that call a listed command do not source the lib. A bash child of one that does inherits the gate; a script started otherwise, or run on a node (`ssh node ./script.sh`), does not.
- Not on the list: `pct exec` and `qm guest exec` (they can read or write), OPNsense and UniFi API calls (`curl`, the controllers), `git`, `nix build`.
- `update-tappaas.service` does not inherit the console's environment; `systemctl start` of it is held by the list.

**Layer C: hrossen, real changes with a reverse.** For what must really run (a new verb's apply, an installer path, the CMDB's reaction). Rules, from this month's experience:

- Only verbs with a reverse in the table of §0, under test names (`test-…`, `zz…`) so a sweep names them.
- Each live test is a script with three phases, **setup, check, teardown**, and the teardown runs even on failure (memory: live tests end with an executed teardown and a leftover check). The leftover check is `cmdb sweep` showing 0 new missing and the module/guest/asset counts back to the before picture; the deep test's `cmdb_end` helper covers fixtures edited by hand.
- `pgrep` for another session's run first; never during the operator's boundary; never on makerfloss.
- Node add/delete is layer C's most expensive test (40 minutes, tappaas4); it runs on request, not in a loop.

The deep test (`site-manager test --deep`) stays the proof of layer C across the whole system, with its new timeouts; it is not a GUI test.

## 7. GUI regression test

- `ui/web/e2e/` holds `routes.json`, `capture.ts`, `compare.ts`, `flows/*.spec.ts`, `baseline/<viewport>/<route>.png` and the `.txt` siblings.
- **What a regression is:** a console error or a non-2xx on any route; a flow assertion failing; a text diff on a route not named in the change; a pixel diff above threshold on a route not named in the change. A diff on a route the change names is shown, not failed.
- **Where it runs:** `ui/test.sh` gains a `--visual` step (skipped without Chromium, like the `--deep` curl today), and `scripts/test/test-console-visual.sh` runs it from the tree tests when `web/node_modules` exists. It is **not** in the 5-minute update path: it is a developer and pre-push check, and part of every GUI coding session's done-criterion ("`run.sh` clean, or the diff is the intended one and the baseline updated").
- **Size:** 40 routes × 4 viewports × ~80 KB is ~13 MB of PNG in git and churns on every intended change. Keep `baseline/` to `phone` and `laptop` in git (~6 MB, refreshed only on accepted changes), and keep the other two viewports' baselines out of git, rebuilt on the Mac on demand. The `.txt` siblings are tiny and always in git; they catch most regressions on their own.
- **Flake control:** fixture mode is deterministic (fixed data, fixed time via `CONSOLE_NOW`), animations off through a `prefers-reduced-motion` emulation, fonts from the dist, one Chromium version pinned by the package lock.

## 8. Skills that help a session understand the GUI

- **A repo skill `.claude/skills/console-gui/SKILL.md`** (loaded when a task touches `ui/`): the route map and where each page, panel and flow lives; the preview/apply contract and `preview.kind`; the step components (`ActStep`, `CheckStep`, `DecideStep`, `StepRow`) and the job panels (`JobStatusLine`, `JobOutput`, `Output`) with "use these, never a new one"; how to run fixture mode, `run.sh` and the flows; the four viewports; the wording rules; and the review checklist the operator applied this month (does the step collapse on select; is there a Continue; is the button ever disabled without saying why; does the output stick to the last line; is there a word the operator did not use). The survey `docs/plans/console-flow-survey.md` and ADR-034 are its references.
- **The Design plugin (Anthropic, in the org catalog)** for `design-critique` and `accessibility-review` on a captured page: run by a Sonnet subagent on the `.txt` tree and one screenshot, returning findings, not pages.
- **The interface-design plugin** (§5) for `status`, `audit` and `extract`.
- **Reading a GUI cheaply** goes in the skill as rules: `read_page` with `filter: interactive` to find controls, `find` by label, `zoom` for icons, screenshot at 0.5 for layout, and the capture's `.txt` instead of the live page whenever fixture mode has the route.
- The `frontend-design` plugin is for building new UIs from scratch; it is not for this console and is not proposed.

## Plan

| Step | What | Session | Proof |
|---|---|---|---|
| 1 **done** | Fixture mode for the server (`CONSOLE_RUNNER=fixtures`, `src/fixtures.ts` from the test fakes, actor header, `CONSOLE_NOW`); `test/fixtures/capture.sh`; refresh the fixtures from hrossen | Opus | the console runs on the Mac against fixtures; every page opens |
| 3 | **Done.** `.interface-design/system.md` written by a session from the stylesheet (direction, spacing, radii, breakpoints, patterns, wording); fold `colors.ts` into the tokens; breakpoints to tokens; our own audit check | Opus | the audit check clean; capture shows no diff (the capture to rerun once step 2 lands; for now the resolved CSS differs from before only in the media queries of §4) |
| 2 **done** | Playwright in `web/`; `routes.json`, `capture.ts`, `compare.ts`, `run.sh`; first baselines at the four viewports (82 routes, `.txt` in git, PNGs local per O1; `ui/README.md`) | Opus | `run.sh` clean twice in a row (about 2½ min; one route at one size about 8 s); the flakes it found were the graphs' own, fixed in `graph.tsx` and `deviceview.tsx` |
| 4 **done** | Flows for Remove node, Add node step 1, Ack, Output stick (`web/e2e/flows`, phone and laptop, in `run.sh`; fixture jobs may be paced, `jobs/<slug>.<phase>.pace`) | Opus | the flows pass (about 30 s), and each fails when its bug is reintroduced (checked by hand with a throwaway edit per bug; the output panel's old freeze, a race, is not reproduced at the fixtures' pace) |
| 5 *(done)* | `TAPPAAS_SIMULATE=1` in `jobs.ts` and the exec wrappers; a layer-C test script template with setup/check/teardown (`ui/test/live-test-template.sh`) | Opus | a simulated apply on hrossen writes nothing (sweep unchanged) |
| 6 **done** | `--visual` in `ui/test.sh`, `test-console-visual.sh` (exit 77 where it cannot run, and under the pre-update gate), the repo skill (done separately) | Opus | `ui/test.sh --visual` on the Mac; the skill loads on a `ui/` task |

Steps 1 and 2 are the loop; 3 to 6 can follow in any order. Each is a session of its own on a branch cut from `adr-041`, merged here after review.

## Open questions for the operator

- **O1** *(decided)* No PNG baselines in git. `run.sh` reuses the baseline stored locally (`ui/web/e2e/baseline/`, git-ignored, stamped with the commit it was made from) and regenerates it from the base commit when there is none or the stamp is stale. The `.txt` siblings are in git.
- **O2** *(decided)* `TAPPAAS_SIMULATE` is an environment variable of the console service, switched by the operator; a per-job toggle may come later.
- **O3** *(decided)* No dependency on the community plugin (no side-loaded code): the console copies the essence — the `.interface-design/system.md` format with Direction, Tokens and Patterns, an `extract` done once by a session, and an `audit` written as our own check (`scripts/test/test-console-design.sh`: tokens used, no raw colours or spacings in `web/src`).
