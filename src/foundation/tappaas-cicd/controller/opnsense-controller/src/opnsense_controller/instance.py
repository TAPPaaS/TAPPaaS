"""instance.py — a deployed config's module source directory (ADR-026 D6.2, #682).

The Python twin of ``lib/ts/src/instance.ts``. A deployed config records where its
module's code lives in ``moduleSource``; before #609 the field was called
``location``, and migration 0006 renames it. Every reader accepts both for one
stable cycle — a site restored from a backup, or one that has not yet taken 0006,
still carries the old name.

Reading only ``location`` is what #682 was: after 0006 the provider directory came
back empty, no auto-pinhole compiled, and `reconcile`'s prune then deleted every
established pinhole as an orphan.

A ``location`` that is not a string is never a path: `site.json` uses that name for
a physical place (an object), which ADR-026 D6.2 calls out as the trap.
"""

from __future__ import annotations


def module_source_of(data: dict | None) -> str:
    """The module's source directory: ``moduleSource``, else a string ``location``.

    "" when neither is a non-empty string.
    """
    if not isinstance(data, dict):
        return ""
    for key in ("moduleSource", "location"):
        value = data.get(key)
        if isinstance(value, str) and value:
            return value
    return ""
