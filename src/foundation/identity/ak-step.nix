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
#   fresh install (no Authentik)  → straight to the target
#
# What the guest runs comes from the build facts update-os.sh collects on the
# guest before every build (build-facts.sh) and stages as
# /etc/nixos/tappaas-build-facts.env. The build runs on the mothership (#774),
# where the guest's own files do not exist: reading them here made every guest
# look like a fresh install and jump straight to the target, which Authentik
# refuses — SSO down until the update rolled back (#797). So "fresh" must be
# SAID (AUTHENTIK_INSTALLED=none); no facts, or a database whose version is
# not known, stops the build before it switches, and the old version keeps running.
#
# The pre-check's blocker (AUTHENTIK_STEP_BLOCKED) stops a step that would fail
# its migration (2025.12 refuses duplicate group names) the same way.
#
# The path is a STRING, never a path literal: a literal would copy the file into
# the nix store.
#
# builtins only, so test-authentik-step.sh can evaluate it without nixpkgs.
{
  lines,
  factsFile ? "/etc/nixos/tappaas-build-facts.env",
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

  # /etc/nixos/tappaas-build-facts.env as an attrset: one KEY=value per line.
  facts =
    if !(builtins.pathExists factsFile) then
      throw "authentik: no build facts (${factsFile}) — update this guest through module-manager, which collects what it runs before it builds (#797)"
    else builtins.listToAttrs (map (m: { name = builtins.elemAt m 0; value = builtins.elemAt m 1; })
      (builtins.filter (m: m != null)
        (map (l: builtins.match "([A-Z_]+)=(.*)" l)
          (builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile factsFile))))));
  said = facts.AUTHENTIK_INSTALLED or (throw "authentik: the build facts (${factsFile}) do not say what the guest runs (#797)");
  installed =
    if said == "none" then null
    else if said == "unknown" then
      throw "authentik: the guest has a database but no record of the Authentik version it runs — cannot choose a step. Write it to /var/lib/authentik/tappaas-version on the guest (what `podman inspect authentik-server` runs), then update again (#797)"
    else trim said;

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

  blocked = trim (facts.AUTHENTIK_STEP_BLOCKED or "");
  # What the guest's server container runs: never step below it (a lost or
  # wrong record must not become a downgrade, which Authentik cannot undo).
  running = let r = trim (facts.AUTHENTIK_RUNNING or "none"); in if r == "none" || r == "" then null else r;
in
if running != null && older step running then
  throw "authentik: the guest's server runs ${running}, newer than the step ${step} this build would install — Authentik cannot go back a version; check /var/lib/authentik/tappaas-version on the guest (#797)"
else if installed != null && older target installed then
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
