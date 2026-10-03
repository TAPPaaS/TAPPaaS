# ak-step.nix — the Authentik version this build installs (#748).
#
# Authentik refuses to skip a release line (2026.8 checks before it migrates),
# moves to each line's latest patch before the next, and cannot go back. So a
# guest moves at most ONE step per build, along `lines` (each release line's
# latest patch, oldest first, the last one the target):
#
#   on an older patch of a line   → that line's latest patch
#   on a line's latest patch      → the next line
#   on the target                 → stays
#   fresh install (no database)   → straight to the target
#
# What the guest runs is read at build time — nixos-rebuild evaluates as root, on
# the guest — from the version file a successful start writes (identity.nix,
# authentik-version-record). A guest from before that file existed has the env
# file its first boot generated: it runs the one version ever pinned until then.
#
# A blocker file, written by the guest's own pre-check, stops a step that would
# fail its migration (2025.12 refuses duplicate group names) BEFORE anything
# changes: the evaluation throws, the rebuild never switches, the old version
# keeps running, and the update says why.
#
# Paths are STRINGS, never path literals: a literal would copy the file into the
# world-readable nix store (the env file holds secrets).
#
# builtins only, so test-authentik-step.sh can evaluate it without nixpkgs.
{
  lines,
  versionFile ? "/var/lib/authentik/tappaas-version",
  legacyMarker ? "/etc/secrets/authentik.env",
  legacyVersion ? "2025.2.1",
  blockerFile ? "/var/lib/authentik/tappaas-step-blocked",
}:
let
  # The file's first line, without surrounding whitespace; "" when there is none.
  trim = s:
    let m = builtins.match "[[:space:]]*([^\n]*[^[:space:]])[[:space:]]*" s;
    in if m == null then "" else builtins.head m;
  lineOf = v:
    let m = builtins.match "([0-9]+\\.[0-9]+)\\.[0-9]+" v;
    in if m == null then throw "authentik: '${v}' is not a version (YYYY.M.P)" else builtins.head m;
  older = a: b: builtins.compareVersions a b < 0;
  n = builtins.length lines;
  target = builtins.elemAt lines (n - 1);

  recorded = if builtins.pathExists versionFile then trim (builtins.readFile versionFile) else "";
  installed =
    if recorded != "" then recorded
    else if builtins.pathExists legacyMarker then legacyVersion
    else null;

  # index of the installed version's line in `lines`, or null
  idxs = builtins.filter (i: lineOf (builtins.elemAt lines i) == lineOf installed)
           (builtins.genList (i: i) n);
  idx = if idxs == [ ] then null else builtins.head idxs;

  step =
    if installed == null then target
    else if idx == null then
      (if older installed (builtins.head lines)
       then throw "authentik: the guest runs ${installed}, older than the first step this release knows (${builtins.head lines}) — step it by hand, or restore"
       else throw "authentik: the guest runs ${installed}, a line this release does not know (target ${target}) — Authentik cannot go back a version")
    else if older installed (builtins.elemAt lines idx) then builtins.elemAt lines idx
    else if idx + 1 < n then builtins.elemAt lines (idx + 1)
    else target;

  blocked = if builtins.pathExists blockerFile then trim (builtins.readFile blockerFile) else "";
in
if installed != null && older target installed then
  throw "authentik: the guest runs ${installed}, newer than this release's ${target} — Authentik cannot go back a version"
else if installed != null && step != installed && blocked != "" && !(older step "2025.12.0") then
  throw "authentik: the step ${installed} -> ${step} would fail its migration — ${blocked}"
else {
  inherit installed target step;
  version = step;
  # What the version needs, decided here so identity.nix states it once:
  #   Redis: no longer used from 2025.10
  #   files: served from /data from 2025.12 (the /media mount moves to /data/media)
  redis = older step "2025.10.0";
  dataMount = !(older step "2025.12.0");
  onTarget = step == target;
}
