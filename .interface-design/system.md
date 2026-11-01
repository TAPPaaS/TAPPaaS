# Design system of the console (`src/foundation/tappaas-cicd/ui/web`) only; nothing else in this repository

Read this before touching the console. `test-console-design.sh` (in `src/foundation/tappaas-cicd/scripts/test`) holds the code to it: raw values not covered by `allow.txt` beside this file fail the tree tests.

## Direction

**Precision & Density.** Tight, technical, monochrome. An operator reads this at a glance on a laptop or a phone in the rack room.

- A cool slate foundation; white panels on a pale ground.
- Depth by borders only. A shadow is for what floats above the page: a modal, the drawer, a phone sheet.
- Status colours are the only chroma in the chrome. The drawing palette below is data (a zone, a cable, a guest), never decoration.
- New work uses tokens. A value that is missing from the scale is a question for the operator, not a new raw number.

## Tokens

All of them live on `:root` in `src/styles.css`, the one source. CSS reads them through `var()`; TS writes the same string, `"var(--slate-400)"`, in a `style`, a `fill` or a `stroke`. Nothing reads a colour back from the DOM, so a colour is never computed on.

### Core colours

| Token | Role |
|---|---|
| `--bg` | the page behind the panels |
| `--panel` | panels, cards, sheets |
| `--ink` | text |
| `--muted` | secondary text, labels |
| `--line` | every default border and divider |
| `--nav` | the side menu |
| `--nav-on` | the menu's active item |
| `--nav-ink` | the menu's text |
| `--accent` | links, the selection, focus |

### Status

Each status is a strong colour for marks (a dot, a left border), a `-bg` for tints, and an `-ink` for text on that tint. Never swap them: `--warn` means attention, `--fail` means broken, whatever the page.

| Status | Means | Mark | Tint | Text on the tint |
|---|---|---|---|---|
| pass | healthy, done | `--pass` | `--pass-bg` | `--pass-ink` |
| warn | needs attention, running | `--warn` | `--warn-bg` | `--warn-ink` |
| fail | broken, refused | `--fail` | `--fail-bg` | `--fail-ink` |
| skip | unknown, not checked | `--skip` | none | none |
| info | neutral note, selection tint | `--accent` | `--info-bg` | `--info-ink` |

### Supporting colours

These carry every value the stylesheet and the drawings already used, unchanged. Prefer a core token in new work.

| Family | Tokens | Role |
|---|---|---|
| Slate | `--slate-50` `--slate-100` `--slate-200` `--slate-300` `--slate-400` `--slate-500` `--slate-600` `--slate-700` `--slate-800` `--slate-900` | the neutral ramp: hover washes, quiet borders, dark panels |
| Gray | `--gray-100` `--gray-200` `--gray-300` `--gray-400` `--gray-600` `--gray-700` `--gray-800` `--gray-900` | quiet text, tracks, port bodies |
| Surfaces | `--white` `--surface-1` `--surface-isp` `--surface-proposal` `--surface-ap` `--surface-fw` `--surface-caution` `--row-selected` `--chip` `--port-line` | tinted cards and rows, default pill ground |
| Borders | `--line-strong` `--line-card` `--line-info` `--line-warn` `--line-caution` `--line-changed` `--line-fw` `--line-nav` `--steel` `--steel-light` | borders stronger or tinted beyond `--line`; steel is a neutral fill |
| Controls | `--nav-hover` `--btn-primary` `--btn-primary-hover` `--btn-danger` `--btn-danger-hover` `--term-bg` | buttons, the menu's hover, the output panel |
| Translucent | `--slate-900-a04` `--slate-900-a08` `--slate-900-a18` `--slate-900-a35` `--slate-500-a16` `--slate-500-a32` `--slate-400-a14` `--slate-100-a85` `--accent-a07` `--accent-a14` `--blue-600-a13` `--green-600-a22` `--red-600-a18` `--fail-a42` `--white-a55` `--black-a15` `--black-a25` | shadows, the scrim, hover and drop washes; the suffix is the alpha |

### Drawing palette

Data colours, for what is drawn. Never for a button, a heading or a status.

| Family | Tokens | Role |
|---|---|---|
| Zones | `--zone-wan` `--zone-mgmt` `--zone-test` `--zone-home` `--zone-work` `--zone-iotLocal` `--zone-iotCloud` `--zone-iotCams` `--zone-iotUntrust` `--zone-guest` `--zone-dmz` | one colour per named zone; `src/colors.ts` picks it |
| Other zones | `--zone-p0` `--zone-p1` `--zone-p2` `--zone-p3` `--zone-p4` `--zone-p5` `--zone-p6` `--zone-p7` | a stable pick by VLAN; also the module tiles |
| Hues | `--blue-50` `--blue-100` `--blue-150` `--blue-200` `--blue-600` `--blue-700` `--blue-800` `--sky-400` `--cyan-600` `--teal-500` `--teal-700` `--green-600` `--green-700` `--lime-700` `--yellow-400` `--yellow-700` `--amber-400` `--amber-500` `--amber-700` `--orange-400` `--orange-500` `--orange-700` `--red-600` `--red-700` `--rose-600` `--pink-700` `--fuchsia-700` `--purple-400` `--purple-600` `--violet-400` `--violet-600` `--violet-800` | cable kinds, port marks, LAG tags, graph edges |
| Rack | `--rack-thumb` `--rack-bay` `--rack-rule` `--hatch-ink` `--hatch-bg` | the rack drawing, the mirror hatch |
| Charts | `--gauge-pass` `--gauge-warn` `--gauge-fail` `--guest-1` `--guest-2` `--guest-3` `--guest-4` `--guest-5` | the section gauge, the storage pie's guests |

### Spacing

A 4 px base: `--sp-4` `--sp-8` `--sp-12` `--sp-16` `--sp-24` `--sp-32`. Paddings, gaps and margins use these. The half steps the stylesheet already has (6, 10, 14 px and others) are capped in `allow.txt`: they may shrink, never spread.

### Radii

`--radius-control` 6 px, the commonest value (buttons, inputs, notes). `--radius-panel` 8 px (sections, cards, side panels). `--radius-sm` 4 px (tags, tree rows). A pill's radius is half its height, and is in `allow.txt`.

### Type

Inter at 14 px on `:root`; monospace is `ui-monospace, SFMono-Regular, Menlo, monospace` for commands, ports and pools. Sizes as used, not tokens:

| Size | Use |
|---|---|
| 1.35rem | the page title, `h1` |
| 1.05rem, 1rem | a tile or section title, `h2` |
| 14 px | body |
| 13 px, 13.5 px | controls, form rows, secondary text |
| 12 px, 12.5 px | table heads, card labels, legends |
| 11 px, 11.5 px | badges, tags, captions |
| 8.5 to 10.5 px | inside the drawings only |

Uppercase with letter spacing is for `h3` and small labels only. Weights: 400, 600 for emphasis, 700 for tags.

### Breakpoints

`--bp-sm` 640 px (a phone: the menu becomes a strip), `--bp-md` 900 px (a tablet: `.two` collapses), `--bp-lg` 1100 px (the drawer stops pushing the page), `--bp-xl` 1250 px (a small laptop: attention rows wrap).

`var()` is not valid in a media query. Write `@media (max-width: var(--bp-sm))` anyway: `vite.config.ts` puts the value in at build time and stops on an unknown token. Code imports `src/breakpoints.ts`, which must agree with `:root`; the audit checks it.

## Patterns

Each has one place in the code. Use it; do not write a second one.

- **Side panel**: `.sidepanel`, with `DetailsLinks` from `src/ui.tsx` at the top: a "Details" link, not Change or Open in. The richest is `src/physical/SidePanel.tsx`. Its header stays on top while the body scrolls, so its × does too.
- **Wizard step**: `src/wizard.tsx` for `StepRow` (a step's row and its state) and `DecideStep` (a choice, then Continue); `src/flows.tsx` for `ActStep` (one job) and `CheckStep` (a check that gates the next step).
- **Job output panel**: `src/jobs.tsx`: `JobStatusLine`, `JobOutput`, `Output`. Dark, monospace, and it sticks to the last line.
- **Overview tiles**: `src/pages/Overview.tsx`: `.ov-grid`, 2×2 down to one column at `--bp-md`, each `.ov-tile` with a status left border.
- **Assets tree**: `src/pages/Assets.tsx`: `.atree`, the tree on the left and the side panel on the right.
- **Physical rack view**: `src/physical/rack.tsx`: the SVG drawing, Unplaced and How to on the left, the selection's side panel on the right.

## Wording

Constraints on new components as much as colours are.

- The operator's words: "the machine's asset record", "the primary location". No synonym, no word the operator did not use.
- No flags or internals in a wizard: it speaks of the machine and the site, never of the command behind it.
- One button per step.
- A Continue after a selection; never a step that collapses on select.
- The output panel sticks to the last line.
- Side panels have a "Details" link at the top, not Change or Open in.
- A disabled button says why.
