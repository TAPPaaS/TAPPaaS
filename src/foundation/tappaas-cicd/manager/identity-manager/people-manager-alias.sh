#!/usr/bin/env bash
# people-manager — the pre-#628 name of identity-manager, kept for ONE stable
# cycle so scripts outside this repository keep working while they change.
# Warns on stderr (stdout stays the command's own) and runs identity-manager
# with the same arguments. Remove after the release that follows #628.
echo "people-manager: renamed to identity-manager (#628) — this alias goes away after one stable release" >&2
exec identity-manager "$@"
