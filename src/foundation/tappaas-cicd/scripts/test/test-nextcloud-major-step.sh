#!/usr/bin/env bash
#
# test-nextcloud-major-step.sh — a Nextcloud guest moves at most one major per build.
#
# Nextcloud refuses to skip a major, and the module's release is 35 while existing
# sites run 33. src/apps/nextcloud/nc-major.nix reads the installed major from the
# guest's config.php and builds min(target, installed + 1), so a site steps 33 -> 34
# -> 35 over two updates and keeps its data; a fresh install goes straight to the
# target. Evaluated here with nix-instantiate against fixture config.php files.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NCM="$(readlink -f "${HERE}/../../../../apps/nextcloud/nc-major.nix")"

PASS=0; FAIL=0
ck()   { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }
ckin() { if [[ "$3" == *"$2"* ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (missing '$2' in: $3)"; FAIL=$((FAIL+1)); fi; }

[[ -f "${NCM}" ]] || { echo "nc-major.nix not found — cannot run here."; exit 77; }
command -v nix-instantiate >/dev/null 2>&1 || { echo "nix-instantiate not available — skipped."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nc-major.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

# A config.php as Nextcloud writes it, with neighbours that must not be mistaken
# for the version.
cfg() {
    cat > "${TMP}/config.php" <<EOF
<?php
\$CONFIG = array (
  'instanceid' => 'oc1234',
  'versionstring' => 'ignored',
  'version' => '$1',
  'installed' => true,
  'maintenance_window_start' => 1,
);
EOF
}

# step <available majors, e.g. "33 34 35"> [config.php path] — "major/onTarget", or the error.
step() {
    local avail="$1" path="${2:-${TMP}/config.php}"
    nix-instantiate --eval --strict --json -E "
      let r = import ${NCM} {
        targetMajor = 35;
        available = m: builtins.elem m [ ${avail} ];
        configPhp = \"${path}\";
      }; in \"\${toString r.major}/\${if r.onTarget then \"target\" else \"step\"}\"" 2>&1 | tr -d '"'
}

echo "── an existing site steps one major per build ──"
cfg 33.0.9.1;  ck "33 -> 34 (a step, not the target)" "34/step"   "$(step '33 34 35')"
cfg 34.0.4.1;  ck "34 -> 35 (the target)"             "35/target" "$(step '33 34 35')"
cfg 35.0.0.12; ck "35 stays 35"                       "35/target" "$(step '33 34 35')"
cfg 32.0.11.2; ck "32 -> 33, never straight to 35"    "33/step"   "$(step '32 33 34 35')"

echo "── a fresh install goes straight to the target ──"
ck "no config.php: 35" "35/target" "$(step '33 34 35' "${TMP}/nope.php")"
printf '<?php\n$CONFIG = array (\n);\n' > "${TMP}/config.php"
ck "config.php without a version (setup not run yet): 35" "35/target" "$(step '33 34 35')"

echo "── what cannot be done says so, before anything is built ──"
cfg 31.0.9.1
ckin "a step nixpkgs lacks: refused, naming the way out" "reinstall (install-module.sh nextcloud --reinstall)" "$(step '33 34 35')"
cfg 36.0.0.1
ckin "a newer installed major: refused (no downgrade)" "cannot go back a major" "$(step '33 34 35')"

echo "── the store copy of config.php never happens ──"
ck "nc-major.nix reads config.php through a string, not a path literal" "0" \
   "$(grep -cE '^[^#]*[^"/]/var/lib/nextcloud' "${NCM}")"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
