# nc-major.nix — the Nextcloud major this build installs.
#
# Nextcloud refuses to skip a major, so a guest moves at most ONE major per build:
# min(targetMajor, installed + 1) — an existing site steps 33 -> 34 at one update
# and 34 -> 35 at the next, keeping its data; a fresh install goes straight to
# targetMajor.
#
# The installed major comes from the build facts update-os.sh collects on the
# guest before every build (build-facts.sh: config.php's 'version'), staged as
# /etc/nixos/tappaas-build-facts.env. The build runs on the mothership (#774),
# where config.php does not exist — reading it here made every site look fresh
# and jump majors (#797). So "fresh" must be SAID (NEXTCLOUD_INSTALLED_MAJOR=none);
# no facts, or an instance whose major is not known, stops the build before it
# switches. Only the major leaves the guest, never config.php's secrets.
#
# builtins only, so test-nextcloud-major-step.sh can evaluate it without nixpkgs.
{
  targetMajor,
  # major -> bool: does nixpkgs carry nextcloud<major>?
  available,
  factsFile ? "/etc/nixos/tappaas-build-facts.env",
}:
let
  # /etc/nixos/tappaas-build-facts.env as an attrset: one KEY=value per line.
  facts =
    if !(builtins.pathExists factsFile) then
      throw "nextcloud: no build facts (${factsFile}) — update this guest through module-manager, which collects what it runs before it builds (#797)"
    else builtins.listToAttrs (map (m: { name = builtins.elemAt m 0; value = builtins.elemAt m 1; })
      (builtins.filter (m: m != null)
        (map (l: builtins.match "([A-Z_]+)=(.*)" l)
          (builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile factsFile))))));
  said = facts.NEXTCLOUD_INSTALLED_MAJOR or (throw "nextcloud: the build facts (${factsFile}) do not say which major the guest runs (#797)");
  installed =
    if said == "none" then null
    else if said == "unknown" then
      throw "nextcloud: the guest has an instance but its major cannot be read from config.php — cannot choose a major (#797)"
    else if builtins.match "[0-9]+" said == null then throw "nextcloud: '${said}' is not a major (#797)"
    else builtins.fromJSON said;
  step = if installed == null then targetMajor
         else if installed + 1 < targetMajor then installed + 1
         else targetMajor;
in
if installed != null && installed > targetMajor then
  throw "nextcloud: installed major ${toString installed} is newer than this release's ${toString targetMajor}; Nextcloud cannot go back a major"
else if !(available step) then
  throw "nextcloud: installed major ${toString installed} needs nextcloud${toString step} next, which this nixpkgs does not carry; reinstall (install-module.sh nextcloud --reinstall) or restore from a backup"
else {
  inherit installed targetMajor;
  major = step;
  # the release's own apps and pins apply only on the target major
  onTarget = step == targetMajor;
}
