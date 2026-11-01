#!/usr/bin/env bash
#
# test-simulate-coverage.sh — tree test: TAPPAAS_SIMULATE=1 keeps holding as the
# code grows. Fails when a direct mutator or a raw config write appears outside
# the guarded paths (docs/plans/console-gui-pipeline.md §6 layer B):
#
#   TS      a raw spawn or fs write; use spawnGuarded (lib/ts exec.ts) and the
#           *Guarded functions or writeJsonAtomic (lib/ts config-io.ts)
#   bash    a redirect into config/; use tappaas_config_write. mv, cp, rm and the
#           other file tools are gated by lib/simulate-gate.sh. A `#!/bin/sh`
#           script calling a listed command: BASH_ENV does not reach it
#   python  a controller package without the httpx gate (simulate.py)
#   list    an entry of lib/simulate-mutators.txt without its reason
#
# An exception goes in ALLOW below with a reason; an entry nothing matches fails
# too, so the list stays true. `--self-test` plants one offence of each kind.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"
FOUNDATION="$(cd "${CICD}/.." && pwd)"

# <path under src/foundation>|<fixed text on the line>|<reason>
ALLOW=(
"tappaas-cicd/lib/ts/src/exec.ts|spawnSync(|the gate itself"
"tappaas-cicd/lib/ts/src/exec.ts|openSync(file|streamToFile's log, after the gate"
"tappaas-cicd/lib/ts/src/config-io.ts|Sync(|the guarded writers themselves"
"tappaas-cicd/lib/ts/src/cmdb.ts|spawnSync(\"curl\"|cmdbRequest holds a recording POST itself; queries read"
"tappaas-cicd/lib/ts/src/cmdb.ts|Sync(|the spool: cmdbReport returns before it when simulating"
"tappaas-cicd/controller/cmdb-controller/src/main.ts|Sync(sock|the daemon's socket; it does not run under a verb"
"tappaas-cicd/controller/cmdb-controller/src/rescan.ts|spawn(argv|the daemon starts a scan; it does not run under a verb"
"tappaas-cicd/controller/cmdb-controller/src/sweep.ts|Sync(file|the daemon's sweep log"
"tappaas-cicd/controller/cmdb-controller/src/sweep.ts|spawn(\"systemd-cat\"|the daemon's sweep log"
"tappaas-cicd/manager/health-manager/src/emit.ts|openSync(f, \"wx\")|the lock; withEmitLock returns before it when simulating"
"tappaas-cicd/manager/health-manager/src/security.ts|mkdtempSync(join(tmpdir()|scratch under the temp dir"
"tappaas-cicd/manager/module-manager/src/main.ts|mkdtempSync(join(tmpdir()|scratch under the temp dir"
"tappaas-cicd/manager/module-manager/src/main.ts|copyFileSync(|into that scratch directory"
"tappaas-cicd/manager/network-manager/src/splithorizon.ts|spawnSync(process.execPath|a probe in a child node, it changes nothing"
"tappaas-cicd/manager/site-manager/src/client.ts|spawn(JOURNALCTL()|follows the journal"
"tappaas-cicd/manager/site-manager/src/main.ts|mkdirSync(dir|site-manager test's log directory, not site state"
"tappaas-cicd/manager/site-manager/src/provision.ts|mkdtempSync(\"/tmp/|the askpass scratch"
"tappaas-cicd/manager/site-manager/src/usb.ts|openSync(image, \"r\")|reads the image"
"network/scripts/switch-controller/src/main.ts|Sync(tmp|writeJsonAtomic here, which returns first when simulating; no lib/ts in this build"
"network/scripts/switch-controller/src/main.ts|renameSync(tmp|the same"
"network/scripts/switch-controller/src/main.ts|spawnSync(|a plugin's read is a bash child under BASH_ENV; plugin_apply is held"
"tappaas-cicd/scripts/notify-update-failure.sh|\"\${CONFIG_DIR}/update-tappaas.failures\"|the script exits at its top when simulating"
)

scan() {
    ROOT="$1" python3 -I - "${ALLOW[@]}" <<'PY'
import os, re, sys

root = os.environ["ROOT"]
allow = [a.split("|", 2) for a in sys.argv[1:]]
used = set()
offences = []

def allowed(rel, line):
    hit = False
    for i, (path, text, _) in enumerate(allow):
        if path == rel and text in line:
            used.add(i)
            hit = True
    return hit

TS_RAW = re.compile(
    r"(?<![A-Za-z.])(spawnSync|execSync|execFileSync|spawn|execFile)\(|"
    r"(?:fs\.|(?<![A-Za-z.]))(writeFileSync|renameSync|appendFileSync|unlinkSync|rmSync|copyFileSync|chmodSync|"
    r"symlinkSync|cpSync|rmdirSync|mkdirSync|mkdtempSync|openSync)\(")
BASH_CFG = re.compile(r"(?<![0-9&])>>?\s*\"?(\$\{?(CONFIG_DIR|TAPPAAS_CONFIG)\b|/home/tappaas/config\b)")
LISTED = re.compile(r"(^|[\s;&|(])(qm|pct|pvesh|zfs|zpool|nixos-rebuild|curl)\s")
SKIP = re.compile(r"(^|/)(node_modules|dist|dist-test|test|fixtures|web|migrations)(/|$)|(^|/)test[^/]*\.sh$|\.test\.ts$|\.d\.ts$")
UI = "tappaas-cicd/ui/"  # the console writes its own state; a job runs through jobs.ts

for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x not in ("node_modules", "dist", "dist-test", "result", ".git")]
    for f in files:
        p = os.path.join(d, f)
        rel = os.path.relpath(p, root)
        if SKIP.search(rel) or rel.startswith(UI):
            continue
        ts = f.endswith(".ts")
        sh = f.endswith(".sh") or f in ("ap-manager", "switch-manager", "proxmox-controller", "pbs-controller")
        if not (ts or sh):
            continue
        try:
            lines = open(p, errors="ignore").read().split("\n")
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            s = line.strip()
            if s.startswith(("#", "//", "*", "/*")):
                continue
            if ts and TS_RAW.search(line) and not s.startswith("export function") and not allowed(rel, line):
                offences.append(f"{rel}:{n}: raw call, use lib/ts exec.ts or config-io.ts: {s[:90]}")
            if sh and BASH_CFG.search(line) and not allowed(rel, line):
                offences.append(f"{rel}:{n}: redirect into config/, use tappaas_config_write: {s[:90]}")
        if sh and lines[0].rstrip() in ("#!/bin/sh", "#!/usr/bin/env sh"):
            if any(LISTED.search(l) and not l.strip().startswith("#") for l in lines) and not allowed(rel, ""):
                offences.append(f"{rel}: #!/bin/sh calling a listed command: BASH_ENV does not reach it")

ctl = "tappaas-cicd/controller"
pairs = [f"{ctl}/opnsense-controller/src/opnsense_controller", f"{ctl}/authentik-controller/src/identity_controller"]
texts = []
for pkg in pairs:
    if not os.path.isdir(os.path.join(root, pkg)):
        continue
    try:
        texts.append(open(os.path.join(root, pkg, "simulate.py")).read())
        init = open(os.path.join(root, pkg, "__init__.py")).read()
    except OSError:
        offences.append(f"{pkg}: no simulate.py")
        continue
    if "simulate.install()" not in init:
        offences.append(f"{pkg}/__init__.py: does not install the httpx gate")
if len(set(texts)) > 1:
    offences.append("the two simulate.py differ")

lst = os.path.join(root, "tappaas-cicd/lib/simulate-mutators.txt")
if os.path.exists(lst):
    for n, line in enumerate(open(lst), 1):
        if line.strip() and not line.startswith("#") and not re.search(r"#\s*\S", line):
            offences.append(f"lib/simulate-mutators.txt:{n}: an entry needs its reason")

if not os.environ.get("NO_STALE"):
    for i, a in enumerate(allow):
        if i not in used:
            offences.append(f"ALLOW entry matches nothing: {a[0]} {a[1]}")

print("\n".join(offences))
sys.exit(1 if offences else 0)
PY
}

if [[ "${1:-}" == "--self-test" ]]; then
    d="$(mktemp -d)"
    trap 'rm -rf "${d:?}"' EXIT
    pkg="${d}/tappaas-cicd/controller/opnsense-controller/src/opnsense_controller"
    mkdir -p "${d}/tappaas-cicd/manager/x" "${d}/tappaas-cicd/lib" "${pkg}"
    touch "${pkg}/simulate.py"
    echo 'simulate.install()' > "${pkg}/__init__.py"
    fails=0
    planted() { # <what> <file> <line>
        printf '%s\n' "$3" > "${d}/$2"
        if NO_STALE=1 scan "${d}" >/dev/null; then echo "  FAIL not caught: $1"; fails=$((fails + 1)); else echo "  ok   caught: $1"; fi
        rm -f "${d:?}/${2:?}"
    }
    planted "raw spawnSync"  tappaas-cicd/manager/x/a.ts 'spawnSync("qm", ["stop", "1"], {});'
    planted "raw write"      tappaas-cicd/manager/x/a.ts 'writeFileSync(f, "x");'
    planted "fs.rmSync"      tappaas-cicd/manager/x/a.ts 'fs.rmSync(f);'
    planted "redirect"       tappaas-cicd/manager/x/a.sh 'echo x > "${CONFIG_DIR}/a.json"'
    planted "sh script"      tappaas-cicd/manager/x/a.sh $'#!/bin/sh\nqm stop 1'
    planted "list reason"    tappaas-cicd/lib/simulate-mutators.txt 'qm stop'
    echo 'nothing' > "${pkg}/__init__.py"
    planted "no httpx gate"  tappaas-cicd/manager/x/b.ts ''
    [[ "${fails}" -eq 0 ]]
    exit
fi

if out="$(scan "${FOUNDATION}")"; then
    echo "simulate coverage: clean"
else
    printf '%s\n' "${out}"
    echo "simulate coverage: FAILED"
    exit 1
fi
