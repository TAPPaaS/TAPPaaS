# ADR-048 — The Security Stream

| | |
|---|---|
| **Status** | **Draft** — for the operator's review |
| **Version** | 0.1 |
| **Date** | 2026-11-10 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | The delivery half of [ADR-047](<ADR-047 - CVE Decisions and the Daily Work.md>). Amends ADR-028 (a patch line beside the train; D12 and D15 gain an automated path), ADR-033 (a stream key with a narrow namespace; a second transport for a signed tag) and ADR-045 (decisions no longer travel only with the code). |
| **Changelog** | v0.1 (2026-11-10): first draft. |

A production site gets a CVE decision or a patched image when the release that carries it reaches
`stable`: up to four weeks after it was made. The train is slow on purpose, because features need
the soak. Decisions and patch-level fixes do not need that soak, and should not wait for it. This
ADR adds a second, narrow way to production: a daily stream that can carry decisions and
patch-level bumps and nothing else.

## Context

- A site reads its VEX from the checkout of the branch it tracks (as-built, G6). `stable` moves
  every two weeks and is one release behind `staging`.
- Debian guests, the nodes and the firewall patch themselves from their distributions (ADR-028
  D5). NixOS guests move only when the pin moves, and a container image only when its pin line
  moves. Those two are what the stream has to deliver.
- ADR-028 D12 and D15 already allow an urgent fix on `stable` between boundaries, by hand, with a
  written reason, numbered `vMAJOR.MINOR.N` and signed. It is used a few times a release.
- ADR-033 makes `stable` and `staging` tips signed tags, verified before a checkout moves, against
  signers the previous release enrolled.
- Sites do not report back. The only signals from a site are what its operator sends.
- Constraints: no scheduled job and no polling against Codeberg; images are on GitHub Releases.
- The repository is MPL-2.0 and developed in the open on `main`.

## Decision

### D1. Two cargoes, two risk classes

| | **Decision feed** | **Patch line** |
|---|---|---|
| Carries | ADR-047's central decisions: component records, deferrals | patch-level version moves: the nixpkgs lock inside the same NixOS release, container image pins inside the same minor version |
| Is | data; a site parses it and nothing in it runs | code and artefacts a site builds and starts |
| Worst case | a wrong level on the Security page | a service that does not start |
| Gate | lint and a diff check on the staging site | build, a deploy test on the staging site, a canary soak |
| Reaches production | the same day | after two days, or at once for an expedited fix |
| Signed by | the stream key, automatically | a release key, by a person |

Everything else stays on the train: module code, managers, migrations, configuration schema, a
new NixOS release, a major or minor version of an image, a new module.

### D2. The decision feed

**Content.** One file, `tappaas-decisions.json`: every module's component records from `main`,
with a header.

```json
{ "schema": 1, "sequence": 412, "generated": "2026-11-10T19:02:11Z", "validUntil": "2026-11-24T19:02:11Z",
  "source": "1d3b8ed1", "components": { "network/opnsense:curl": { … }, "templates/nix:sqlite": { … } } }
```

A record names the versions it holds for (ADR-047 D3), so one feed serves every channel. A site
on 2.3.3 and a site on 2.4 read the same file.

**Built by an event.** A push to `main` that touches `src/**/*-components.json` starts the build
(a path-filtered trigger, no schedule). The build compiles the records, runs the lint (schema,
mandatory fields, review dates, every rule inside one component), increments `sequence`, signs,
and publishes. Nothing is built on a day nobody decided anything.

**Signed.** `ssh-keygen -Y sign -n tappaas-decisions` with the **stream key**: one more line in
`.tappaas/allowed_signers`, restricted with `namespaces="tappaas-decisions"`. It can sign a feed
and nothing else; it cannot sign a release tag or an image. It lives where the build runs. A
site verifies with the `allowed_signers` of its last verified release, as it does for a tag
(ADR-033 D4), so enrolling or replacing the stream key is a signed release like any other key
change.

**Verified at the site** before it is used:

| Check | Refuses |
|---|---|
| the signature, namespace `tappaas-decisions` | a feed from anyone else |
| `sequence` higher than the last one applied | an old feed served again |
| `validUntil` in the future | a feed held back for weeks |
| the schema | a file the site's version cannot read |

A feed that fails is not applied. The site keeps the last good one, and when that passes
`validUntil` it falls back to the records in its own checkout and raises `decisions-stale`
(warning) on the site. A missing feed never fails a scan.

**Applied.** The scan and the rescan read the feed in place of the checkout's records when the
feed is newer than the site's release. A known-exploited CVE counts at its upstream severity
whatever the feed says (ADR-047 D2); that rule is in the site's code and uses the scanner's own
database, so no feed can switch it off.

**Gate.** The staging site applies each new feed first and compares the scores before and after.
The build publishes to production only when: the lint passed; the scan with the new feed did not
fail; and every unit whose level dropped is explained by a record that changed in this feed. A
drop the diff cannot explain stops the publication and mails the maintainers. The gate takes
minutes and needs nobody.

### D3. The patch line

For each release in service (the one on `stable`, the one on `staging`) there is a patch line:
the release plus patch-level moves. It is ADR-028's urgent fix, made routine for one narrow kind
of change.

**What may be on it.** A patch release `vMAJOR.MINOR.N` may differ from its base release only in:

| Path | Allowed change |
|---|---|
| `src/foundation/templates/flake.lock` and the locks that follow it | a newer revision of the **same** nixpkgs release branch |
| the lines `src/image-pins.json` lists | a newer digest or patch tag of the **same** major.minor |
| `src/**/*-components.json`, `src/**/*-vex.json` | any |
| `release/releases.json`, `RELEASES.md`, the version files | the record of this patch |

`tappaas-train.sh patch-scope <tag>` checks it. **The site checks it too**, in the verifier,
before the checkout moves: a patch tag whose diff against its base release touches anything else
is refused, whoever signed it. A mistake in the release tooling cannot put a feature on the patch
line.

**How a patch is made.**

1. ADR-047's daily `candidates` check proposes a move. A maintainer approves it, and it lands on
   `main` first (ADR-028 D15: forward, on `main`).
2. `tappaas-train.sh security-patch` cuts `patch/<release>` from the release tag and applies the
   allowed-path changes from `main`. It refuses if `patch-scope` fails.
3. **Gate 1, the staging site (hours).** Every NixOS module's system is built from the patch
   branch, so an evaluation or build break stops here. The canary guest is deployed from it and
   its module test runs, as the boundary's `prove` phase does today. For an image move, the
   module's own test runs against the new image.
4. **Gate 2, the canary sites (two days).** The patch is published to the canary ring (D4). It
   moves on unless a fault is recorded against it: `tappaas-train fault`, which already blocks a
   promotion.
5. **Gate 3, everyone.** A release key signs `vMAJOR.MINOR.N`; that signature is the approval.
   `stable` moves to it as an urgent fix does today.

Patches are batched. One patch release a week is the normal rhythm; a day's candidates wait for
it unless they clear a high or critical item.

**Expedited.** A known-exploited CVE, or a critical one reachable from the network on a default
deployment, skips gate 2 with `--expedite --why "security: …"` (ADR-028 D12). Gate 1 and the
signature stay.

**Why this does not repeat the mistake ADR-028 warns about.** "A cherry-picked pin arrives next
to code it was never built against" is true across NixOS releases and for module changes. Inside
one release branch nixpkgs backports fixes and keeps options stable, and gate 1 builds every
module against the exact pin before any site sees it. The scope check keeps module code off the
line, so the code beside the pin is always the code the release proved.

### D4. Rings

A site chooses its ring in `site.json`:

| `security.ring` | Gets the feed | Gets patches |
|---|---|---|
| `canary` | when gate D2 passes | after gate 1 |
| `daily` (the default for a subscribed site) | when gate D2 passes | after gate 2 and the signature |
| `release` | with its release, as today | at the boundary, as today; expedited fixes as today |

There is no telemetry. The canary ring is a few sites whose operators agreed to report: the
maintainers' own production sites first. The soak is time plus the absence of a recorded fault.
That is weaker than measured health, and it is what a system that does not phone home can offer.

### D5. Transport: files, not a second git remote

Both cargoes are published as files beside the images on GitHub Releases, under a `security`
release whose assets are replaced:

| Asset | Content |
|---|---|
| `latest.json` | the feed's sequence and hash, the newest patch per release line and ring, a few hundred bytes |
| `tappaas-decisions.json` + `.sig` | D2 |
| `patch-<version>.bundle` | a git bundle: the signed patch tag on top of its base release |

A site asks once a night, inside the update it already runs: one conditional request for
`latest.json`, and a download only when something changed. A patch arrives as a bundle; the site
fetches from it and runs the ADR-033 verifier unchanged (the tag's signature, the tree hash, the
ancestry) plus the scope check. Where a tag came from does not matter once it verifies.

Codeberg sees one push-triggered build per day at most, and no site polls it for the stream.
Each patch tag is also pushed to Codeberg when it is released to everyone, so the public
repository stays complete.

### D6. Paid access

What is sold is **the daily delivery**: the signed feed and the tested, signed patch releases,
within a day or a week of the decision. What stays free is everything in them.

- Decisions and pin moves are authored on public `main`. Anyone can read them the minute they are
  pushed, and anyone can build a feed from `main` and sign it with a key their own site trusts.
- A site in the `release` ring gets all of it with the next release, at most two weeks later for
  `staging` and four for `stable`. That is today's behaviour, so nothing is taken away.
- An expedited fix (D3) goes to every site at once, subscribed or not. Nobody is left exposed to
  a known-exploited CVE because they did not pay.

**Mechanism: bundles encrypted to the site's key.** A subscribing site creates a key pair
(`site-manager security subscribe` prints the public half). The assets of D5 are encrypted with
one content key per publication, and that key is wrapped for every subscriber's public key in
`latest.json`.

| | Encrypted to the site key (proposed) | Per-site token on a private repository or cache | Public after N days only |
|---|---|---|---|
| Hosting | any public file host, the same place as the images | a server that checks tokens; Codeberg restricts private repositories to small supporting use, so it means running one | none |
| Access control | who is in the recipient list at publication | revocable at any moment, and usage is visible | none; the delay is the product |
| Leaves a subscriber | at the next publication | at once | — |
| Load on Codeberg | none | none if self-hosted | none |
| Operations | a subscriber list of public keys; no server | a service that must be up for sites to patch | none |
| Weakness | the subscriber list is visible as opaque key ids; a subscriber can pass the files on | a paid security path now depends on a server we run | no early access to sell |

The embargo is already there: the `release` ring is the public delay, and its length is the
train's.

**Against the licence and against what is public.**

- MPL-2.0 lets anyone who receives a file pass it on. A subscriber may republish the feed or a
  patch bundle, and the licence cannot forbid it. Subscription terms can ask them not to; the
  model must not depend on it.
- Nothing in the stream is secret. CVE data, upstream fixes and our own records on `main` are
  public. A capable operator can reproduce the stream. The subscription pays for the triage being
  done, tested and delivered daily, not for exclusive knowledge.
- That is why this is a soft paywall. A hard one would need the records written in a private
  repository and published after a delay. It would end open development of the security work,
  need every contributor's agreement to hold their contributions back, and still leak through
  the first subscriber. It is not proposed.

### D7. What changes for the maintainers' day

| When | Who | What |
|---|---|---|
| nightly | the staging site | scan, rescan, `candidates` (ADR-047 D8) |
| morning | a maintainer | the queues: move a pin, decide, review; pushes to `main` |
| on that push | the build | feed: lint, sign, gate on the staging site, publish |
| weekly, or the same day for a high or critical fix | a maintainer | `security-patch`, gate 1 |
| two days later | a maintainer | sign and release the patch, unless a fault was recorded |
| at the boundary | the train | as today; the patch lines of the two releases in service continue, the oldest ends |

## Consequences

- **Good.**
  - A decision reaches production the day it is made; a patch-level fix within a week, or a day.
  - The train keeps its soak for everything that needs one, and gets fewer urgent fixes.
  - The automation key can sign data only. What a patch may contain is enforced by the site.
  - No new server and no new load on Codeberg.
- **Cost.**
  - Two patch lines to keep, each with a weekly patch release and a signature.
  - A feed builder, a scope check in the train and in the verifier, bundle transport, rings,
    subscription keys.
  - A site on the `daily` ring runs a version (`2.4.3`) that the `release` ring does not, so
    support has to ask which.
- **Risk.**
  - **A pin move inside a release branch breaks a module.** Gate 1 builds all of them and deploys
    one; gate 2 is two days on real sites; the way back is the previous patch tag, by an operator
    command (ADR-033 D6).
  - **The stream key is stolen.** The thief can sign feeds: levels on the Security page can be
    lowered, known-exploited CVEs excepted. No code runs. Replacing the key is one signed release.
  - **The feed stops.** Sites fall back to their checkout after `validUntil` and say so.
  - **The canary ring is too small to catch anything.** Then gate 2 is only a delay. Gate 1 has
    to be good enough on its own, and the first months should show whether it is.

## Alternatives considered

- **Move the boundary forward for every fix** (ADR-028's answer today). Kept for anything outside
  the patch scope. For patch-level fixes it makes every site take two weeks of features early.
- **Let sites move their own pins.** Rejected in ADR-028: every site would run an untested
  combination.
- **A third git channel (`security`).** The same content, and sites would fetch one more Codeberg
  branch nightly. Files on the image host avoid the load and allow encryption.
- **An update framework with full role separation (TUF).** The feed uses its rollback and freeze
  protections. Root, targets, snapshot and timestamp roles are more key handling than two
  maintainers can keep up; ADR-033's signer chain is the root of trust here.

## Phases

| Phase | Content | Done when |
|---|---|---|
| S1 | The feed: builder, stream key and namespace, site verification, fallback, `decisions-stale` | hrossen applies a feed built from `main` and refuses a replayed and an expired one |
| S2 | The feed gate and publication to GitHub Releases, `latest.json`, the nightly check | a decision pushed in the morning is on a production-channel test site the next night |
| S3 | `patch-scope` in the train and in the verifier; `security-patch`; gate 1 | a patch with a module change is refused on both sides; an image patch passes gate 1 on hrossen |
| S4 | Bundle transport, rings, the two-day gate, `--expedite` | a canary site takes a patch from a bundle, a `daily` site two days later |
| S5 | Subscription keys and encrypted assets | an unsubscribed site sees `latest.json` and cannot read the assets; it gets the same content at the boundary |

## Open questions

1. **Soft or hard paywall?** Proposed: soft (D6). It sells delivery and keeps development open.
2. **Encryption to the site key, or tokens on a server we run?** Proposed: encryption, for having
   no server in the patch path. Tokens give instant revocation and usage figures.
3. **Does the feed go to every site free, with only the patch line paid?** Decisions cost nothing
   to deliver and a wrong level on a free site helps nobody. Proposed: decide with question 1;
   the design allows either.
4. **Who signs patch releases?** Proposed: a release key, by a person, as ADR-033 has it. With one
   patch a week per line that is two signatures a week. An automation key for patches would have
   to be trusted with a pin move, and a pin decides what code a site builds.
5. **Canary sites.** Which sites, and is two days right? With only the maintainers' own sites the
   ring is small.
6. **Two patch lines or one?** Patching only `stable` halves the work and leaves `staging` sites
   to wait for the boundary, where they get the fix through the train anyway.
7. **Is a weekly patch rhythm enough**, with same-day for high and critical, or should every
   approved candidate ship daily?
