# ADR-048 — The Security Stream

| | |
|---|---|
| **Status** | **Draft** — for the operator's review |
| **Version** | 0.2 |
| **Date** | 2026-11-11 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | The delivery half of [ADR-047](<ADR-047 - CVE Decisions and the Daily Work.md>). Amends ADR-028 (private channels, a daily patch line, a public line 14 days behind), ADR-033 (subscriber tags, a second remote, a stream key for data) and ADR-045 (decisions no longer travel only with a release). |
| **Changelog** | v0.1 (2026-11-10): first draft, a soft paywall over open development. v0.2 (2026-11-11): the operator's model, replacing it. **Development is private**: unstable and staging live on a server we run. **Production exists twice**: a subscriber line with daily bug, security and decision patches, and a public line that gets the same feature releases at the same boundaries and each patch 14 days later. Access by **per-site tokens** on that server. Both the decision feed and the patches are paid. A person signs every patch release. Canary: hrossen and makerfloss, two days. |

A production site gets a fix or a CVE decision when the release that carries it reaches `stable`,
up to four weeks after it was made. This ADR adds a daily stream of bug fixes, security patches
and decisions to production, and makes that stream the paid product: subscribers get it daily,
everyone gets it 14 days later. Features keep the train and its soak, and reach both at the same
boundary.

## Context

- A site reads its code and its CVE decisions from the branch it tracks. `stable` moves every two
  weeks and is one release behind `staging`.
- Debian guests, the nodes and the firewall patch themselves from their distributions (ADR-028
  D5). NixOS guests move when the pin moves, a container image when its pin line moves, and
  TAPPaaS's own code when a release moves.
- ADR-028 D12 and D15 allow an urgent fix on `stable` between boundaries, by hand, numbered
  `vMAJOR.MINOR.N` and signed.
- ADR-033 makes `stable` and `staging` tips signed tags, verified before a checkout moves.
- Today everything is developed in the open on Codeberg, pushed on to a GitHub mirror, and the
  documentation site is built from the same repository. Three people have commits in the tree.
- Sites do not report back.
- Constraints: no scheduled job and no polling against Codeberg; images are on GitHub Releases.

## Decision

### D1. Private development, two production lines

| Channel | Where | Who can read it | Moves |
|---|---|---|---|
| **unstable** (`main`) | the private forge (D7) | maintainers and contributors | continuously |
| **staging** | the private forge | maintainers, contributors, the staging sites | at the boundary, and daily patches |
| **production, subscriber line** | the private forge, a repository of its own | subscribed sites | feature releases at the boundary; bug, security and decision patches daily |
| **production, public line** | Codeberg, public | everyone | the **same feature releases at the same boundary**; each patch **14 days after** subscribers got it |

A feature never reaches a subscriber earlier than the public. What a subscription buys is 14 days
on every fix and every decision, and nothing else.

### D2. What a patch may be

A patch is a commit from `main` that the release line may take between boundaries:

| Kind | Examples | Commit types |
|---|---|---|
| Security | a nixpkgs lock move inside the same NixOS release; an image pin inside the same minor | `build(pin)`, `fix` |
| Decisions | component records (ADR-047) | `chore(vex)` |
| Bug fix | a corrected script, a manager fix, a failing check | `fix` |

Never on a patch line: `feat` commits, a migration, a change to a configuration schema, a new
module, a new NixOS release, a minor or major version of an image. `tappaas-train.sh patch-scope`
refuses a patch that carries one, by commit type and by a list of paths that only a release may
touch (`migrations/`, `fields.json`, `module-catalog.json`, `flake.nix`). The site's verifier
applies the path list too, so a mistake in the release tooling cannot put a migration on a patch.

### D3. One release, two branches: how the lines stay the same

Each release in service has two branches on the private forge:

| Branch | Holds | Tagged |
|---|---|---|
| `rel/X.Y` | the release as cut, plus every patch whose embargo has ended | `vX.Y.N`: the **public** line |
| `sub/X.Y` | `rel/X.Y` plus the patches still under embargo | `vX.Y.N+sK`: the **subscriber** line, K patches ahead of public `vX.Y.N` |

The rules that keep them from drifting:

1. **A patch enters through `sub` only.** It is cherry-picked from `main` onto `sub/X.Y`. Nothing
   is ever committed to `rel` directly.
2. **A patch leaves the embargo in the order it entered.** Fourteen days after its subscriber
   release, the oldest embargoed patch is cherry-picked from `sub` onto `rel`, `rel` is merged
   back into `sub`, and both are tagged: public `vX.Y.(N+1)` and subscriber `vX.Y.(N+1)+s(K-1)`.
   The merge changes no file. The boundary's release-fault ports (below) are the one case taken
   out of order; the check covers them like any other.
3. **The check.** `tappaas-train.sh embargo-check` computes, for every line: the tree of `sub`
   must equal the tree of `rel` with the embargoed patches applied in order, and when no patch is
   under embargo the two trees must be identical. It runs before every tag on either branch. A
   mismatch stops the publication. The lines cannot drift without it being seen the same day.
4. **Each tag says what it holds.** The tag message of a subscriber tag lists the ids of the
   patches still under embargo; a public tag lists the ones it has taken. The verifier uses this
   in D8.
5. **A fault found during the soak is a patch like any other.** It goes to `sub`, and is public
   14 days later. If the release it fixes becomes public production before that, the boundary
   takes it across early (below).

**At a boundary**, for the release leaving staging:

- subscriber production moves to the tip of `sub/X.Y`;
- public production moves to the tip of `rel/X.Y`, after the boundary has ported every patch on
  `sub/X.Y` that fixes a fault this release introduced. Those are named when they are made
  (`fix … --release-fault`). The public never gets a release with a known fault of its own that
  subscribers have already had fixed. Security and other patches keep their 14 days.

A release line was cut from `main` 14 days before it becomes production, so every fix that was on
`main` at the cut is in `rel/X.Y` from the start, and each of them reached subscribers at least
14 days earlier on the previous line. The cadence and the embargo are both 14 days on purpose.

### D4. The daily rhythm and the gates

| When | Who | What |
|---|---|---|
| nightly | the staging site (hrossen) | scan, rescan, `candidates` (ADR-047 D8) |
| morning | a maintainer | the queues; fixes, pin moves and records are pushed to private `main` |
| on that push | the build | the **decision feed** (D5): lint, sign, gate, publish to subscribers the same day |
| the same day | `tappaas-train.sh patch-day` | picks the day's patch commits onto `sub/X.Y` for each line in service; `patch-scope`; `embargo-check` |
| **gate 1**, hours | hrossen | every NixOS module's system is built from each patched line; the canary guest is deployed from it and its module test runs; a moved image runs its module's test |
| **gate 2**, two days | hrossen and makerfloss | both run the patched staging line. The patch moves on unless `tappaas-train fault` records a fault against it |
| **gate 3**, a signature | a maintainer with a release key | `vX.Y.N+sK` on each line; subscribers get it that night |
| 14 days after gate 3 | the forge, then a maintainer | the port of D3, `embargo-check`, a signature on the public tag, a push to Codeberg |

So a fix written on day 0 is on subscriber production on day 2 and on public production on day
16. Days with no patch commit produce nothing.

**Known-exploited, the same day.** A CVE on the known-exploited list, or a critical one reachable
from the network on a default deployment, skips gate 2: `patch-day --expedite --why "security:
…"`. Gate 1 and the signature stay.

**The canary ring does not run the production line.** hrossen follows unstable and makerfloss
staging. A production-line patch is proved by gate 1 (built for every module, deployed to the
canary guest from that line) and soaked as the same commits on the staging line. That is weaker
than a site living on the production line for two days, and it is what two sites allow.

**Signing, made cheap.** One sitting a day at most. `tappaas-train.sh sign-day` on the signer's
machine fetches every tag that waits, prints one screen for each (the commits, the scope check,
the gates passed, the tree hash, for a public tag the embargo dates), and signs them after one
confirmation. A typical day is one subscriber tag per line and, two weeks into the model, one
public tag per line: two to four signatures from one command. The signature stays a person's
statement about one commit, as ADR-033 has it; no automation key can sign a release.

### D5. The decision feed

ADR-047's component records, delivered as data the day they are made.

- **Content.** One file, `tappaas-decisions.json`: every module's records from private `main`,
  with `sequence`, `generated`, `validUntil` (14 days) and the source commit. Records name the
  versions they hold for, so one feed serves every line.
- **Built by an event**: a push to `main` that touches a records file. No schedule.
- **Signed** with `ssh-keygen -Y sign -n tappaas-decisions` by a **stream key** that
  `.tappaas/allowed_signers` restricts to that namespace. It can sign a feed and nothing else. It
  lives with the build on the private forge.
- **Gate.** hrossen applies each feed first. It is published when the lint passed, the scan with
  it did not fail, and every unit whose level dropped is explained by a record that changed.
- **Verified at the site**: the signature and namespace, a `sequence` higher than the last, a
  `validUntil` in the future, the schema. A feed that fails is not applied. Past `validUntil` the
  site falls back to the records in its checkout and raises `decisions-stale`.
- **A known-exploited CVE counts at its upstream severity whatever the feed says.** That rule is
  in the site's code and uses the scanner's own database.
- **Paid.** The feed is served only to subscribers, from the forge (D7). The same records are
  patch commits on `sub`, so they reach the public line with the 14-day port, and a free site
  reads them from its checkout as it does today.

### D6. What becomes of the public repository, the mirror and the docs

| Thing | Today | With this ADR |
|---|---|---|
| Codeberg `TAPPaaS` | all development; `main`, `staging`, `stable` | the **publication repository**: `stable` (the public line) and the signed public tags. Default branch `stable`. No `main`, no `staging`. Nothing is developed there |
| History on Codeberg | every commit as it is pushed | the same commits, arriving with the release that contains them: a feature four weeks after it was written, a patch 14 days after subscribers got it |
| Codeberg CI | builds and tests on push | none. Releases arrive tested and signed |
| Issues | Codeberg | Codeberg stays the public tracker for faults and requests. Security reports and embargoed work are tracked on the forge |
| GitHub mirror | push mirror of Codeberg | unchanged, and it mirrors only Codeberg. It must never be pointed at the forge. Subscriber tags (`+sK`) never reach Codeberg, so they never reach GitHub |
| Images on GitHub Releases | built at releases | unchanged. Images change at feature releases, which both lines get on the same day, so they stay public |
| Documentation site | built from the repository | built from public `stable` at each public release. It describes what the public can run. A preview for unreleased work is served from the forge to maintainers and contributors |
| ADRs and the roadmap | on `main`, public at once | in the repository, so public with the release. An open question asks whether the roadmap should be published apart |
| `channels.json` | declares unstable, staging, production | the public repository declares production only. The forge's repositories declare all three, and the subscriber line |

**Outside contributors.**

- **Regular contributors** get an account on the forge and work against private `main` as today.
  They see embargoed patches, so they sign the contributor agreement (D9) first.
- **A pull request on Codeberg** is made against public `stable`, which is weeks behind `main`.
  A maintainer ports it to private `main`, with the author kept on the commit. It appears on
  Codeberg with the release that contains it. This is slower for the contributor than today and
  the page that explains contributing has to say so.
- **A fork** such as AndreasJe's keeps working against the public line. Integrating it becomes a
  port to `main` like any pull request; with a forge account it becomes direct.
- **Community and site module repositories** are their own repositories and are not affected.

### D7. The forge: tokens on a server we run

**What it is.** A Forgejo instance, installed as a TAPPaaS site of its own (the `forgejo` and
`woodpecker` modules, identity, backup), on a rented server. Not hrossen: the product must not
depend on the test system. It holds:

| Repository | Readable by | Content |
|---|---|---|
| `tappaas/TAPPaaS` | maintainers, contributors | `main`, `staging`, every `rel/` and `sub/` branch, all tags |
| `tappaas/production` | subscribers (read-only) | the subscriber line: `stable` and the `+sK` tags, pushed there after gate 3. Its releases carry the decision feed |

A subscriber can read `tappaas/production` and nothing else. Development is not visible to them.

**How a site authenticates.**

- A subscription creates one account per site with one read-only access token. The operator
  enters it once: `site-manager subscription set` reads it from the terminal and stores it with
  the site's secrets. It is never put in a URL or a config file.
- The site's repository entry for TAPPaaS points at the forge. Fetches go over HTTPS with the
  token through a credential helper. The decision feed is fetched the same way, once a night,
  inside the update the site already runs.
- What arrives is verified exactly as today (ADR-033 D6): the tag's signature against the
  enrolled signers, the tree hash, the ancestry. The forge is transport. A compromised forge can
  withhold a release; it cannot make a site run something unsigned.

**Revocation and figures.** Disabling the account ends access at once. The forge's access log
gives, per site: last fetch, the tag it fetched, and so which sites are behind. A small licence
service beside Forgejo holds `site → token → paid until` and disables accounts when a
subscription ends, after a grace period.

**When a subscription lapses**, the site falls back to the public line without the operator
doing anything, and without ever going backwards:

1. The forge answers the site's fetch with "subscription ended" (a status the site can tell from
   an outage). The site raises a `subscription` warning and stops asking for the feed.
2. The site keeps the subscriber tag it runs. It paid for those patches.
3. Each night it looks at the public line. It moves there when a public tag exists whose base
   release is the same or newer **and** whose tag message lists every patch its own tag held
   under embargo (D3 rule 4). That is at most 14 days later, or at the next boundary.
4. From then on it follows Codeberg as any free site.

A public tag is not a git descendant of a subscriber tag, so ADR-033's "never backwards" rule
gains this one case: a move from a subscriber tag to a public tag that contains all its patches.
The same rule lets a free site subscribe: a subscriber tag always contains its public base.

**When the forge is down**, subscribers get no patches until it is back. Nothing breaks: a site
stays on its last verified release. An outage longer than `validUntil` makes the feed stale and
sites say so.

### D8. What changes in the verifier and the train

- Release tags match `vX.Y.N` and `vX.Y.N+sK`. A subscriber tag's message carries
  `embargoed: <patch ids>`; a public tag's `patches: <patch ids>`.
- The ancestry rule accepts the two cross-line moves of D7 and no other.
- `patch-scope` (paths) runs in the verifier for any tag that is not a feature release.
- The train gains `patch-day`, `embargo-check`, `sign-day`, and the port. `tappaas-train patch`
  (ADR-028 D15) becomes `patch-day --expedite`.
- The stream key is one line in `allowed_signers` with `namespaces="tappaas-decisions"`.

### D9. The licence

The repository is MPL-2.0. "Paying customers only, public after 14 days" is compatible with it
under conditions, and they differ by how hard the paywall must be.

**What MPL-2.0 requires, and does not.**

- It requires that whoever receives the software can get its source under MPL. Subscribers
  receive source. It does not require publishing to the public, and it sets no deadline. A
  14-day delay before public release breaks nothing.
- It gives every recipient the right to pass the software on, and it forbids a licensee from
  restricting that right for others. Under plain MPL a subscriber may publish a patch on the day
  they receive it, and a subscription contract that forbids it would be asking them to give up a
  right the licence grants.

**So there are two ways to run the embargo.**

| | **A. Plain MPL** | **B. Subscriber terms during the embargo** |
|---|---|---|
| Patches reach subscribers under | MPL-2.0 | a subscriber licence: use on the subscribed sites, no redistribution until public release; MPL-2.0 from that day |
| The embargo holds because | subscribers have little reason to leak, and the token ends if they do | the licence says so |
| Needs | nothing | every copyright holder's agreement to distribute their contribution under the subscriber terms for 14 days |
| Weakness | one subscriber can lawfully publish everything daily | the agreements; and it applies only to what TAPPaaS owns |

For B, three things have to hold:

1. **Rights in all of the code.** Lars, Erik and Andreas have commits in the tree, and those
   contributions came in under MPL. Each has to agree, in writing, that TAPPaaS may distribute
   their past and future contributions under the subscriber terms for the embargo period.
   Without that, B covers only the parts whose author agreed.
2. **A contributor agreement from now on**, signed before a forge account or a merged pull
   request: MPL inbound, plus that same right.
3. **Third-party parts keep their own licences.** Modules that carry others' code (the tree has
   third-party licence and authors files under some modules) are outside the subscriber terms. A
   patch that only moves a lock or a pin points at upstream's public fix, which nobody can
   embargo anyway.

Either way: what is embargoed is our work (the triage, the tested and signed patch). The
upstream CVE and the upstream fix are public from the first minute.

This section is an engineer's reading of the licence. A lawyer should confirm it before the
first subscription is sold.

## Consequences

- **Good.**
  - A subscriber gets a fix in two days and a decision the same day; a known-exploited fix the
    same day.
  - The public line loses nothing against today: it gets features at the same boundary and fixes
    within 14 days, where today a fix waits up to four weeks.
  - The two production lines are held together by a tree check, not by care.
  - Revocation is immediate and usage is visible.
- **Cost.**
  - A server to run, back up and keep available, with a licence service.
  - Moving development off Codeberg: accounts, CI, the docs build, the mirror's source, every
    session's and contributor's remotes.
  - Two branches and two tag series per release, a daily patch routine and a daily signature.
  - Open development ends. Outside contributions get slower.
- **Risk.**
  - **A patch breaks production.** Gate 1 builds every module; gate 2 is two days on two sites;
    the way back is the previous tag by an operator command.
  - **The lines drift.** `embargo-check` before every tag.
  - **The embargo leaks.** D9. The design assumes it can and still works: a leak gives the public
    early what it gets on day 14.
  - **The public is left exposed for 14 days to something subscribers have had fixed.** See the
    first open question.
  - **The forge is the single way to patches for subscribers.** Signed content limits what a
    compromise can do; an outage delays patches and breaks nothing.

## Alternatives considered

- **A soft paywall over open development** (v0.1): everything authored on public `main`, the
  daily delivery sold. Replaced by the operator's decision.
- **The public line as the subscriber line 14 days late, with no second branch.** No porting at
  all, and the simplest. It fails at the boundary: features would also arrive 14 days late on the
  public line, or the public would get every fresh patch at each boundary.
- **Encryption to a site key on a public host.** No server, and no instant revocation or usage
  figures. Replaced by tokens.
- **Move the boundary forward for every fix** (ADR-028 today). Kept for anything outside the
  patch scope.

## Phases

| Phase | Content | Done when |
|---|---|---|
| S0 | The licence: D9 decided, the agreements signed, a lawyer's confirmation | Path A or B is chosen in writing |
| S1 | The forge as a TAPPaaS site; development, CI and the docs preview move there; Codeberg becomes the publication repository; the mirror and the docs site build from it | A boundary runs from the forge and Codeberg receives only `stable` and its tags |
| S2 | `rel/` and `sub/` branches, `+sK` tags, `patch-scope`, `embargo-check`, the port, the verifier's cross-line rule | A rehearsal line takes three patches, ports them in order, and the check stops a deliberately wrong port |
| S3 | `patch-day`, gates 1 and 2, `sign-day`, `--expedite` | A fix pushed in the morning is on a subscribed test site two days later with one signing command |
| S4 | The decision feed: builder, stream key, site verification, fallback | hrossen applies a feed and refuses a replayed and an expired one |
| S5 | Tokens: accounts, `site-manager subscription`, the licence service, lapse and fallback | A lapsed test site holds its tag, then joins the public line by itself when the public tag covers its patches |

## Settled in review

Settled in v0.2 (operator, 2026-11-11): a hard paywall with a 14-day embargo; unstable and
staging private; production as a subscriber line and a public line with the same feature
boundaries; per-site tokens on a server we run, with fallback to the public line when a
subscription lapses; the feed and the patches both paid; a person signs each patch release with a
release key; the canary ring is hrossen and makerfloss for two days.

## Open questions

1. **Does a known-exploited fix go to the public line at once?** As decided, the public waits 14
   days for every patch. For a CVE that is being exploited and is reachable on a default
   deployment, that means knowingly leaving free sites open for two weeks. Proposed: these, and
   only these, are ported at once.
2. **Licence path A or B** (D9), and whether Erik and Andreas agree to B.
3. **Where the forge runs**, who else has administrative access, and what availability it must
   have.
4. **Grace period** when a subscription ends, before the token is disabled.
5. **A production-line canary.** hrossen and makerfloss run unstable and staging. Should one
   subscribed production site join the ring?
6. **The roadmap and the ADRs** become public four weeks late with the code. Publish the roadmap
   apart, on the docs site?
7. **Bug fixes in the paid stream.** Every `fix` commit is a candidate for the daily patch. That
   is more change on production than security alone. Should a bug fix need a severity to qualify,
   or does every fix go?
