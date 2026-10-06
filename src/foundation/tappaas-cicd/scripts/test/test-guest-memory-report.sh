#!/usr/bin/env bash
#
# test-guest-memory-report.sh — the sizing rule #663 writes down, against a fake
# Loki: peak + max(25 %, 0.5 GiB), up to 0.5 GiB, never below 1 GiB; a guest that
# showed pressure keeps at least its declared size.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../../../logging/guest-memory-report.sh"

PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); fi; }

[[ -f "${SRC}" ]] || { echo "guest-memory-report.sh not found — cannot run here."; exit 77; }
command -v jq >/dev/null && command -v column >/dev/null || { echo "jq/column missing — cannot run here."; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gmr.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT INT TERM

G=1073741824
# Fake Loki: answers each query by the field it unwraps (or count_over_time).
#   small : 0.3 GiB used of 1 GiB, quiet          → 1 (the floor)
#   mid   : 1.1 GiB used of 8 GiB, quiet          → 2 (1.1 + 0.5 = 1.6 → 2)
#   big   : 3.9 GiB used of 6 GiB, quiet          → 5 (3.9 × 1.25 = 4.9 → 5)
#   tight : 0.6 GiB used of 2 GiB, 12 stalls      → 2 (pressure: keeps its size)
#   oomed : 0.4 GiB used of 1 GiB, an OOM kill    → 1
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/curl" <<FAKE
#!/usr/bin/env bash
q="\$(printf '%s\n' "\$@" | sed -n 's/^query=//p')"
r() { printf '{"metric":{"vm":"%s"},"value":[0,"%s"]},' "\$1" "\$2"; }
case "\$q" in
  *"unwrap maxmem"*)   out="\$(r small $G)\$(r mid \$((8*$G)))\$(r big \$((6*$G)))\$(r tight \$((2*$G)))\$(r oomed $G)" ;;
  *quantile_over_time*|*"unwrap used"*)
                       out="\$(r small 322122547)\$(r mid 1181116006)\$(r big 4187593113)\$(r tight 644245094)\$(r oomed 429496729)" ;;
  *psi_some*)          out="\$(r small 0)\$(r mid 0)\$(r big 0)\$(r tight 0)\$(r oomed 0)" ;;
  *"oom_kills"*)       out="\$(r small 0)\$(r mid 0)\$(r big 0)\$(r tight 0)\$(r oomed 1)" ;;
  *"max_over_time"*"alloc_stalls"*) out="\$(r tight 2584)\$(r small 0)" ;;
  *"min_over_time"*"alloc_stalls"*) out="\$(r tight 2572)\$(r small 0)" ;;
  *count_over_time*)   out="\$(r small 10080)\$(r mid 10080)\$(r big 5040)\$(r tight 10080)\$(r oomed 10080)" ;;
esac
printf '{"data":{"result":[%s]}}' "\${out%,}"
FAKE
chmod +x "${TMP}/bin/curl"

OUT="$(PATH="${TMP}/bin:${PATH}" bash "${SRC}" 7d 2>&1)"
col() { awk -v vm="$1" -v c="$2" '$1 == vm {print $c}' <<< "${OUT}"; }
ck "a quiet small guest gets the 1 GiB floor" "1" "$(col small 6)"
ck "a quiet mid guest: peak + 0.5 GiB, up to 0.5" "2" "$(col mid 6)"
ck "a quiet big guest: peak + 25 %, up to 0.5" "5" "$(col big 6)"
ck "stalls in the window keep the declared size" "2" "$(col tight 6)"
ck "…and are counted as the rise, not the total" "12" "$(col tight 8)"
ck "an OOM kill keeps the declared size" "1" "$(col oomed 6)"
ck "cover: a guest sampled half the window" "50%" "$(col big 10)"
ck "a bad window is refused" "2" "$(PATH="${TMP}/bin:${PATH}" bash "${SRC}" 7w >/dev/null 2>&1; echo $?)"

echo
echo "── ${PASS} passed, ${FAIL} failed ──"
[[ "${FAIL}" -eq 0 ]]
