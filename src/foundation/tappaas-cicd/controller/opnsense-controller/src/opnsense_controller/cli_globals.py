"""Shared helpers for global CLI options that work both before AND after the
subcommand.

argparse subparser gotcha (#379): when the same option is declared on both the
top-level parser and a subparser (so it can appear on either side of the
subcommand), the subparser parses into a *fresh* namespace and merges it back
onto the main namespace — so the subparser's default clobbers a value the user
supplied BEFORE the subcommand. With `caddy-manager --no-ssl-verify list` the
flag was silently dropped and SSL verification stayed on.

The fix has two parts, both required:

1. Declare the global options with ``default=argparse.SUPPRESS`` (use
   :func:`make_global_parent`) so an *absent* flag writes nothing to the
   namespace and therefore cannot clobber a value parsed on the other side.
2. Seed the namespace with the real defaults *before* parsing (use
   :func:`parse_with_globals`), so those defaults are present when no flag is
   given, without going through ``set_defaults`` (which the subparser merge
   overrides).
"""

import argparse


def make_global_parent(add_help: bool = False) -> argparse.ArgumentParser:
    """Return a parent parser whose options don't write unless supplied.

    Add the shared global options to the returned parser, then pass it as a
    ``parents=[...]`` entry to BOTH the top-level parser and every subparser.
    """
    return argparse.ArgumentParser(
        add_help=add_help, argument_default=argparse.SUPPRESS
    )


def parse_with_globals(parser, defaults, argv=None):
    """Parse args with the global-option defaults seeded into the namespace.

    ``defaults`` maps each global dest to its real default value. Because the
    global options use ``SUPPRESS``, an absent flag leaves the seeded default in
    place, and a flag on either side of the subcommand is preserved.
    """
    namespace = argparse.Namespace()
    for dest, value in defaults.items():
        setattr(namespace, dest, value)
    return parser.parse_args(argv, namespace=namespace)
