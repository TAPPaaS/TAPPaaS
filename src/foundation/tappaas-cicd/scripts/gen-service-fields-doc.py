#!/usr/bin/env python3
"""Generate the FIELDS section of each service README from its manifest (#567).

The per-field documentation is generated, not written, for the reason #567
exists: a field's definition and its change semantics live in the manifest, and
a hand-kept table beside them is a second copy that drifts. Only the region
between the markers is touched — the service's own prose above it is the
author's and is never rewritten.

Each field gets its own section with a standardised table covering ALL its
attributes, per the operator's note on #567: not only the update policy.

    gen-service-fields-doc.py            # rewrite every service README
    gen-service-fields-doc.py --check    # fail if any is out of date
"""
import json
import pathlib
import sys

BEGIN = "<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->"
END = "<!-- END GENERATED FIELDS -->"

FOUNDATION = pathlib.Path(__file__).resolve().parents[2]

# Attribute -> how it is labelled. Order is the order of the table.
DEFN_ROWS = [
    ("type", "Type"),
    ("default", "Default"),
    ("values", "Allowed values"),
    ("enum", "Allowed values"),
    ("format", "Format"),
    ("pattern", "Pattern"),
    ("minimum", "Minimum"),
    ("maximum", "Maximum"),
    ("example", "Example"),
    ("requiredBy", "Required by"),
    ("usedBy", "Used by"),
    ("deprecated", "Deprecated"),
]
CHANGE_ROWS = [
    ("class", "Change class"),
    ("apply", "Apply mode"),
    ("normalize", "Normalizer"),
    ("liveKey", "Reported as"),
    ("setFlag", "Provider flag"),
    ("hook", "Hook"),
    ("composite", "Composite input to"),
    ("sideEffects", "Side effects"),
]


def fmt(v):
    if isinstance(v, bool):
        return "`true`" if v else "`false`"
    if v is None:
        return "*(none)*"
    if isinstance(v, list):
        # A list of scalars reads better as inline code; anything structured is
        # JSON, because a Python repr with single quotes is not a value anyone
        # can paste into a module config.
        if all(isinstance(x, (str, int, float, bool)) for x in v):
            return ", ".join(f"`{x}`" for x in v) if v else "*(none)*"
        return f"`{json.dumps(v)}`"
    if isinstance(v, dict):
        # A values map documents each option; anything else is a literal.
        if all(isinstance(d, str) for d in v.values()):
            return "<br>".join(f"`{k}` — {d[:110]}" for k, d in v.items())
        return f"`{json.dumps(v)}`"
    s = str(v)
    return f"`{s}`" if len(s) < 90 else s


def section(name, entry, schema_defn):
    merged = dict(schema_defn or {})
    merged.update(entry)
    out = [f"### `{name}`", ""]
    if merged.get("description"):
        out += [merged["description"], ""]
    rows = []
    for key, label in DEFN_ROWS:
        if key in merged:
            rows.append((label, fmt(merged[key])))
    for key, label in CHANGE_ROWS:
        if key in merged:
            rows.append((label, fmt(merged[key])))
    if rows:
        out += ["| Attribute | Value |", "|---|---|"]
        out += [f"| {k} | {v} |" for k, v in rows]
        out.append("")
    if merged.get("note"):
        out += [f"**About the field.** {merged['note']}", ""]
    if merged.get("changeNote"):
        out += [f"**Why this change class.** {merged['changeNote']}", ""]
    return out


def render(coord, manifest, schema):
    fields = manifest.get("fields", {})
    comps = manifest.get("composites", {})
    body = [BEGIN, "", "## Fields", ""]
    if not fields:
        body += [f"`{coord}` declares no fields.", ""]
    else:
        body += [
            f"`{coord}` owns **{len(fields)}** declared field(s). Each table below "
            "carries the field's full definition and, where the service applies it, "
            "its ADR-020 change semantics.",
            "",
        ]
        for name in fields:
            body += section(name, fields[name], schema.get(name))
    if comps:
        body += ["## Composites", ""]
        for name, c in comps.items():
            body += [
                f"### `{name}`",
                "",
                f"Built from {', '.join('`' + i + '`' for i in c.get('inputs', []))}.",
                "",
            ]
            rows = [(l, fmt(c[k])) for k, l in CHANGE_ROWS if k in c]
            if rows:
                body += ["| Attribute | Value |", "|---|---|"]
                body += [f"| {k} | {v} |" for k, v in rows]
                body.append("")
            if c.get("changeNote"):
                body += [f"**Why this change class.** {c['changeNote']}", ""]
    body.append(END)
    return "\n".join(body)


def compose(*flags):
    """Run compose-fields.sh, or exit 2 saying why it refused.

    Exit 2 is not exit 1. Exit 1 means a README disagrees with its manifest and
    regenerating fixes it; exit 2 means the manifests disagree with EACH OTHER
    and no README is at fault. Reporting a field collision as stale docs sends
    the reader to regenerate a file that is already correct.
    """
    import subprocess
    composer = FOUNDATION / "tappaas-cicd" / "scripts" / "compose-fields.sh"
    r = subprocess.run([str(composer), str(FOUNDATION), *flags],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        print("manifest collision — the schema could not be composed; "
              "no README was checked", file=sys.stderr)
        sys.exit(2)
    return r.stdout


def label(path):
    """Name a file by the repository that registers it, not by this checkout.

    Discovery spans every repo in site.json .repositories, so a bare relative
    path is ambiguous the moment two of them own a services/ directory.
    """
    for anc in path.parents:
        if (anc / "src" / "module-catalog.json").is_file():
            return f"{anc.name}/{path.relative_to(anc)}"
    return str(path)


def main():
    check = "--check" in sys.argv
    # The COMPOSED view (#567): a service manifest now carries its own field
    # definitions inline, and schemas/module-fields.json holds only the generic
    # 19. Composing covers both — a field defined in the module tier
    # (cluster/fields.json) is still documented in the services that use it.
    schema = json.loads(compose())["fields"]

    # Document what the SCHEMA is composed from: every service manifest in every
    # repository site.json registers, asked of the one discovery that also
    # builds the schema. Globbing this checkout's foundation/ instead would
    # document a subset of what it validates against — a community module could
    # contribute a field definition and never have its own README checked.
    manifests = sorted(
        pathlib.Path(line) for line in compose("--list-tiers").splitlines()
        if line and pathlib.Path(line).parent.parent.name == "services"
    )

    stale, wrote = [], 0
    for mf in manifests:
        svc = json.load(open(mf))
        coord = svc.get("service") or svc.get("scope", "?")
        readme = mf.parent / "README.md"
        generated = render(coord, svc, schema)

        old = readme.read_text() if readme.exists() else ""
        if BEGIN in old and END in old:
            head, rest = old.split(BEGIN, 1)
            _, tail = rest.split(END, 1)
            new = head + generated + tail
        else:
            intro = old.rstrip() + "\n\n" if old.strip() else (
                f"# {coord} service\n\n"
                "<!-- Describe what this service provides and how a module uses it. "
                "This prose is yours; the generated block below is not. -->\n\n")
            new = intro + generated + "\n"

        if new != old:
            if check:
                stale.append(label(readme))
            else:
                readme.write_text(new)
                wrote += 1

    if check:
        if stale:
            print("service README field sections are out of date:")
            for s in stale:
                print(f"  {s}")
            print("regenerate: scripts/gen-service-fields-doc.py")
            return 1
        print("every service README field section matches its manifest")
        return 0
    print(f"wrote {wrote} service README(s)")
    return 0


sys.exit(main())
