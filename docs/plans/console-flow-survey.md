# Console flow survey: Change / Preview / Apply / Result

Scope: `src/foundation/tappaas-cicd/ui` in `/Users/larsrossen/src/TAPPaaS-adr041`. Paths below are relative to `ui/web/src` unless they start with `src/` (the server) or `manager/`. This was a read-only survey; nothing was changed.

## 0. What decides the flow (needed to read the tables)

- **The verb's preview kind** comes from the manager's `--help --json` (`lib/ts/src/help.ts:412-418` `defaultEffect`, `:469-473`). For bash tools it comes from `ui/manifest/bash-verbs.json`. There are four kinds:
  - `read`: StepView shows one **Run** button and no stepper (`operate.tsx:321-327, 339-341`).
  - `apply-flag` (`--apply`): the preview runs the verb without `--apply`. A plan or a delta.
  - `dry-run-flag` (`--check` / `--dry-run`): a real dry run, usually a refusal check.
  - `none` (`effect: { noPreview }`): **there is no dry run.** A Preview click starts no process. The server writes "… has no dry run. Apply runs exactly: …" and marks the job done (`src/jobs.ts:466-477`). StepView labels the button "Preview (no dry run)" (`operate.tsx:340`). Many wizard notes say so outright ("There is no dry run: the preview is the command": `Adopt.tsx:133`, `Buddy.tsx:75,77`, `Enrol.tsx:75`, `Satellite.tsx:77`, `ResetPassword.tsx:52`, `nodepools.tsx:72`, `Wifi.tsx:70`, `Modules.tsx:248`).
- **Destructive** means the verb word matches `delete|purge|retire|erase|discard|remove*`, or the verb sets `destructive: true` (`help.ts:345, 446-456`). It needs the object's name typed (`operate.tsx:286, 291-296, 331-337`). The server checks the same rule (`src/jobs.ts:531-533`).
- **Apply without Preview** is already supported: `applyNowJob` makes one job that runs the dry run first and applies only after a clean one (`api.ts:142`, `src/jobs.ts:524-543, 680-697`). For a `none` verb it applies at once, with no `previewPhase`.
- **StepView** (`operate.tsx:252-370`) is the generic step. It shows the four-pill stepper (`:322-326`), the form (`StepForm`, `:241-250`), the command (`:330`), the typed name (`:332-337`), **two buttons, Preview and Apply** (`:339-346`), then `JobView` for the preview (`:353`) and `TwoPhaseView`/`JobView` for the apply (`:360`). **Operate** (`:372-386`) stacks StepViews in a `Wizard` modal (`wide={false}`). **OperateButton** (`:390-411`) is the button that opens it.

## 1. Every place the concept is used

Legend:
- **Kind**: R = read, A = apply-flag, D = dry-run-flag, N = none (no dry run).
- **Typed**: the operator types a name before the change.
- **What the operator sees**: stages/steps × buttons per step. A StepView always means a 4-pill stepper with Preview + Apply buttons, or 1 Run button for a read.

### 1a. Wizards (pop-ups with their own `StepRow` stages)

| Wizard (file) | Component per stage | Verb(s) | Kind | Typed | What the operator sees |
|---|---|---|---|---|---|
| Remove a node (`pages/RemoveNode.tsx`) | **custom** `RemoveStep` (`:135-325`): check at once, findings, typed name, one button, inline output | `site-manager node delete <n> --shutdown/--erase/--lost` (check = no `--apply`); then `--apply --yes --asset` | A | yes (local, `:308-311`) | 3 stages; stage 2 = 1 button. **Reference pattern.** |
| Add a node, stage 0 (`pages/AddNode.tsx:334-392`) | `StepView` ×2 (`:347`, `:362`) + ProgressBar | `node media prepare`; `node usb write <node> <dev> --yes` | N, N | no | 8 stages in all (0, 1, 2, 3, 4, 5a, 5b, 6). Stage 0 has two full steppers, and both Previews are no-ops. |
| Add a node, stage 1 | **custom** `DeclareStep` (`:499-589`) + `DeclaredLine` (`:484-492`) | `site-manager node add <N> …` | **N** (`manager/site-manager/src/main.ts:155`) | no | form + 1 button. **Reference pattern.** |
| Add a node, stage 3 | raw status line + `Output` (`:442-448`); `OperateButton` "Register joined nodes" (`:452`) | `node add` job watched; `node reconcile` | –, A | no | live output; the reconcile pop-up is the full stepper |
| Add a node, stage 4 | `NodePools` → `StepView` (`physical/nodepools.tsx:119`) | `node storage add <node> <pool>` | N | no | full stepper per pool (no-op Preview) |
| Add a node, 5a/5b (`pages/NodeUplinks.tsx:108,112,170`) | `StepView` ×2 / ×1 | `node network set`, `node network test` | A, A | no | stepper; the preview checks the declaration on the node (drain + rollback ahead) |
| Adopt a machine (`pages/Adopt.tsx`) | `StepView` ×2 (`:225-226`), `StepView` (`:235`), `JobView` on resume (`:235`), nested `Operate` (`:245`) | `switch-manager update-port` → `switch-manager reconcile`; `module-manager adopt`; `asset-manager place` | N, A, N, D | no | 4 stages; stage 2 = 2 steppers, stage 3 = stepper with a no-op Preview, stage 4 = a modal over the modal |
| Add a backup buddy (`pages/Buddy.tsx`) | `StepView` (`:122`), `StepView` read (`:127`), `JobView` on resume | `backup-manager peer add pull/remote`; `peer check` | N, R | no | 3 stages; no-op Preview; check = Run click |
| Enrol a device (`pages/Enrol.tsx`) | `StepView` (`:160`) with `after` (config `Output` + download, `:106-115`); `JobView` on resume (`:156`) | `network-manager wgvpn add-peer` | N | no | 3 stages; no-op Preview |
| Add a satellite (`pages/Satellite.tsx`) | `StepView` (`:178`), `StepView` read (`:181`), `JobView` on resume | `module-manager add satellite`; `module-manager test` | N, R | no | 4 stages; no-op Preview; test = Run click |
| WiFi (`pages/Wifi.tsx`) | `StepView` ×2 (`:148-149`), secrets POST (`:78-86`), `StepView` (`:181`) | `ap-manager ssid remove` / `ssid add` / `ssid modify`; passphrase; `ap-manager reconcile` | N (remove destructive), N, A | `ssid remove` yes (StepView) | 5 stages; up to 3 steppers |
| Reset a password (`pages/ResetPassword.tsx`) | `StepView` (`:121`) with `after` link; secrets POST (`:65-74`) | `identity-manager user reset-password --link`; `--password-stdin` | N | no | 3 stages; no-op Preview |
| Backup keys (`pages/BackupKeys.tsx`) | **custom, not a job**: `post("secrets/backup-keys")` (`:51-63`), result in a raw `<pre>` (`:125`) | `backup-manager key export --usb … --password-stdin` | – | no | 3 stages; 1 button; no live output, no Stop |
| Data pools (`physical/nodepools.tsx:135-147`, `AddPoolButton`) | `Wizard` → `NodePools` → `StepView` | `node storage add` | N | no | same as Add node stage 4 |

### 1b. Operate dialogs (`OperateButton` / `Operate` → `StepView` per step)

| Page (file:line) | Buttons → verb(s) | Kind | Typed | Steps |
|---|---|---|---|---|
| Setup Day 1 (`pages/Setup.tsx`) | Issue certificate `acme-setup.sh` (`:289`); Bootstrap identities `identity-manager bootstrap` → `reconcile` (`:295-302`); Register the switch `add-controller` → `interrogate` → `switch-manager reconcile` (`:308-316`); Install backup/identity/logging `module-manager add` (`:332`); Test (`:333`); Publish console `module-manager add console` (`:335`); Add a stack `module-manager add-stack` (`:70`) | N; N→A; N→N→A; N; R; N; D (`--dry-run`) | no | 1, 2, 3, 1, 1, 1, 1 |
| Day 2 (`pages/Day2.tsx`) | Add room (`:116`), Add rack (`:164`): `asset-manager room/rack add`; Add environment (`:210`): `environment-manager add` → `reconcile <env>`; Add user (`:213`): `identity-manager user add --no-reconcile` → `reconcile`; Place… `Operate` (`:90-94`): `asset-manager place` | D; N→A; N→A; D | no | 1, 2, 2, 1 |
| Module page, Operate (`pages/ModuleOperate.tsx`) | Update (`:22`) `module-manager update`; Reconcile (`:30`); Test (`:35`); Test --deep (`:36`); Snapshot VM (`:42`); Resume/Suspend (`:49-51`); Delete (`:57-73`) | N (disruptions); A; R; R + `writeWhen --deep` (a write with no dry run); N (`--restore/--cleanup` destructive); N; N **destructive** | Delete | 1 each |
| Module config (`pages/ModuleConfig.tsx:142-163`) | `Operate` fieldsStep `module-manager modify` | D (`--dry-run`, the pre-gate's change classes) | no | 1 |
| Modules catalogue (`pages/Modules.tsx:228`) | Install `module-manager add` | N | no | 1 |
| Module sections (`pages/ModuleSections.tsx:71`) | operations a module declares | varies | varies | 1 |
| Zones (`pages/Zones.tsx:164-194, 292-293`) | Modify (fieldsStep `network-manager modify`) → reconcile; enable/disable/manual → reconcile; Bind; Reconcile; Add one like it / Add a zone (`add --check`); Delete (`delete --check`) | N→A; N→A; N; A; D; D **destructive** | Delete | 2, 2, 1, 1, 1, 1 |
| Environments (`pages/Environments.tsx:79, 200-208`) | Add (2 steps); Modify (fieldsStep); Reconcile; Delete (`--check`); Show | N→A; N; A; D **destructive**; R | Delete | 2, 1, 1, 1, 1 |
| Identity (`pages/Identity.tsx:59-62, 151, 174`) | Show; Modify / Add (fieldsStep `--no-reconcile` → reconcile); Delete (→ reconcile); Reconcile with Authentik | R; N→A; N **destructive**→A; A | Delete | 1, 2, 2, 1 |
| Backup (`pages/Backup.tsx:125, 235-262, 285`) | Site modify (`--check`); Pulse / All restore points / Placement / Show / Coverage / Restore points / Peer check; Reconcile the PBS job; Modify (`backup-manager modify`); Purge | D; R ×7; A; N; N **destructive** | Purge | 1 each |
| Site (`pages/Site.tsx:59, 124, 184, 197-219, 256-275, 307-318`) | Register joined nodes; site modify ×2; Release train preview/status; Reconcile repositories; Sync; Release; Hold; Stashes; Location add/modify/delete; **Update now** (`site-manager update`, sweep plan, disruptions) | A; D; R; A; D; N; N; R; D/D/D **destructive**; D | location delete | 1 each |
| HealthPanel (`pages/HealthPanel.tsx:47, 49, 60`) | Ack / Unack / Maintenance (`manager/health-manager/src/emit-verbs.ts:30-44`) | N | no | 1 |
| Assets / Physical (`pages/Assets.tsx:209-271, 363-365`, `pages/Physical.tsx:162-209`) | room add/modify/delete, rack add/modify/delete, faceplate add | D (room/rack delete **destructive**) | deletes | 1 |
| AssetPage (`pages/AssetPage.tsx:113-142, 296-297`) + `physical/disks.tsx:87-160, 171-172` | Receive, Move to (`place`), Take out (`unplace`), Change (`disk modify`), Faulty/Repaired, Dispose (`asset dispose`), Remove the record (`disk remove`), Port… (`port modify`), Remove the cable (`cable remove`), Record a cable (`cable add`), Record a disk, Adopt the disks | D (all asset-manager `--check`); **destructive**: `unplace` (`main.ts:186`), `asset dispose` (`destructive: true`), `disk remove`, `cable remove` | destructive ones | 1 |
| Device ops (`physical/deviceops.tsx`) | Change port (`:52`: `update-port` → `switch-manager reconcile`); Park (`:53`: `remove-port` **destructive** → reconcile preview); Network show/set (`:62-75`); asset modify/remove (`:129-130`); cable split/join (`:141-178`); lifecycle (`:248-252`) | N→A; N→A; R/A; D; D; D | Park, remove, dispose | 2, 2, 1… |
| Rack ops (`physical/rackops.tsx:243-278`) | Place…, Move to…, Change placement…, Unplace…, Add a room, Record a device, Record… | D (unplace **destructive**) | Unplace | 1 |
| Locations (`locations.tsx:136`) | `switch-manager modify-switch` / `ap-manager modify` | N | no | 1 |
| Assistant card (`assistant.tsx:154-247`) | any proposed verb | any | yes (local, `:168, 230-236`) | **custom**: Preview + Run; **Run needs a preview first** (no `applyNowJob`) |

About 110 `OperateButton` call sites in total (counted per file): deviceops 14, Site 14, AssetPage 12, Backup 11, Assets 9, Zones 8, ModuleOperate 8, rackops 8, Setup 7, Environments 5, Identity 5, Day2 4, HealthPanel 3, Physical 3, disks 2, and 1 each in locations, ModuleSections, Modules, AddNode. There are 3 bare `<Operate>` uses: `Adopt.tsx:245`, `Day2.tsx:90`, `ModuleConfig.tsx:142`.

## 2. Proposal per use

Two patterns:
- **RN** (Remove-node): the check runs at once, findings are shown, one button, output inline.
- **AN** (Add-node): a form, one button, output inline, a one-liner when collapsed, Try again on failure.

The test for each: does the operator **read** something produced by the preview before deciding?
- For `none` verbs the "preview" only echoes the command, so the Preview button is pure friction.
- For `dry-run-flag` verbs that are refusal checks, `applyNowJob` already runs the check first, so the answer can be shown inline.
- For `apply-flag` verbs whose preview is a plan or delta covering more than the operator's own change, the preview must stay. It can still **run at once when the step opens** (the RN "check at once"), which saves the click without hiding the plan.

### Do first (most operator pain, little effort once `ActStep` exists, see plan step 3)

| Use | → | Why | Effort |
|---|---|---|---|
| Adopt stage 3 `module-manager adopt` (`Adopt.tsx:235`) | AN | N: the Preview is a no-op; the note already says so | small |
| Buddy stage 2 `peer add` (`Buddy.tsx:122`) | AN | N | small |
| Enrol stage 2 `wgvpn add-peer` (`Enrol.tsx:160`) | AN (keep `after`: config + Download) | N | small |
| Satellite stage 3 `module-manager add satellite` (`Satellite.tsx:178`) | AN | N; a long job, so a live inline output and Stop matter | small |
| Reset password, link (`ResetPassword.tsx:121`) | AN (keep `after`: the link) | N | small |
| Add node stage 0 `node media prepare`, `node usb write` (`AddNode.tsx:347, 362`) | AN (keep ProgressBar) | N; two steppers inside one optional stage | small |
| Data pools `node storage add` (`nodepools.tsx:119`) | AN | N; one stepper per pool | small |
| WiFi `ssid add` / `ssid modify` (`Wifi.tsx:149`) | AN | N | small |
| WiFi `ssid remove` (`Wifi.tsx:148`) | AN plus a typed name | N, destructive | small |
| Buddy `peer check`, Satellite `test` (`Buddy.tsx:127`, `Satellite.tsx:181`) | RN-style read: run when the stage opens | R; today the operator must click Run | small |
| **All `none` verbs in Operate dialogs**: ack/unack/maintenance, backup modify, repository hold/release, zone bind, module install/add console, resume/suspend, snapshot-vm, acme-setup, modify-switch/ap modify, `update` | AN, decided inside StepView by `previewKind === "none"` | about 30 buttons; the stepper's "Preview (no dry run)" step means nothing | medium (one change in StepView, plan step 6) |

### Later (medium; worth it, but the check result needs some UI)

| Use | → | Why | Effort |
|---|---|---|---|
| **Destructive D verbs**: asset remove / dispose, disk remove, cable remove, unplace, room/rack/faceplate delete, location delete, zone delete, environment delete | RN | the `--check` is a refusal check ("still placed", "still in a role"); the operator needs only the verdict, then the typed name and one button | medium (generic `CheckStep`; findings from the exit code + tail; no per-verb parser like `noderemove.ts`) |
| **Non-destructive D verbs** (record edits): room/rack add/modify, place / place modify, cable add/split/join, disk add/modify/adopt, port modify, asset receive/fault/repaired/allocate/release, site modify, location add/modify, network add | AN using `applyNowJob` (the dry run runs first in the same job; a refusal comes back inline as the failure) | the preview is a validation that a refusal shows just as well | medium (StepView dispatch + inline refusal) |
| `module-manager modify` (ModuleConfig, fieldsStep) | AN, with `previewNote` (the change classes) shown **above the button** | `previewNote` is computed from the form values (`fields.tsx:226-240`), not from the job, so it can go before Apply; disruptions are already checkboxes | medium |
| "Record, then reconcile" pairs: PortChange (`deviceops.tsx:18-35`), Zones modify/state → reconcile (`Zones.tsx:164-189`), Identity add/modify/delete → reconcile (`Identity.tsx:34-46`), Environment add → reconcile (`Environments.tsx:27-45`), Adopt stage 2 (`Adopt.tsx:225-226`), Setup switch registration and identity bootstrap (`Setup.tsx:295-316`) | step 1 → AN; step 2 → keep the preview, run at open | step 1 is N; step 2 is a site-wide plan | medium |
| Assistant card (`assistant.tsx:154-247`) | reuse the shared flow: Run = `applyNowJob`, and a Stop button | today it has no Stop (no `JobControl`), a local typed name, and a second job view | medium |
| Backup keys (`BackupKeys.tsx:51-63`) | make it a streamed job (server: a secrets job with stdin), then AN | today one blocking POST: no live output, no Stop, result in a raw `<pre>` after the fact | large (server side) |

### Keep a preview the operator reads (but run it at once and unify the output)

| Use | Why the preview stays |
|---|---|
| `switch-manager reconcile` (Adopt, PortChange, Park, Setup) | the delta for **every** pending port on every switch, not only this one ("read the preview's list before you apply", `deviceops.tsx:33`, `Adopt.tsx:113`) |
| `ap-manager reconcile` (`Wifi.tsx:73`) | the per-AP delta; clients may lose WiFi |
| `network-manager reconcile` (`Zones.tsx:192, 293`) | every plane dry: OPNsense, Proxmox, switch, AP |
| `identity-manager reconcile` | the plan against Authentik (create/change/**remove**) |
| `environment-manager reconcile`, `backup-manager reconcile`, `module-manager reconcile` (three-way drift), `site-manager repository reconcile` / `sync` | a plan or drift to confirm |
| `site-manager update` (Update now, `Site.tsx:307-318`) | the sweep's plan; Apply blocks the console |
| `module-manager add-stack` (`Setup.tsx:56`) | a plan: module order, skips, hand steps |
| `node network set` / `test` (NodeUplinks, deviceops) | the preview checks the declaration on the node before a drain under rollback |
| `node reconcile` (`Site.tsx:59`, `AddNode.tsx:452`) | lists the nodes it would register |
| `node delete` | already RN |

For all of these: a **"preview at open"** step. Open the step and the preview job starts. Its output is shown live with the status line. One Apply button sits under it and applies that preview (`applyJob`). Effort: medium, inside the same StepView rework.

## 3. Output panes

| Where | Component | Follows the last line | Folds when finished | Status line + Stop | Notes |
|---|---|---|---|---|---|
| `jobs.tsx:77-109` `Output` | itself | yes (stick logic, `:89-100`) | `collapsed` → last 4 lines + "▸ N earlier lines" (`:76, 88, 103-105`) | no (not its job) | the one good pane |
| `operate.tsx:171-175` `JobView` / `:177-190` `JobPart` | `Output` | yes | the preview folds once an apply exists (`:353` `collapsed={applied !== null}`) | Tag + "label: state · s · job id" + `JobControl` (`:180-185`) | `live` = running **or queued** (`:174`) |
| `operate.tsx:194-209` `TwoPhaseView` | `JobPart` ×2 | yes | the preview folds when the apply starts (`:202`) | yes, per phase | apply `live` = running only (`:205`) |
| `operate.tsx:356-359` `jobShownIn` line | none | – | – | Tag + JobControl | **dead option**: no Step sets `jobShownIn` (grep finds only `operate.tsx`) |
| `operate.tsx:214-222` `ProgressBar` | itself | – | – | – | only Add node `usb write` (`AddNode.tsx:293`) |
| `jobs.tsx:144-173` `JobDetail` (Activity, module page) | `Output` | yes | the preview phase folds (`:155`) | no (Stop sits on the row, `:193`) | `live` = `running` only (`:155, 160, 167`): a queued job is not "live" here but is in JobView |
| `RemoveNode.tsx:209, 245` (removal running) | `Output live` | yes | finished → hidden entirely in `<details>` "What the removal printed" (`:247-250`) | own prose line + Tag + `JobControl` (`:209`); no job id, no `jobResult` | `live` forced true while not finished |
| `RemoveNode.tsx:285-290` (check) | `Output` in `<details>` | yes | always closed | none: the check has no Stop | |
| `RemoveNode.tsx:238, 271` | **raw `<pre className="output">`** of the last 8 lines | no (static) | – | – | tails duplicated from Output |
| `AddNode.tsx:570-574` (declare running) | `Output live` | yes | – | Tag + prose + `jobResult · job id` + `JobControl` (`:572`) | **unreachable for node add**: no dry run, so `inApply` is true at once (`:511`) |
| `AddNode.tsx:542-549` (declared) | `DeclaredLine` + `Output` in `<details>` | – | closed | `DeclaredLine` (`:489`) Tag + line + job id + `JobControl` | the "What the check printed" pane shows `phaseOutputs(job).preview ?? ""`, which is always "(no output)" for node add (no `previewPhase`) |
| `AddNode.tsx:552-567` (failed) | raw `<pre>` tail (`:558`) + `Output` in `<details>` | – | closed | none | |
| `AddNode.tsx:442-448` (stage 3, the install) | `Output` | yes | never | "The job: **state**" + `JobControl`, **no Tag**, no job id (`:445`) | a third status-line style in the same wizard |
| `AddNode.tsx:455-460` | raw `<pre className="output">` in `<details>` | no | – | – | PXE service status (static text: acceptable) |
| `assistant.tsx:219-243` | `Output` ×2 in a local `.jobview` | yes | **never** folds | Tag + "preview/run: state · job id", **no `JobControl`: no Stop** | |
| `Enrol.tsx:111` | `Output` for the wg config | – | – | – | the config file, not job output (fine) |
| `BackupKeys.tsx:125` | **raw `<pre>`** with the POST's output | no | – | none; "Writing…" on the button | no stream: the result appears only at the end |
| `CiPanel.tsx:33, 189`, `HealthPanel.tsx:117` | raw `<pre className="output">` | no | – | – | JSON or drift **data**, not job output (acceptable, but uses the job-output look) |
| `ModuleSections.tsx:27` | `<pre className="mono small">` | – | – | – | section text |
| `Setup.tsx:272-279, 344, 359` "Check: run the module tests" | **no pane** | – | – | button text "Checking…" | runs module tests via `GET setup?refresh=1`: no output, no Stop |
| `Operations.tsx:147-167` discovery sweep | **no pane** | – | – | readstate "A sweep … is running" | polling only |
| Activity sweep runs (`Activity.tsx:18-50`) | table of lines | – | `open` toggle | – | journal, not a job |

Inconsistencies:
1. **Six status-line variants** for a running job: `JobPart` (`operate.tsx:180-185`), `RemoveNode.tsx:209`, `DeclaredLine` (`AddNode.tsx:489`), `DeclareStep` (`AddNode.tsx:572`), AddNode stage 3 (`AddNode.tsx:445`, no Tag), assistant (`assistant.tsx:221-224, 238-241`, no Stop). The job id, duration and `jobResult` are present in some and missing in others.
2. **Two fold behaviours**:
   - `Output collapsed` keeps the last 4 lines visible (JobView/TwoPhaseView/JobDetail).
   - `<details>` hides everything behind a summary (RemoveNode `:247, 286`; AddNode `:545, 563`).
   The new pattern uses the second for finished output and the first for a finished phase.
3. **Three "live" rules**: running or queued (`operate.tsx:174`, `assistant.tsx:226, 242`, `wizard.tsx:22` `jobLive`); running only (`jobs.tsx:155, 160, 167`, `operate.tsx:205`, `AddNode.tsx:447`); forced true (`RemoveNode.tsx:245`, `AddNode.tsx:573`). `jobLive` exists but is not used by `JobView`/`JobDetail`.
4. **Raw `<pre>` tails** instead of `Output`: `RemoveNode.tsx:238, 271`, `AddNode.tsx:558`, `BackupKeys.tsx:125`. Each comes with its own tail helper: `nodeadd.ts:316` `lastLines` and `noderemove.ts:69` `tail` do the same thing.
5. **Wrapping differs by container**: `.output` is `white-space: pre` with horizontal scroll (`styles.css:209`), but `ol.setup .output` wraps (`styles.css:270`). The same job output wraps inside a wizard stage and scrolls sideways inside an Operate dialog.
6. **"Starting…" texts**: `JobView` "starting {label}…" (`operate.tsx:173`), `RemoveNode.tsx:205`, `AddNode.tsx:540`, button labels "Starting…" (`RemoveNode.tsx:314`, `AddNode.tsx:584`). StepView's buttons show no starting state.
7. **No Stop**: the assistant card, the RemoveNode check, Backup keys, Setup Check.

## 4. Shared code

| Piece | Where defined | Used by | Local copies / gaps |
|---|---|---|---|
| `Wizard` (modal shell, close guard) | `wizard.tsx:58-97` | Operate, AddNode, RemoveNode, Adopt, Buddy, Enrol, Satellite, Wifi, ResetPassword, BackupKeys, nodepools | – (good). `Adopt.tsx:245` opens an `Operate` (a Wizard) **inside** the Adopt Wizard: a modal over a modal |
| `StepRow` | **`pages/Setup.tsx:150-169`** (a page file) | AddNode, RemoveNode, Adopt, Buddy, Enrol, Satellite, Wifi, ResetPassword, BackupKeys, Setup | shared, but lives in a page; belongs in `wizard.tsx` |
| `StepView` / `StepForm` / `useStepValues` | `operate.tsx:252, 241, 226` | Operate, the wizards above, NodeUplinks, nodepools; `StepForm` + `useStepValues` also by `DeclareStep` (`AddNode.tsx:501-503, 581`) | `DeclareStep` re-implements the run half of StepView |
| `Output` | `jobs.tsx:77` | JobPart, JobDetail, RemoveNode, AddNode, assistant, Enrol | raw `<pre>` at `RemoveNode.tsx:238, 271`, `AddNode.tsx:458, 558`, `BackupKeys.tsx:125` |
| `JobControl` | `jobs.tsx:114` | JobPart, JobList, RemoveNode, AddNode (×3), operate jobShownIn | **missing** in `assistant.tsx` |
| Status line | `JobPart` (`operate.tsx:177`) is private | – | 5 local versions (section 3, item 1) |
| `OperateButton` / `Operate` | `operate.tsx:390, 372` | ~110 call sites | `Day2.tsx:90`, `ModuleConfig.tsx:142`, `Adopt.tsx:245` drive `Operate` directly with their own open state |
| `ReadState` | `ui.tsx:142` | pages | AddNode boot medium (`AddNode.tsx:343`) and BackupKeys (`BackupKeys.tsx:142`) hand-roll the read error text |
| `FindingList` | **local** `RemoveNode.tsx:114-131` (not exported) | RemoveNode only | `physical/overview.tsx:283` has a **different** `FindingList` (rows + empty): same name, different shape; RemoveNode's success list (`:213-231`) and `Afterwards` (`:334-359`) reuse the `.findings` class by hand |
| `DetailsLinks` | `ui.tsx:185` | SidePanel (`:683`), HealthPanel | – |
| Side panels `SidePanel` / `HealthPanel` / `CiPanel` | `physical/SidePanel.tsx:113`, `pages/HealthPanel.tsx:65`, `pages/CiPanel.tsx:88` | – | SidePanel runs no jobs (status + DetailsLinks). HealthPanel has 3 `OperateButton`s (all N). CiPanel shows data in `.output` pre |
| Typed-name confirm | none shared | – | 3 copies: `operate.tsx:291-294, 332-337`; `assistant.tsx:166-168, 230-236`; `RemoveNode.tsx:183, 308-311`. RemoveNode accepts only the exact node name; the other two also accept the label |
| Run state machine (start → previewPhase → apply → done/stopped/failed) | none shared | – | 4 copies: `operate.tsx:256-297` (StepView), `AddNode.tsx:504-522` (DeclareStep: `inApply`, `failed`), `RemoveNode.tsx:145-180` (`stopped`, `finished`, `ok`), `assistant.tsx:155-168` |
| Resumable session | `useJobSession` + `ResumeOffer` (`wizard.tsx:37-52`) | RemoveNode `:43, 67`, Adopt `:77, 152`, Buddy `:46, 93`, Enrol `:49, 130`, Satellite `:45, 95` | **AddNode** has its own jobs read `useAddNodeSession` (`AddNode.tsx:114-126`, a second `jobs?bin=…` poll) and its own offer bar (`:321-327`, 3 buttons) instead of `ResumeOffer` |
| "Step 1 = a form + Continue/Edit" | none shared | – | 6 copies: `RemoveNode.tsx:89-96`, `Adopt.tsx:202-218`, `Buddy.tsx:110-116`, `Wifi.tsx:134-143`, `BackupKeys.tsx:88-95`, `Satellite.tsx:170-174` |
| Second stepper | `operate.tsx:322-326` is the only "Change/Preview/Apply/Result" stepper | – | the wizards' `StepRow` list is the other stepper. Inside a wizard stage the operator therefore sees **two stacked steppers** (stage rows + the 4 pills) wherever a stage embeds `StepView` |
| Tail helper | – | – | `nodeadd.ts:316` `lastLines`, `noderemove.ts:69` `tail` |
| Small check list | – | – | `AddNode.tsx:85-92` `Check` (Dot + label + detail), used only there; the same `.plain.checks` markup appears by hand in `NodeUplinks.tsx:19-25` (`PortLine`) and `Wifi.tsx:185-189` |

Stale or misleading text found on the way:
- `AddNode.tsx:18-20, 494-498, 572` say node add "runs its dry run first". **`node add` has no dry run** (`manager/site-manager/src/main.ts:155`, `noPreview`). `:572` is therefore unreachable, and the "What the check printed" pane (`:545-548`) always shows "(no output)".
- `operate.tsx:47-49, 356-359`: `jobShownIn` is never set by any Step.
- `Satellite.tsx` stage text "Previewed, then applied." and `Buddy.tsx:86` "previewed, then applied" describe a no-op preview.

## 5. Proposed plan (in order)

Steps 1 to 7 are done, on branch `console-flow-plan` (components in `web/src/jobs.tsx`, `run.ts`, `stepform.tsx`, `flows.tsx`, `argv.ts stepFlow`). Differences from the plan below: `node network set` previews on its button, not on open, because its preview writes the declaration; Adopt stage 4's nested `Operate` stays (step 7's last bullet, not done); the assistant's Run still needs a preview (step 10). From step 9, `jobShownIn` and AddNode's dry-run texts are already gone; `JobDetail`'s `live` is left.

1. (done) **One status line and one output pane.** Small.
   - Export `JobStatusLine({ job, label })` from `jobs.tsx`: Tag (`jobLevel`), label, `jobResult`, duration, job id, `JobControl`. Use it in `JobPart`, `RemoveNode.tsx:209`, `DeclaredLine`/`DeclareStep`, `AddNode.tsx:445` and `assistant.tsx:221, 238`; the assistant gains Stop as a result.
   - Give `Output` a `live` default from `jobLive(job)` through a `JobOutput({ job, phase, fold })` wrapper: `fold: "tail"` keeps the last 4 lines, `fold: "closed"` uses `<details>`.
   - Replace the raw tails (`RemoveNode.tsx:238, 271`, `AddNode.tsx:558`) with `Output` given a `tail` prop. Delete `noderemove.ts:69` and keep a single `lastLines` in `jobs.tsx`.
   - Make `.output` wrapping one rule (`styles.css:209` vs `:270`).
2. (done) **`useJobRun()` hook** (`jobs.tsx` or a new `run.ts`). Medium.
   - It takes `start(argv, confirm?)` via `applyNowJob` or `applyJob`, and returns `{ job, phase: "idle" | "starting" | "checking" | "applying" | "done" | "refused" | "stopped" | "failed", inApply, ok, tail, error }`.
   - It calls `useReportJob` and `onApplied`/`onDone` itself.
   - It replaces the four state machines (`operate.tsx:256-297`, `AddNode.tsx:504-522`, `RemoveNode.tsx:145-180`, `assistant.tsx:155-168`).
3. (done) **`ActStep`** (the AN pattern), generalised from `DeclareStep` (`AddNode.tsx:499-589`). Medium.
   - Props: a form (`StepForm` from a `Step`, or children), the button label, `blocked`, `progress`, `after`, `previewNote` shown above the button, and a `collapsedLine` for the finished one-liner.
   - Behaviour: the button starts `useJobRun`; while the job runs it shows `JobStatusLine` + `Output live`; on failure, the tail + Try again with the form kept; when done, the one-liner + `<details>` output + `after`.
4. (done) **`CheckStep`** (the RN pattern), generalised from `RemoveStep` (`RemoveNode.tsx:135-325`). Medium.
   - Behaviour: it runs `previewJob` when the step opens, and again on "Check again". It shows a running line with Stop. An optional `parse(output, exit)` returns `{ state, blockers, losses, tail }`; the default is ok on exit 0, else blocked with the tail. Then `FindingList`, then children: choices, then `TypedConfirm` + an `ActStep` button that applies (`applyJob` of the check, or `applyNowJob`).
   - Move `FindingList` to `ui.tsx` (rename one of the two). Remove node then becomes `CheckStep` + `noderemove.ts` parse.
5. (done) **`TypedConfirm({ object, label, value, set })`**, one component with one matching rule. It replaces `operate.tsx:332-337`, `assistant.tsx:230-236` and `RemoveNode.tsx:308-311`. Small.
6. (done) **StepView becomes a dispatcher.** Medium to large; this is the step that reaches the ~110 OperateButtons.
   - `previewKind === "none"` → `ActStep` (no stepper, no Preview button).
   - `read` → run on open (or keep one Run for expensive reads such as `test`).
   - destructive with a dry run → `CheckStep` + `TypedConfirm`.
   - non-destructive `dry-run-flag` → `ActStep` via `applyNowJob` (a refusal is shown inline).
   - `apply-flag` plans (reconciles, update, add-stack, network set/test, node reconcile) → "preview at open" + one Apply that applies that preview.
   - Keep the four pills only where a read preview remains, or drop them in favour of the status line.
   - Add an explicit override field such as `step.flow?: "act" | "check" | "plan"` for the few that need it, e.g. a module modify where `previewNote` matters.
7. (done) **Wizards adopt it.** Small each after 3 and 6.
   - Adopt stage 3, Buddy stage 2, Enrol stage 2, Satellite stage 3, ResetPassword link, NodePools, AddNode stage 0, Wifi declare: these change by themselves once StepView dispatches. Correct their stage texts ("previewed, then applied").
   - Buddy `peer check` and Satellite `test` run on open.
   - Replace Adopt stage 4's nested `Operate` (`Adopt.tsx:245`) with the place form inline in the stage.
8. **Wizard scaffolding.** Small.
   - Move `StepRow` to `wizard.tsx`.
   - Add a `DecideStep` (a form + Continue/Edit that locks the fields) for the six copies (`RemoveNode.tsx:89-96`, `Adopt.tsx:202-218`, `Buddy.tsx:110-116`, `Wifi.tsx:134-143`, `BackupKeys.tsx:88-95`, `Satellite.tsx:170-174`).
   - Build `useAddNodeSession` on `useJobSession`, and give `ResumeOffer` an optional extra action ("Done with it") so AddNode drops `AddNode.tsx:321-327`.
   - Share AddNode's `Check` (`AddNode.tsx:85-92`) as a `CheckList`.
9. **Cleanup.** Small.
   - Remove the dead `jobShownIn` (`operate.tsx:47-49, 356-359`).
   - Fix AddNode's dry-run texts (`AddNode.tsx:18-20, 494-498, 545-548, 572`).
   - Make `JobDetail`'s `live` use `jobLive` (`jobs.tsx:155, 160, 167`).
10. **Assistant card.** Medium. Use `useJobRun` + `JobStatusLine` + `TypedConfirm`. Run = `applyNowJob`, so no Preview click is required; keep Preview for `apply-flag` plans, as in step 6.
11. **Non-job long actions.** Large (server).
    - Backup keys write (`BackupKeys.tsx:51-63`; a secrets endpoint that runs `backup-manager key export … --password-stdin`) and Setup "Check" (`Setup.tsx:272-279`) become streamed jobs with stdin.
    - Then they use `ActStep` and gain live output and Stop. The WiFi passphrase and the reset password are short and can stay as they are.

Expected effect: steps 1-5 are the shared core: about 4 pieces (`JobStatusLine`, `JobOutput`, `useJobRun`, `TypedConfirm`) plus 2 step components (`ActStep`, `CheckStep`). Remove node and Add node stage 1 become their first users with no change in behaviour. Step 6 then moves about 30 no-dry-run buttons and about 40 `--check` buttons to one-button flows in one change, and keeps a readable, auto-run preview for the dozen plan/delta verbs.
