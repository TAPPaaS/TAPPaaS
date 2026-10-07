#!/usr/bin/env python3
"""roadmap-cut.py — move what a release carries out of ROADMAP.md's waves into its release section.

Run by `tappaas-train.sh boundary` just before main is promoted to staging, so the cut version's
tag already holds its own roadmap; nobody edits ROADMAP.md in the middle of a boundary.

    roadmap-cut.py --version 2.2 --date 2026-10-09 [--promoted 2.1] [--check] [--file ROADMAP.md]
    roadmap-cut.py --normalize [--check] [--file ROADMAP.md]

A cut does, in ROADMAP.md:
  - every ✅ row in a wave or in Future Work moves into a new `## Release <version>` section,
    under its wave and group heading. Everything on main is what the boundary cuts, so a ticked
    row is in this release — nothing is guessed;
  - each group heading gets its counts again: `released: N · done for <next>: M · open: K`;
    a group with nothing open leaves the waves, and so does a wave with no group left;
  - `## Next release` — the summary kept current while work lands — becomes the release's
    summary, and is left empty for the next one;
  - the release that just reached production (`--promoted`) gets its production date;
  - *At a glance* is recomputed.
A second run for a version that already has its section changes nothing (a resumed boundary).

--normalize rewrites the counts and *At a glance* into the current form without cutting.
--check prints what would change and writes nothing. Exit 0 on success, 1 on a ROADMAP.md it
cannot read, 2 on bad arguments.
"""

import argparse
import re
import sys

WAVE_RE = re.compile(r"^## Wave (\d+) — (.*)$")
RELEASE_RE = re.compile(r"^## Release (\S+) — (.*)$")
GROUP_RE = re.compile(r"^### (✅ )?(G\d+\.\d+) (.*)$")
ROW_RE = re.compile(r"^\| (✅ )?(?:FW )?#\d+ \|")
SEP_RE = re.compile(r"^\|[-:| ]+\|$")
COUNT_RE = re.compile(r" · (released(?: in [\d.]+)?|done for [\d.]+|open): (\d+)")
SCORE_RE = re.compile(r" — Ease ([LMH–-]) · Risk ([LMH–-])")
SUMMARY_BEGIN = "<!-- next-release summary -->"
SUMMARY_END = "<!-- /next-release summary -->"

NEXT_RELEASE_BLOCK = """## Next release

What the next release delivers, kept current as work lands — one short paragraph, written for
someone deciding whether to upgrade. The release-train boundary turns it into that release's
summary (`release/roadmap-cut.py`) and leaves this block empty again.

{begin}
{text}
{end}
"""


class RoadmapError(Exception):
    pass


def bump(version):
    m = re.match(r"^(\d+)\.(\d+)", version)
    if not m:
        raise RoadmapError("not a version: {}".format(version))
    return "{}.{}".format(m.group(1), int(m.group(2)) + 1)


# ── structure ────────────────────────────────────────────────────────────────────────────
def split_sections(lines):
    """[(heading or None, [lines])] at `## ` level, in order."""
    out = [(None, [])]
    for l in lines:
        if l.startswith("## "):
            out.append((l, []))
        else:
            out[-1][1].append(l)
    return out


def parse_group(head, body):
    m = GROUP_RE.match(head)
    _, gid, rest = m.groups()
    released = sum(int(n) for k, n in COUNT_RE.findall(rest) if k.startswith("released"))
    base = COUNT_RE.sub("", rest).rstrip()
    blocks = []                      # ("text", line) | ("table", [header, sep, rows...])
    i = 0
    while i < len(body):
        l = body[i]
        if l.startswith("| ") and i + 1 < len(body) and SEP_RE.match(body[i + 1]):
            tbl = [l, body[i + 1]]
            i += 2
            while i < len(body) and body[i].startswith("|"):
                tbl.append(body[i])
                i += 1
            blocks.append(("table", tbl))
            continue
        blocks.append(("text", l))
        i += 1
    return {"id": gid, "base": base, "released": released, "blocks": blocks}


def parse_wave(head, body):
    m = WAVE_RE.match(head)
    intro, groups, cur = [], [], None
    for l in body:
        if GROUP_RE.match(l):
            cur = [l, []]
            groups.append(cur)
        elif cur is None:
            intro.append(l)
        else:
            cur[1].append(l)
    return {"n": int(m.group(1)), "head": head, "intro": intro,
            "groups": [parse_group(h, b) for h, b in groups]}


def rows(group):
    for kind, b in group["blocks"]:
        if kind == "table":
            for r in b[2:]:
                yield r


def counts(group):
    done = sum(1 for r in rows(group) if r.startswith("| ✅ "))
    open_ = sum(1 for r in rows(group) if ROW_RE.match(r) and not r.startswith("| ✅ "))
    return done, open_


def heading(group, next_version):
    done, open_ = counts(group)
    parts = []
    if group["released"]:
        parts.append("released: {}".format(group["released"]))
    if done:
        parts.append("done for {}: {}".format(next_version, done))
    if open_:
        parts.append("open: {}".format(open_))
    return "### {}{} {}{}".format("✅ " if open_ == 0 else "", group["id"], group["base"],
                                   "".join(" · " + p for p in parts))


def group_lines(group, next_version):
    out = [heading(group, next_version)]
    for kind, b in group["blocks"]:
        out.extend(b if kind == "table" else [b])
    return out


def first_paragraph(blocks):
    para = []
    for kind, b in blocks:
        if kind != "text":
            if para:
                break
            continue
        if not b.strip() or b.startswith("#"):
            if para:
                break
            continue
        para.append(b)
    return para


# ── the cut ──────────────────────────────────────────────────────────────────────────────
def take_done(group):
    """Remove the group's ✅ rows; return [(subheading or None, header, sep, rows)] taken.
    A `####` subsection whose tables all empty goes with them."""
    taken, new_blocks, sub = [], [], None
    for kind, b in group["blocks"]:
        if kind == "text" and b.startswith("#### "):
            sub = b
        if kind != "table":
            new_blocks.append((kind, b))
            continue
        done = [r for r in b[2:] if r.startswith("| ✅ ")]
        keep = [r for r in b[2:] if not r.startswith("| ✅ ")]
        if done:
            taken.append((sub, b[0], b[1], done))
        if keep:
            new_blocks.append(("table", b[:2] + keep))
    # drop a `####` subsection left with no table at all
    cleaned, i = [], 0
    while i < len(new_blocks):
        kind, b = new_blocks[i]
        if kind == "text" and b.startswith("#### "):
            j = i + 1
            while j < len(new_blocks) and not (new_blocks[j][0] == "text" and new_blocks[j][1].startswith("#### ")):
                j += 1
            had_table = any(k == "table" for k, _ in new_blocks[i:j])
            originally_tabled = any(t[0] == b for t in taken)
            if originally_tabled and not had_table:
                i = j
                continue
        cleaned.append((kind, b))
        i += 1
    group["blocks"] = cleaned
    group["released"] += sum(len(t[3]) for t in taken)
    return taken


def glance(waves, next_version):
    out = ["## At a glance", "",
           "Per group: its scores, and where its rows are. *released* = shipped in a release (the "
           "release sections say which); *done for {v}* = done on `main`, ships at the next "
           "boundary; *open* = still to do.".format(v=next_version), "",
           "| Wave | Group | Ease | Risk | released | done for {} | open |".format(next_version),
           "|------|-------|:-:|:-:|---:|---:|---:|"]
    for w in sorted(waves, key=lambda w: -w["n"]):
        for g in w["groups"]:
            done, open_ = counts(g)
            s = SCORE_RE.search(g["base"])
            title = re.sub(r" — added .*$", "", SCORE_RE.sub("", g["base"]))
            out.append("| {} | {}{} {} | {} | {} | {} | {} | {} |".format(
                w["n"], "✅ " if open_ == 0 else "", g["id"], title,
                s.group(1) if s else "–", s.group(2) if s else "–",
                g["released"] or "–", done or "–", open_ or "–"))
    return out


def latest_release(sections):
    for head, _ in sections:
        if head and RELEASE_RE.match(head):
            return RELEASE_RE.match(head).group(1)
    return None


def run(text, version=None, date=None, promoted=None, normalize=False):
    lines = text.rstrip("\n").split("\n")
    sections = split_sections(lines)
    if version and any(h and h.startswith("## Release {} — ".format(version)) for h, _ in sections):
        return text, ["Release {} is already in ROADMAP.md — nothing to cut".format(version)]
    waves = [parse_wave(h, b) for h, b in sections if h and WAVE_RE.match(h)]
    if not waves and not normalize:
        raise RoadmapError("no `## Wave N — …` section found")
    if not any(h and RELEASE_RE.match(h) for h, _ in sections):
        raise RoadmapError("no `## Release X — …` section found")
    report = []
    next_version = bump(version) if version else bump(latest_release(sections))

    release_body = []
    summary = ""
    if version:
        # the summary written ahead, in `## Next release`
        for h, b in sections:
            if h == "## Next release":
                t = "\n".join(b)
                if SUMMARY_BEGIN in t and SUMMARY_END in t:
                    summary = t.split(SUMMARY_BEGIN, 1)[1].split(SUMMARY_END, 1)[0].strip()
        moved_total, carried = 0, []
        for w in sorted(waves, key=lambda w: w["n"]):
            wave_out = []
            for g in list(w["groups"]):
                whole = counts(g)[1] == 0          # nothing open: the group leaves the waves
                intent = first_paragraph(g["blocks"])
                taken = take_done(g)
                if not taken:
                    continue
                moved_total += sum(len(t[3]) for t in taken)
                carried.append(g["id"])
                wave_out += ["", "#### {} {}".format(g["id"], SCORE_RE.sub(lambda m: m.group(0), g["base"]))]
                if whole and intent:
                    wave_out += [""] + intent
                last_sub = None
                for sub, hdr, sep, rs in taken:
                    if sub and sub != last_sub:
                        wave_out += ["", "#" + sub]      # #### → ##### inside a release
                        last_sub = sub
                    wave_out += ["", hdr, sep] + rs
                if whole:
                    w["groups"].remove(g)
                    report.append("{} is complete and leaves the waves".format(g["id"]))
            if wave_out:
                release_body += ["", "### Wave {} — {}".format(w["n"], WAVE_RE.match(w["head"]).group(2))] + wave_out
            if not w["groups"]:
                report.append("Wave {} is complete and leaves the waves".format(w["n"]))
        # Future Work's ticked rows
        fw_rows, fw_hdr = [], None
        for idx, (h, b) in enumerate(sections):
            if h and h.startswith("## Future Work"):
                new_b, i = [], 0
                while i < len(b):
                    if b[i].startswith("| ") and i + 1 < len(b) and SEP_RE.match(b[i + 1]):
                        fw_hdr = (b[i], b[i + 1])
                        new_b += b[i:i + 2]
                        i += 2
                        while i < len(b) and b[i].startswith("|"):
                            (fw_rows if b[i].startswith("| ✅ ") else new_b).append(b[i])
                            i += 1
                        continue
                    new_b.append(b[i])
                    i += 1
                sections[idx] = (h, new_b)
        if fw_rows:
            release_body += ["", "### Future Work", "", fw_hdr[0], fw_hdr[1]] + fw_rows
            moved_total += len(fw_rows)
        if moved_total == 0:
            report.append("no ✅ row to move: the release section says so")
        if not summary:
            summary = "{} issue{} done across {}.".format(
                moved_total, "" if moved_total == 1 else "s",
                ", ".join(carried) if carried else "Future Work") if moved_total else "No roadmap item done since the last release."
        head = ["## Release {} — staging {} · production at the next boundary".format(version, date), "",
                "Tag `v{}`, cut into staging {} by a release-train boundary.".format(version, date), "",
                summary]
        if release_body:
            head += ["", "The rows below are what it carried, by the wave and group they came from."]
        release_block = head + release_body + [""]
        report.insert(0, "{}: {} row{} move into the release ({} group{})".format(
            version, moved_total, "" if moved_total == 1 else "s", len(carried), "" if len(carried) == 1 else "s"))

    # reassemble
    out, wave_iter = [], iter(sorted(waves, key=lambda w: -w["n"]))
    waves_by_head = {w["head"]: w for w in waves}
    release_inserted = False
    for h, b in sections:
        if h and WAVE_RE.match(h):
            w = waves_by_head[h]
            if not w["groups"]:
                continue
            out += [h] + w["intro"]
            for g in w["groups"]:
                out += group_lines(g, next_version)
            continue
        if h == "## At a glance":
            out += glance(waves, next_version) + [""]
            continue
        if h == "## Next release":
            if version:
                out += NEXT_RELEASE_BLOCK.format(begin=SUMMARY_BEGIN, text="", end=SUMMARY_END).split("\n")
            else:
                out += [h] + b
            continue
        if h and RELEASE_RE.match(h) and not release_inserted:
            if not any(x == "## Next release" for x, _ in sections):
                out += NEXT_RELEASE_BLOCK.format(begin=SUMMARY_BEGIN, text="", end=SUMMARY_END).split("\n")
                report.append("added the `## Next release` block")
            if version:
                out += release_block
            release_inserted = True
        if h and promoted and h.startswith("## Release {} — ".format(promoted)) and "production at the next boundary" in h:
            h = h.replace("production at the next boundary", "production {}".format(date))
            report.append("Release {} reached production {}".format(promoted, date))
        if h is not None:
            out.append(h)
        out += b
    text_out = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).rstrip("\n") + "\n"
    return text_out, report


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--file", default="ROADMAP.md")
    ap.add_argument("--version")
    ap.add_argument("--date")
    ap.add_argument("--promoted")
    ap.add_argument("--normalize", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    if a.normalize == bool(a.version):
        ap.error("give --version (a cut) or --normalize, not both")
    if a.version and not re.match(r"^\d{4}-\d{2}-\d{2}$", a.date or ""):
        ap.error("--version needs --date YYYY-MM-DD")
    try:
        with open(a.file, encoding="utf-8") as fh:
            text = fh.read()
        new, report = run(text, a.version, a.date, a.promoted, a.normalize)
    except (OSError, RoadmapError) as e:
        print("roadmap-cut: {}".format(e), file=sys.stderr)
        return 1
    for r in report:
        print("roadmap-cut: " + r)
    if new == text:
        print("roadmap-cut: ROADMAP.md is unchanged")
        return 0
    if a.check:
        print("roadmap-cut: --check, nothing written")
        return 0
    with open(a.file, "w", encoding="utf-8") as fh:
        fh.write(new)
    print("roadmap-cut: wrote {}".format(a.file))
    return 0


if __name__ == "__main__":
    sys.exit(main())
