# nc-major.nix — the Nextcloud major this build installs.
#
# Nextcloud refuses to skip a major, so a guest moves at most ONE major per build:
# min(targetMajor, installed + 1). The installed major is read from the guest's own
# config.php at build time — nixos-rebuild evaluates as root, on the guest — so an
# existing site steps 33 -> 34 at one update and 34 -> 35 at the next, keeping its
# data, while a fresh install (no config.php yet) goes straight to targetMajor.
#
# The file is read through a STRING path, never a path literal: a literal would copy
# config.php, which holds the instance's secrets, into the world-readable nix store.
#
# builtins only, so test-nextcloud-major-step.sh can evaluate it without nixpkgs.
{
  targetMajor,
  # major -> bool: does nixpkgs carry nextcloud<major>?
  available,
  configPhp ? "/var/lib/nextcloud/config/config.php",
}:
let
  lines = builtins.filter builtins.isString (builtins.split "\n" (builtins.readFile configPhp));
  versionOf = l: builtins.match "[[:space:]]*'version'[[:space:]]*=>[[:space:]]*'([0-9]+)\\.[0-9.]*',?[[:space:]]*" l;
  found = builtins.filter (m: m != null) (map versionOf lines);
  installed =
    if !(builtins.pathExists configPhp) || found == [ ] then null
    else builtins.fromJSON (builtins.head (builtins.head found));
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
