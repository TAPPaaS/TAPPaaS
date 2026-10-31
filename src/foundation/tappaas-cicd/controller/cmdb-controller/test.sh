#!/usr/bin/env bash
#
# test.sh — tests for cmdb-controller (ADR-040, implementation plan step 1).
#
# FAST (default, non-disruptive): a throwaway PostgreSQL in a temp directory
# (initdb + pg_ctl, its socket in the temp dir, no TCP), the controller built
# with tsc and started against it on a temp socket, the cmdb CLI against that.
# Never the site's database or socket. Covers:
#   - the schema: exactly the eight tables of D13, both exclusion constraints
#     (and that an overlapping period is refused), the GIN index; a second
#     start applies it again without harm
#   - the metamodel loaded as data: class_ancestor's closure, attribute_def
#   - a report: a server asset with an rj45 port, a machine CI the asset is
#     allocated to, a vm on it
#   - query: every asset (subclasses), every physical object, by attribute
#   - history: a second observation changes an attribute; both periods are
#     kept, and the object as of the first time shows the first value
#   - drift: that observation had no change behind it, so the server is
#     drifted; a change report clears it
#   - refusals: two keys matching two objects (409), an immutable value
#     changed (409), a field a port of that kind does not have (422), a field
#     the class does not have (422); nothing of a refused batch is written
#   - impact over two hops, and not beyond
#   - resolve (D14): host.name, service.instance.id
#   - an ended CI leaves key matching: the same name again is a new CI (D7)
#   - the loopback listener wants the token; the change stream (SSE)
#   - the client: a report the service cannot take is spooled and replayed;
#     lib/cmdb.sh never fails its caller
#   - the example report in README.md is accepted as written
#   - software is known by its name within its node: an upgrade is the same CI
#   - an asset is found by any of its ports' MACs; a MAC on one asset and a
#     serial on another is a conflict
#   - a CI unreported beyond its class's expiry is unseen (never deleted), and
#     operational again when reported; an asset does not expire
#   - rescan runs `<component> report` for the cmdbSource components only
#   - a reference to an object not reported yet makes a placeholder, which its
#     owner's report merges into (also when it was named by an abstract class,
#     and when a stronger key finds another object); an unknown class is refused
#   - recorded on objects and relations; the relations verb; owned-by's pairs
#   - volatile attributes never drift; conditions and their checks; an assessment; --where on a path;
#     a pool's key is its name on its node; a service resolves by name
#   - the discovery sweep over a fixture site: baseline, expected, drift, the
#     differ, unmanaged, missing, the journal lines, exit codes 0/1/2
#   - new, not drift: the ports of an asset a verb made and the fields its first
#     observation fills are new (with the verb); an old asset's port and a later
#     change of a filled field are drift
#
# Needs pg_ctl/initdb/psql, node, tsc, curl and jq; without them on PATH it
# re-enters itself under nix-shell. PostgreSQL will not run as root: as root
# the database part is skipped (run it as tappaas).
#
# DEEP (TAPPAAS_TEST_DEEP=1): nothing more yet — the live service is checked
# on the mothership (cmdb.service, its socket and the dump), see README.md.
#
# Prints "Results: N passed, M failed"; exits 1 on any failure.
#
set -uo pipefail
for _a in "$@"; do [[ "${_a}" == "--deep" ]] && export TAPPAAS_TEST_DEEP=1; done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/../.." && pwd)"

_missing=""
for _t in initdb pg_ctl psql createdb node tsc curl jq; do command -v "${_t}" >/dev/null 2>&1 || _missing+=" ${_t}"; done
if [[ -n "${_missing}" && -z "${CMDB_TEST_IN_NIX:-}" ]] && command -v nix-shell >/dev/null 2>&1; then
    exec env CMDB_TEST_IN_NIX=1 nix-shell -p postgresql_16 nodejs_22 typescript curl jq --run "bash '${HERE}/test.sh' $*"
fi

PASS=0
FAIL=0
ok()  { echo "  ok: $*";   PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }
results() { echo ""; echo "Results: ${PASS} passed, ${FAIL} failed"; [[ "${FAIL}" -eq 0 ]]; }

if [[ -n "${_missing}" ]]; then
    echo "  skip: no${_missing} here, and no nix-shell to bring them"
    results; exit $?
fi

T="$(mktemp -d /tmp/cmdb-test.XXXXXX)"
DIST="${HERE}/dist-test"
SVC_PID=""
cleanup() {
    [[ -n "${SVC_PID}" ]] && kill "${SVC_PID}" 2>/dev/null && wait "${SVC_PID}" 2>/dev/null
    [[ -d "${T}/pg" ]] && pg_ctl -D "${T}/pg" -m immediate stop >/dev/null 2>&1
    rm -rf -- "${T}" "${DIST}"
    return 0
}
trap cleanup EXIT INT TERM

echo "== cmdb-controller TypeScript build =="
rm -rf -- "${DIST}"
if tsc -p "${HERE}/tsconfig.json" --outDir "${DIST}" >"${T}/tsc.log" 2>&1; then
    ok "tsc build clean (src and lib/ts)"
else
    bad "tsc build failed: $(head -5 "${T}/tsc.log")"
    results; exit $?
fi
MAIN="${DIST}/controller/cmdb-controller/src/main.js"
CLI="${DIST}/controller/cmdb-controller/src/cli.js"

echo "== the metamodel loader: a relation's tree end =="
mkdir -p "${T}/mm"
cp "${HERE}"/metamodel/*.json "${T}/mm/"
jq '.relations["runs-on"].tree = "sideways"' "${HERE}/metamodel/relations.json" >"${T}/mm/relations.json"
# node exits 1 when the load throws, which under pipefail would fail the pipe
# before grep is heard: capture, then look.
_tree_out="$(node -e "require('${DIST}/controller/cmdb-controller/src/metamodel.js').Metamodel.fromDir('${T}/mm')" 2>&1 || true)"
if grep -q "relation runs-on: tree sideways" <<<"${_tree_out}"; then
    ok "a tree end that is none of from, to, both stops the load"
else
    bad "a wrong tree end was loaded"
fi

if [[ "$(id -u)" -eq 0 ]]; then
    echo "  skip: PostgreSQL does not run as root; run this as tappaas"
    results; exit $?
fi

echo "== a throwaway PostgreSQL =="
PGPORT_T=$(( 20000 + RANDOM % 20000 ))
export PGHOST="${T}" PGPORT="${PGPORT_T}" PGUSER=tappaas PGDATABASE=cmdb
if initdb -D "${T}/pg" -U tappaas --auth=trust -E UTF8 --no-locale >"${T}/initdb.log" 2>&1 \
    && pg_ctl -D "${T}/pg" -o "-k ${T} -c listen_addresses='' -p ${PGPORT_T}" -w -l "${T}/pg.log" start >/dev/null 2>&1 \
    && createdb cmdb; then
    ok "PostgreSQL $(postgres --version | awk '{print $NF}') in ${T}"
else
    bad "could not start PostgreSQL: $(tail -3 "${T}/initdb.log" "${T}/pg.log" 2>/dev/null)"
    results; exit $?
fi
sql() { psql -qtAX -c "$1" 2>&1; }

export CMDB_PGHOST="${T}" CMDB_PGPORT="${PGPORT_T}" CMDB_PGDATABASE=cmdb CMDB_PGUSER=tappaas
export CMDB_SHARE="${HERE}" CMDB_SOCKET="${T}/cmdb.sock" CMDB_TOKEN_FILE="${T}/token"
export TAPPAAS_CONFIG="${T}/config"
API_PORT=$(( 40000 + RANDOM % 20000 ))
export CMDB_LISTEN="127.0.0.1:${API_PORT}"
echo "test-token-$$" >"${CMDB_TOKEN_FILE}"
mkdir -p "${TAPPAAS_CONFIG}"

# The rescan sources (components.json's cmdbSource): one that reports, one that
# fails, one that is not a source. They report through the CLI, to this service.
mkdir -p "${T}/bin"
cat >"${T}/components.json" <<'JSON'
{ "version": 1, "components": [
  { "name": "fake-manager", "kind": "manager", "cmdbSource": true },
  { "name": "quiet-manager", "kind": "manager" },
  { "name": "broken-manager", "kind": "manager", "cmdbSource": true } ] }
JSON
printf '#!/usr/bin/env bash\n[[ "$1" == report ]] || exit 2\necho %q | node %q report --json >/dev/null\n' \
    '{"source":"fake-manager","objects":[{"class":"zone","name":"rescanned","attributes":{"vlan":99}}]}' "${CLI}" >"${T}/bin/fake-manager"
printf '#!/usr/bin/env bash\necho "boom: the plane is down" >&2\nexit 3\n' >"${T}/bin/broken-manager"
printf '#!/usr/bin/env bash\ntouch %q\n' "${T}/quiet-ran" >"${T}/bin/quiet-manager"
chmod +x "${T}/bin/"*
export CMDB_COMPONENTS="${T}/components.json" CMDB_SOURCE_PATH="${T}/bin:${PATH}"

node "${MAIN}" serve >"${T}/svc.log" 2>&1 &
SVC_PID=$!
for _ in $(seq 1 100); do [[ -S "${CMDB_SOCKET}" ]] && break; sleep 0.1; done
if [[ -S "${CMDB_SOCKET}" ]]; then ok "cmdb-controller serves ${CMDB_SOCKET}"; else bad "the service did not start: $(cat "${T}/svc.log")"; results; exit $?; fi

cmdb() { node "${CLI}" "$@"; }

# Report times relative to now, on the hour: a CI expires after 7 days (D5), so
# a fixed date would be unseen the moment it is reported.
ago() { node -e 'const d = new Date(Date.now() - Number(process.argv[1]) * 3600e3); d.setUTCMinutes(0, 0, 0); console.log(d.toISOString())' "$1"; }
T1="$(ago 96)"; T1b="$(ago 94)"; T2="$(ago 72)"; T3="$(ago 48)"; T4="$(ago 24)"; OLD="$(ago 240)"

echo "== the schema (D13) =="
check "exactly the eight tables" "attribute,attribute_def,change,class,class_ancestor,object,relation,relation_type" \
    "$(sql "SELECT string_agg(table_name, ',' ORDER BY table_name) FROM information_schema.tables WHERE table_schema = 'public'")"
check "the exclusion constraints on attribute and relation" "attribute_no_overlap,relation_no_overlap" \
    "$(sql "SELECT string_agg(conname, ',' ORDER BY conname) FROM pg_constraint WHERE contype = 'x'")"
check "a GIN index on attribute.value" "1" "$(sql "SELECT count(*) FROM pg_indexes WHERE tablename = 'attribute' AND indexdef ILIKE '%USING gin (value%'")"
check "the store records its schema version" "cmdb schema 5" "$(sql "SELECT obj_description('object'::regclass, 'pg_class')")"
if node "${MAIN}" schema >"${T}/schema2.log" 2>&1; then ok "applying the schema again is harmless (idempotent)"; else bad "second schema apply failed: $(cat "${T}/schema2.log")"; fi

echo "== the metamodel, as data (D3, D13) =="
check "class_ancestor: a server is a server, an asset, a resource, an object" "asset:1,object:3,resource:2,server:0" \
    "$(sql "SELECT string_agg(ancestor || ':' || depth, ',' ORDER BY ancestor) FROM class_ancestor WHERE class = 'server'")"
check "attribute_def: a port's kind is required, one of the D9 connectors" "string|true|[\"rj45\", \"sfp\", \"wifi\", \"usb-a\", \"usb-c\"]" \
    "$(sql "SELECT type || '|' || required || '|' || (spec->'enum')::text FROM attribute_def WHERE class = 'port' AND name = 'kind'")"
check "faulty is a flag on resource" "boolean" "$(sql "SELECT type FROM attribute_def WHERE class = 'resource' AND name = 'faulty'")"
check "a physical class: asset's subclasses inherit it" "t" "$(sql "SELECT physical FROM class WHERE name = 'server'")"
check "cmdb class show: an asset's keys" "serial,vendor|name" "$(cmdb class show server --json | jq -r '[.keys[].components | join(",")] | join("|")')"
cmdb class list >"${T}/classes.txt" 2>&1 && grep -q "^      server" "${T}/classes.txt" && ok "cmdb class list draws the tree" || bad "class list: $(head -5 "${T}/classes.txt")"

echo "== a report: a server, its rj45 port, a machine on it, a vm on that =="
cat >"${T}/r1.json" <<JSON
{ "source": "site-manager", "kind": "observation", "time": "${T1}",
  "objects": [
    { "ref": "srv", "class": "server", "name": "srv-01",
      "attributes": { "vendor": "hp", "serial": "CZC1234", "model": "hp/z840", "displayName": "tappaas1",
                      "cpu": "E5-2680v4", "memory": 131072, "stage": "operational" } },
    { "class": "port", "name": "eno1",
      "attributes": { "asset": { "ref": "srv" }, "kind": "rj45", "speed": "1g", "mac": "aa:bb:cc:00:00:01", "role": "lan" } },
    { "ref": "m", "class": "machine", "name": "tappaas1",
      "attributes": { "hostname": "tappaas1", "clusterMember": true, "asset": { "ref": "srv" } } },
    { "class": "vm", "name": "nextcloud", "attributes": { "vmid": 200, "cores": 4, "memory": 8192, "onNode": { "ref": "m" } } }
  ] }
JSON
out="$(cmdb report --json <"${T}/r1.json")"
check "delivered, four objects created" "true 4" "$(jq -r '"\(.delivered) \([.result.objects[] | select(.created)] | length)"' <<<"${out}")"
SRV_ID="$(jq -r '.result.objects[0].id' <<<"${out}")"
check "the asset is allocated to the machine (allocated-to)" "machine/tappaas1" \
    "$(cmdb show srv-01 --json | jq -r '.relations[] | select(.type == "allocated-to") | "\(.other.class)/\(.other.name)"')"
out="$(cmdb report --json <"${T}/r1.json")"
check "the same report again changes nothing" "null 0" "$(jq -r '"\(.result.change) \([.result.objects[] | select(.created)] | length)"' <<<"${out}")"

echo "== query =="
check "every asset: the server (a subclass)" "server/srv-01" "$(cmdb query asset --json | jq -r '[.[] | "\(.class)/\(.name)"] | join(",")')"
check "every physical object: the server and its port" "port/eno1,server/srv-01" "$(cmdb query --physical --json | jq -r '[.[] | "\(.class)/\(.name)"] | join(",")')"
check "every node: the machine and the vm" "machine/tappaas1,vm/nextcloud" "$(cmdb query node --json | jq -r '[.[] | "\(.class)/\(.name)"] | join(",")')"
check "by attribute: vendor=hp" "srv-01" "$(cmdb query --where vendor=hp --json | jq -r '[.[].name] | join(",")')"
check "by attribute: a number" "nextcloud" "$(cmdb query vm --where vmid=200 --json | jq -r '[.[].name] | join(",")')"

echo "== history and drift (D6) =="
cat >"${T}/r2.json" <<JSON
{ "source": "health-manager", "time": "${T2}",
  "objects": [ { "class": "server", "name": "srv-01", "attributes": { "cpu": "E5-2690v4" } } ] }
JSON
out="$(cmdb report --json <"${T}/r2.json")"
check "the second observation changed cpu and marked drift" "cpu cpu" "$(jq -r '.result.objects[0] | "\(.changed | join(",")) \(.drift | join(","))"' <<<"${out}")"
check "history keeps both periods of cpu" "E5-2680v4 ${T1} ${T2}|E5-2690v4 ${T2} null" \
    "$(cmdb history srv-01 --json | jq -r '[.attributes[] | select(.name == "cpu") | "\(.value) \(.from) \(.to)"] | join("|")')"
check "the server as of the first report had the first cpu" "E5-2680v4" "$(cmdb history srv-01 --at "${T1b}" --json | jq -r '.attributes.cpu.value')"
check "a query as of then sees the first cpu" "E5-2680v4" "$(cmdb query server --at "${T1b}" --json | jq -r '.[0].attributes.cpu')"
check "drift on the server: what cpu was, from whom" "E5-2680v4 health-manager" "$(cmdb show srv-01 --json | jq -r '"\(.drift.attributes.cpu.was) \(.drift.source)"')"
cmdb history srv-01 >"${T}/hist.txt" 2>&1 && grep -q "E5-2690v4" "${T}/hist.txt" && ok "cmdb history prints a table" || bad "history text: $(head -3 "${T}/hist.txt")"
cat >"${T}/r3.json" <<JSON
{ "source": "asset-manager", "kind": "change", "verb": "asset modify", "job": "J-1", "actor": "lars", "time": "${T3}",
  "objects": [ { "class": "server", "name": "srv-01", "attributes": { "assetTag": "T-0001" } },
               { "class": "server", "name": "srv-02", "attributes": { "vendor": "dell", "serial": "X2" } } ] }
JSON
cmdb report --json <"${T}/r3.json" >/dev/null
check "a change clears the drift" "null" "$(cmdb show srv-01 --json | jq -r '.drift')"
check "the change is recorded with its job and verb" "change J-1 asset modify" \
    "$(sql "SELECT kind || ' ' || job || ' ' || verb FROM change WHERE job = 'J-1'")"

echo "== refusals: conflicts and the metamodel =="
before="$(sql "SELECT (SELECT count(*) FROM object) || '/' || (SELECT count(*) FROM attribute)")"
refuse() { # <what> <expected rc> <expected text> <report json>
    local o rc
    o="$(cmdb report --json <<<"$4" 2>&1)"; rc=$?
    if [[ "${rc}" == "$2" ]] && grep -q -- "$3" <<<"${o}"; then ok "$1"; else bad "$1 — rc ${rc}: ${o}"; fi
}
refuse "two keys matching two objects is a conflict (409)" 4 "conflict" \
    '{"source":"t","objects":[{"class":"server","name":"srv-02","attributes":{"vendor":"hp","serial":"CZC1234"}}]}'
refuse "an immutable value changed is a conflict" 4 "immutable" \
    '{"source":"t","objects":[{"class":"server","name":"srv-01","attributes":{"vendor":"hp","serial":"OTHER"}}]}'
refuse "speed is no field of a wifi port (422)" 4 "speed does not apply" \
    '{"source":"t","objects":[{"class":"port","name":"wlan0","attributes":{"asset":"srv-01","kind":"wifi","speed":"1g"}}]}'
refuse "an sfp port's speed is an sfp speed" 4 "one of 1g, 10g, 25g" \
    '{"source":"t","objects":[{"class":"port","name":"sfp0","attributes":{"asset":"srv-01","kind":"sfp","speed":"2.5g"}}]}'
refuse "a field the class does not have" 4 "has no field" \
    '{"source":"t","objects":[{"class":"server","name":"srv-01","attributes":{"colour":"red"}}]}'
refuse "an abstract class cannot be reported" 4 "abstract" \
    '{"source":"t","objects":[{"class":"asset","name":"x"}]}'
refuse "the whole batch is refused: the good object is not written either" 4 "no class" \
    '{"source":"t","objects":[{"class":"zone","name":"lan","attributes":{"vlan":10}},{"class":"nope","name":"x"}]}'
check "nothing of the refused batches was written" "${before}" "$(sql "SELECT (SELECT count(*) FROM object) || '/' || (SELECT count(*) FROM attribute)")"

echo "== impact (recursive over relation) =="
check "two hops from the server: its port and machine, then the vm" "1:machine/tappaas1,1:port/eno1,2:vm/nextcloud" \
    "$(cmdb impact srv-01 --hops 2 --json | jq -r '[.impact[] | "\(.depth):\(.class)/\(.name)"] | sort | join(",")')"
check "one hop does not reach the vm" "0" "$(cmdb impact srv-01 --hops 1 --json | jq '[.impact[] | select(.name == "nextcloud")] | length')"
check "from the vm, in only: nothing depends on it" "0" "$(cmdb impact vm/nextcloud --direction in --json | jq '.impact | length')"

echo "== resolve (D14) =="
check "host.name=nextcloud is the vm" "vm nextcloud" "$(cmdb resolve host.name=nextcloud --json | jq -r '"\(.class) \(.name)"')"
check "service.instance.id is the CI id" "srv-01" "$(cmdb resolve "service.instance.id=${SRV_ID}" --json | jq -r '.name')"

echo "== an ended CI is kept, and leaves key matching (D5, D7) =="
OLD_VM="$(cmdb show vm/nextcloud --json | jq -r '.id')"
cmdb report --json >/dev/null <<JSON
{ "source": "module-manager", "kind": "change", "verb": "module delete", "time": "${T4}",
  "objects": [ { "class": "vm", "name": "nextcloud", "attributes": { "vmid": 200 }, "end": true } ] }
JSON
check "a query no longer lists it" "0" "$(cmdb query vm --json | jq 'length')"
check "…with --all it is there, retired" "retired" "$(cmdb query vm --all --json | jq -r '.[0].attributes.stage')"
check "its runs-on ended with it" "0" "$(cmdb show vm/nextcloud --json | jq '.relations | length')"
NEW_VM="$(cmdb report --json <<<'{"source":"module-manager","kind":"change","objects":[{"class":"vm","name":"nextcloud","attributes":{"vmid":200,"onNode":"tappaas1"}}]}' | jq -r '.result.objects[0].id')"
[[ -n "${NEW_VM}" && "${NEW_VM}" != "null" && "${NEW_VM}" != "${OLD_VM}" ]] && ok "the same name again is a new CI" || bad "nextcloud again: ${NEW_VM} (old ${OLD_VM})"

echo "== the listeners =="
check "loopback without the token: 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' "http://${CMDB_LISTEN}/v1/health")"
check "loopback with the token: 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "${CMDB_TOKEN_FILE}")" "http://${CMDB_LISTEN}/v1/health")"
check "the socket is not world-accessible" "660" "$(stat -c '%a' "${CMDB_SOCKET}" 2>/dev/null || stat -f '%Lp' "${CMDB_SOCKET}")"
curl -sN --max-time 3 --unix-socket "${CMDB_SOCKET}" http://cmdb/v1/stream >"${T}/sse.txt" 2>/dev/null &
_sse=$!
sleep 0.5
cmdb report --json >/dev/null <<<'{"source":"network-manager","objects":[{"class":"zone","name":"lan","attributes":{"vlan":10}}]}'
wait "${_sse}" 2>/dev/null
grep -q '^event: change' "${T}/sse.txt" && grep -q '"source":"network-manager"' "${T}/sse.txt" \
    && ok "the change stream sends the change (SSE)" || bad "no change on the stream: $(cat "${T}/sse.txt")"

echo "== the client: spool and replay; lib/cmdb.sh =="
out="$(CMDB_SOCKET="${T}/down.sock" cmdb report --json <<<'{"source":"switch-manager","objects":[{"class":"zone","name":"iot","attributes":{"vlan":20}}]}')"
check "the service down: the report is spooled, not lost" "false 1" "$(jq -r '.delivered' <<<"${out}") $(ls "${TAPPAAS_CONFIG}/.cmdb-spool/"*.json 2>/dev/null | wc -l | tr -d ' ')"
cmdb report --json >/dev/null <<<'{"source":"switch-manager","objects":[{"class":"zone","name":"dmz","attributes":{"vlan":30}}]}'
check "the next report replays the spool first" "0 iot" "$(ls "${TAPPAAS_CONFIG}/.cmdb-spool/"*.json 2>/dev/null | wc -l | tr -d ' ') $(cmdb show zone/iot --json | jq -r '.name')"
printf '#!/usr/bin/env bash\nexec node %q "$@"\n' "${CLI}" >"${T}/cmdb-bin"; chmod +x "${T}/cmdb-bin"
_lib_out="$(CMDB_BIN="${T}/cmdb-bin" bash -c '. "'"${CICD}"'/lib/cmdb.sh"
    cmdb_available || echo unavailable
    echo "{\"source\":\"t\",\"objects\":[{\"class\":\"nope\",\"name\":\"x\"}]}" | cmdb_report; echo "rc=$?"
    cmdb_query asset | jq -r "length"' 2>"${T}/lib.err")"
check "cmdb.sh: a refused report does not fail the caller; query answers" "rc=0 2" "$(tr '\n' ' ' <<<"${_lib_out}" | sed 's/ $//')"
grep -q "report not recorded" "${T}/lib.err" && ok "cmdb.sh: …and warns" || bad "cmdb.sh did not warn: $(cat "${T}/lib.err")"

echo "== the README's example =="
awk '/^```json$/{f=1;next} /^```$/{if(f)exit} f' "${HERE}/README.md" >"${T}/readme.json"
out="$(cmdb report --json <"${T}/readme.json" 2>&1)"
check "the README's example report is accepted" "true" "$(jq -r '.delivered' <<<"${out}" 2>/dev/null || echo "${out}")"
check "…and its cluster has the machine as a member" "machine/tappaas1" \
    "$(cmdb show cluster/tappaas --json | jq -r '.relations[] | select(.type == "member-of") | "\(.other.class)/\(.other.name)"')"

cmdb report --json >/dev/null <<<'{"source":"t","objects":[{"class":"machine","name":"tappaas1","attributes":{"environment":{"class":"environment","name":"mgmt"}}}]}'
check "a node's environment leaves its cluster alone" "cluster/tappaas environment/mgmt" \
    "$(cmdb show machine/tappaas1 --json | jq -r '[.relations[] | select(.type == "member-of") | "\(.other.class)/\(.other.name)"] | sort | join(" ")')"

echo "== software: known by its name within its node; version is history (D5) =="
cmdb report --json >/dev/null <<<'{"source":"module-manager","objects":[{"class":"app","name":"pve","attributes":{"version":"9.0","onNode":"tappaas1"}}]}'
PVE="$(cmdb show app/pve --json | jq -r '.id')"
out="$(cmdb report --json <<<'{"source":"module-manager","kind":"change","verb":"module update","objects":[{"class":"app","name":"pve","attributes":{"version":"9.1","onNode":"tappaas1"}}]}')"
check "an upgrade is the same CI, its version changed" "${PVE} false version" "$(jq -r '.result.objects[0] | "\(.id) \(.created) \(.changed | join(","))"' <<<"${out}")"
check "…and the version's history is the upgrades" "9.0|9.1" "$(cmdb history app/pve --json | jq -r '[.attributes[] | select(.name == "version") | .value] | join("|")')"
check "cmdb class show: software's key is (name, onNode)" "name,onNode" "$(cmdb class show app --json | jq -r '[.keys[].components | join(",")] | join("|")')"

echo "== an asset by any of its ports' MACs (D5) =="
out="$(cmdb report --json <<<'{"source":"installer","objects":[{"ref":"box","class":"server","name":"new-box","attributes":{"model":"hp/z840"}},{"class":"port","name":"eno1","attributes":{"asset":{"ref":"box"},"kind":"rj45","mac":"AA:BB:CC:00:00:01"}}]}')"
check "a box reported under another name, by a port's MAC, is srv-01" "srv-01 new-box false" "$(jq -r '.result.objects[0] | "\(.name) \(.reportedAs) \(.created)"' <<<"${out}")"
check "…and its port is that asset's eno1, not a new one" "false" "$(jq -r '.result.objects[1].created' <<<"${out}")"
check "…no second server was made" "srv-01,srv-02" "$(cmdb query server --json | jq -r '[.[].name] | join(",")')"
refuse "a serial on one asset and a MAC on another is a conflict" 4 "conflict" \
    '{"source":"t","objects":[{"ref":"b","class":"server","name":"srv-02","attributes":{"vendor":"dell","serial":"X2"}},{"class":"port","name":"eno9","attributes":{"asset":{"ref":"b"},"kind":"rj45","mac":"aa:bb:cc:00:00:01"}}]}'
check "cmdb class show: an asset's keys and its keyVia" "serial,vendor|name port.mac" \
    "$(cmdb class show server --json | jq -r '"\([.keys[].components | join(",")] | join("|")) \(.keyVia[0].class).\(.keyVia[0].field)"')"

echo "== unseen: a CI no source reported within its class's expiry (D5) =="
cmdb report --json >/dev/null <<JSON
{ "source": "site-manager", "time": "${OLD}", "objects": [
  { "class": "vm", "name": "old-vm", "attributes": { "vmid": 300, "stage": "operational" } },
  { "class": "other-device", "name": "old-box", "attributes": { "stage": "placed" } } ] }
JSON
check "a vm last reported 10 days ago is unseen" "unseen" "$(cmdb show vm/old-vm --json | jq -r '.attributes.stage.value')"
check "…since its 7 days ran out, by cmdb-controller" "$(ago 72) cmdb-controller" "$(cmdb show vm/old-vm --json | jq -r '"\(.attributes.stage.since) \(.attributes.stage.source)"')"
check "…and it is kept, not deleted" "1" "$(cmdb query vm --where vmid=300 --json | jq 'length')"
check "an asset does not expire: only CIs do" "placed" "$(cmdb show other-device/old-box --json | jq -r '.attributes.stage.value')"
check "cmdb class show: a vm's expiry is the ci default, 7 days" "604800" "$(cmdb class show vm --json | jq -r '.expirySeconds')"
cmdb report --json >/dev/null <<<'{"source":"site-manager","objects":[{"class":"vm","name":"old-vm","attributes":{"vmid":300}}]}'
check "reported again, it is operational" "operational" "$(cmdb show vm/old-vm --json | jq -r '.attributes.stage.value')"
check "…its stage history: operational, unseen, operational" "operational|unseen|operational" \
    "$(cmdb history vm/old-vm --json | jq -r '[.attributes[] | select(.name == "stage") | .value] | join("|")')"

echo "== rescan asks every cmdbSource component (components.json) =="
out="$(cmdb rescan --json)"
check "the two sources were asked, the other component not" "fake-manager:true broken-manager:false" \
    "$(jq -r '[.asked[] | "\(.source):\(.ok)"] | join(" ")' <<<"${out}")"
[[ ! -e "${T}/quiet-ran" ]] && ok "…quiet-manager (no cmdbSource) was not run" || bad "quiet-manager ran"
check "what the source reported is in the store" "99" "$(cmdb show zone/rescanned --json | jq -r '.attributes.vlan.value')"
check "a failed source says why" "boom: the plane is down" "$(jq -r '.asked[] | select(.source == "broken-manager") | .stderr' <<<"${out}")"

echo "== placeholders: a reference to what is not reported yet =="
out="$(cmdb report --json <<<'{"source":"module-manager","objects":[{"class":"vm","name":"ph-vm","attributes":{"vmid":400,"onNode":{"class":"machine","name":"ph-node"}}}]}')"
check "the batch is accepted, the placeholder listed" "machine/ph-node" "$(jq -r '[.result.placeholders[] | "\(.class)/\(.name)"] | join(",")' <<<"${out}")"
PH="$(jq -r '.result.placeholders[0].id' <<<"${out}")"
check "a name and nothing else: placeholder, its source, no stage" "true module-manager null" \
    "$(cmdb show machine/ph-node --json | jq -r '"\(.attributes.placeholder.value) \(.attributes.placeholder.source) \(.attributes.stage.value)"')"
out="$(cmdb report --json <<<'{"source":"site-manager","objects":[{"class":"machine","name":"ph-node","attributes":{"hostname":"ph-node","stage":"operational"}}]}')"
check "its owner's report merges into it" "${PH} false true" "$(jq -r '.result.objects[0] | "\(.id) \(.created) \(.adopted)"' <<<"${out}")"
check "…the mark is gone, the relation kept" "null vm/ph-vm" "$(cmdb show machine/ph-node --json | jq -r '"\(.attributes.placeholder.value) \(.relations[0].other.class)/\(.relations[0].other.name)"')"
out="$(cmdb report --json <<<'{"source":"asset-manager","objects":[{"ref":"a","class":"other-device","name":"ph-box"}],"relations":[{"type":"allocated-to","from":{"ref":"a"},"to":{"class":"node","name":"ph-role"}}]}')"
PH="$(jq -r '.result.placeholders[0].id' <<<"${out}")"
out="$(cmdb report --json <<<'{"source":"module-manager","objects":[{"class":"vm","name":"ph-role","attributes":{"vmid":401}}]}')"
check "named by an abstract class: the owner says what it is" "${PH} vm" "$(jq -r '.result.objects[0] | "\(.id) \(.class)"' <<<"${out}")"
cmdb report --json >/dev/null <<<'{"source":"switch-manager","objects":[{"class":"port","name":"ph0","attributes":{"asset":{"class":"server","name":"tag-x"},"kind":"rj45"}}]}'
out="$(cmdb report --json <<<'{"source":"asset-manager","objects":[{"class":"server","name":"tag-x","attributes":{"vendor":"hp","serial":"CZC1234"}}]}')"
check "a stronger key finds the real asset: it keeps its name" "srv-01 tag-x" "$(jq -r '.result.objects[0] | "\(.name) \(.reportedAs)"' <<<"${out}")"
check "…the placeholder's port moved to it" "server/srv-01" "$(cmdb show ph0 --json | jq -r '.relations[] | select(.type == "part-of") | "\(.other.class)/\(.other.name)"')"
check "…and the placeholder has ended" "0" "$(cmdb query server --where name=tag-x --json | jq 'length')"
cmdb report --json >/dev/null <<JSON
{ "source": "backup-manager", "time": "${OLD}", "objects": [ { "class": "backup-peer", "name": "ph-peer", "attributes": { "location": { "class": "location", "name": "ph-loc" } } } ],
  "relations": [ { "type": "backs-up", "from": { "class": "datastore", "name": "ph-ds" }, "to": { "class": "vm", "name": "ph-old" } } ] }
JSON
check "a placeholder has not been seen, so it does not expire" "null" "$(cmdb show vm/ph-old --json | jq -r '.attributes.stage.value')"
refuse "a reference to a class that does not exist is refused" 4 "no class nope" \
    '{"source":"t","objects":[{"class":"zone","name":"z9"}],"relations":[{"type":"serves","from":{"class":"nope","name":"x"},"to":{"class":"environment","name":"e"}}]}'

echo "== recorded facts (D7) =="
cmdb report --json >/dev/null <<'JSON'
{ "source": "asset-manager", "objects": [
    { "ref": "l", "class": "location", "name": "home", "recorded": true },
    { "ref": "r", "class": "room", "name": "attic", "recorded": true, "attributes": { "location": { "ref": "l" } } },
    { "ref": "p", "class": "passive-device", "name": "pp-01", "recorded": true } ],
  "relations": [ { "type": "placed-in", "from": { "ref": "p" }, "to": { "ref": "r" }, "attributes": { "unit": 3 }, "recorded": true } ] }
JSON
check "the object is recorded" "true" "$(cmdb show passive-device/pp-01 --json | jq -r '.recorded')"
check "…and its relation" "true" "$(cmdb show passive-device/pp-01 --json | jq -r '.relations[0].recorded')"
check "a relation field of a recorded object is recorded" "true" "$(cmdb show room/attic --json | jq -r '.relations[] | select(.type == "at") | .recorded')"
check "query --recorded" "location/home,passive-device/pp-01,room/attic" "$(cmdb query --recorded --json | jq -r '[.[] | "\(.class)/\(.name)"] | join(",")')"
cmdb report --json >/dev/null <<<'{"source":"health-manager","objects":[{"class":"passive-device","name":"pp-01","attributes":{"description":"seen"}}]}'
check "a source seeing it later does not unrecord it" "true" "$(cmdb show passive-device/pp-01 --json | jq -r '.recorded')"
cmdb show passive-device/pp-01 | grep -q "recorded" && ok "cmdb show says so" || bad "cmdb show does not say recorded"

echo "== relations (the topology's read) =="
check "by type and from-class, with attributes, both ends named" "passive-device/pp-01 room/attic 3 true" \
    "$(cmdb relations --type placed-in --from-class asset --json | jq -r '.[0] | "\(.from.class)/\(.from.name) \(.to.class)/\(.to.name) \(.attributes.unit) \(.recorded)"')"
check "by an end" "port/eno1,port/ph0" "$(cmdb relations --type part-of --to server/srv-01 --json | jq -r '[.[] | "\(.from.class)/\(.from.name)"] | join(",")')"
check "--recorded" "at,placed-in" "$(cmdb relations --recorded --json | jq -r '[.[].type] | join(",")')"
check "as of a time before it existed: nothing" "0" "$(cmdb relations --type placed-in --at "${T1}" --json | jq 'length')"
check "an unknown type is not found" "3" "$(cmdb relations --type nope --json >/dev/null 2>&1; echo $?)"
cmdb relations --type part-of >"${T}/rels.txt" 2>&1 && grep -q "port/eno1" "${T}/rels.txt" && ok "cmdb relations prints a table" || bad "relations: $(head -3 "${T}/rels.txt")"

echo "== a relation's dependency words: set by the source that knows them =="
_eno="$(cmdb relations --type part-of --to server/srv-01 --json | jq -r '.[] | select(.from.name == "eno1") | .from.id')"
cmdb report --json >/dev/null <<<'{"source":"switch-manager","objects":[{"ref":"a","class":"network-device","name":"sw-dep"},{"ref":"p","class":"port","name":"7","attributes":{"asset":{"ref":"a"},"kind":"rj45"}}]}'
_p7="$(cmdb relations --type part-of --to network-device/sw-dep --json | jq -r '.[0].from.id')"
_cable() { cmdb report --json >/dev/null <<<"{\"source\":\"$1\",\"relations\":[{\"type\":\"connects\",\"from\":{\"id\":\"${_p7}\"},\"to\":{\"id\":\"${_eno}\"},\"attributes\":$2}]}"; }
_attrs() { cmdb relations --type connects --to "${_eno}" --json | jq -c '.[0].attributes | to_entries | sort_by(.key) | from_entries'; }
_periods() { sql "SELECT count(*) FROM relation WHERE type = 'connects' AND from_object = '${_p7}' AND to_object = '${_eno}'"; }
_cable switch-manager '{"origin":"lldp","linkSpeed":"1g"}'
_cable site-manager '{"redundancyGroup":"tappaas1:lanbond"}'
check "a report of only the group annotates the cable, keeping its attributes" '{"linkSpeed":"1g","origin":"lldp","redundancyGroup":"tappaas1:lanbond"}' "$(_attrs)"
_n="$(_periods)"
_cable switch-manager '{"origin":"lldp","linkSpeed":"1g"}'
check "another source's report that does not name it keeps it: no new period" "${_n} tappaas1:lanbond" "$(_periods) $(_attrs | jq -r '.redundancyGroup')"
_cable site-manager '{"redundancyGroup":null}'
check "null unsets it" '{"linkSpeed":"1g","origin":"lldp"}' "$(_attrs)"
refuse "a redundancy group is a name" 4 "redundancyGroup is a name" \
    "{\"source\":\"t\",\"relations\":[{\"type\":\"connects\",\"from\":{\"id\":\"${_p7}\"},\"to\":{\"id\":\"${_eno}\"},\"attributes\":{\"redundancyGroup\":3}}]}"

echo "== owned-by's pairs =="
out="$(cmdb report --json <<<'{"source":"identity-manager","objects":[{"ref":"o","class":"organization","name":"acme"},{"ref":"g","class":"group","name":"staff","attributes":{"uuid":"u-1"}},{"class":"organization","name":"acme-nl"}],"relations":[{"type":"owned-by","from":{"ref":"g"},"to":{"ref":"o"}},{"type":"owned-by","from":{"class":"organization","name":"acme-nl"},"to":{"ref":"o"}}]}' 2>&1)"
check "a group and an organization are owned by an organization" "2" "$(jq '.result.relations | length' <<<"${out}" 2>/dev/null || echo "${out}")"

echo "== volatile attributes, conditions, and the keys of pools and services =="
cmdb report --json >/dev/null <<<'{"source":"storage-manager","objects":[{"class":"storage-pool","name":"tanka1","attributes":{"onNode":"tappaas1","used":100,"size":1000,"conditions":[{"type":"capacity","status":"ok","since":"2026-10-30T00:00:00Z"}]}},{"class":"storage-pool","name":"tanka1","attributes":{"onNode":"ph-node","used":5}}]}'
check "one pool name on two nodes is two CIs" "2" "$(cmdb query storage-pool --json | jq 'length')"
out="$(cmdb report --json <<<'{"source":"storage-manager","objects":[{"class":"storage-pool","name":"tanka1","attributes":{"onNode":"tappaas1","used":200,"conditions":[{"type":"capacity","status":"critical","since":"2026-10-30T01:00:00Z"}]}}]}')"
check "a volatile change is stored and is no drift" "conditions,used none" "$(jq -r '.result.objects[0] | "\(.changed | sort | join(",")) \(if (.drift | length) == 0 then "none" else (.drift | join(",")) end)"' <<<"${out}")"
check "…it has history" "2" "$(cmdb history "$(jq -r '.result.objects[0].id' <<<"${out}")" --json | jq '[.attributes[] | select(.name == "used")] | length')"
check "attribute_def carries the flag" "t" "$(sql "SELECT volatile FROM attribute_def WHERE class = 'storage-pool' AND name = 'used'")"
check "--where on a path into the value" "tanka1" "$(cmdb query --where conditions.status=critical --json | jq -r '[.[].name] | join(",")')"
refuse "a condition has a known status" 4 "whose status is one of" \
    '{"source":"t","objects":[{"class":"zone","name":"lan","attributes":{"conditions":[{"type":"drift","status":"sick"}]}}]}'
refuse "conditions are an array" 4 "conditions must be an array" \
    '{"source":"t","objects":[{"class":"zone","name":"lan","attributes":{"conditions":"ok"}}]}'
refuse "health is gone: conditions replaced it" 4 "has no field health" \
    '{"source":"t","objects":[{"class":"zone","name":"lan","attributes":{"health":{"status":"ok"}}}]}'
_pid="$(cmdb query storage-pool --where conditions.status=critical --json | jq -r '.[0].id')"
_seen="$(cmdb query storage-pool --json | jq -r --arg i "${_pid}" '.[] | select(.id == $i) | .lastSeen')"
_rows() { sql "SELECT count(*) FROM attribute WHERE object = '${_pid}' AND name = 'conditions'"; }
_before="$(_rows)"
out="$(cmdb report --json <<<'{"source":"health-manager","assessment":true,"objects":[{"id":"'"${_pid}"'","class":"storage-pool","name":"tanka1","attributes":{"conditions":[{"type":"capacity","status":"critical","since":"2026-10-30T01:00:00Z","lastChecked":"2026-10-30T02:00:00Z"}]}}]}')"
_c="$(cmdb report --json <<<'{"source":"health-manager","assessment":true,"objects":[{"id":"'"${_pid}"'","class":"storage-pool","name":"tanka1","attributes":{"conditions":[{"type":"capacity","status":"critical","since":"2026-10-30T01:00:00Z","lastChecked":"2026-10-30T03:00:00Z"}]}}]}' | jq -r '.result.change')"
check "only lastChecked moved: no change, no new period" "null ${_before}" "${_c} $(_rows)"
check "…and it was rewritten in place" "2026-10-30T03:00:00Z" "$(cmdb show "${_pid}" --json | jq -r '.attributes.conditions.value[0].lastChecked')"
check "an assessment is no sighting: lastSeen stands" "${_seen}" "$(cmdb show "${_pid}" --json | jq -r '.lastSeen')"
refuse "an assessment names objects by id" 4 "by id" \
    '{"source":"health-manager","assessment":true,"objects":[{"class":"zone","name":"nope","attributes":{"conditions":[]}}]}'
check "the rules are served: runs-on's dependant, the shipped set" "from 5" "$(curl -s --unix-socket "${CMDB_SOCKET}" http://cmdb/v1/rules | jq -r '"\(.data.relations[] | select(.name == "runs-on") | .dependant) \(.data.rules | length)"')"
check "…a rule's dependant clause, and the attributes one may name" "true true" "$(curl -s --unix-socket "${CMDB_SOCKET}" http://cmdb/v1/rules | jq -r '"\(any(.data.rules[]; .dependant.haNode == true)) \(.data.fields | index("haNode") != null)"')"
check "the containment is served: each relation type's tree end" "to from both null" "$(curl -s --unix-socket "${CMDB_SOCKET}" http://cmdb/v1/rules | jq -r '[.data.relations[] | select(.name == ("allocated-to", "runs-on", "connects", "depends-on")) | .tree | tostring] | join(" ")')"
refuse "a pool needs its node" 4 "no key" '{"source":"t","objects":[{"class":"storage-pool","name":"tanka1"}]}'
cmdb report --json >/dev/null <<<'{"source":"module-manager","objects":[{"class":"service","name":"nextcloud:web","attributes":{"onNode":"tappaas1","version":"1"}}]}'
_svc="$(cmdb show service/nextcloud:web --json | jq -r '.id')"
cmdb report --json >/dev/null <<<'{"source":"module-manager","kind":"change","objects":[{"class":"service","name":"nextcloud:web","attributes":{"onNode":"tappaas1","version":"2"}}]}'
out="$(cmdb report --json <<<'{"source":"network-manager","objects":[{"ref":"r","class":"proxy-route","name":"nc.example"}],"relations":[{"type":"serves","from":{"ref":"r"},"to":{"class":"service","name":"nextcloud:web"}}]}')"
check "a proxy-route serves <module>:<service> by name; no placeholder; one service over versions" "0 ${_svc}" \
    "$(jq -r '.result.placeholders | length' <<<"${out}") $(cmdb relations --type serves --from proxy-route/nc.example --json | jq -r '.[0].to.id')"
check "a buddy that pulls ours is pulled-by" "pulled-by" "$(cmdb report --json <<<'{"source":"backup-manager","objects":[{"class":"backup-peer","name":"bud","attributes":{"direction":"pulled-by"}}]}' >/dev/null; cmdb show backup-peer/bud --json | jq -r '.attributes.direction.value')"
check "a network device has a management MAC" "aa:aa" "$(cmdb report --json <<<'{"source":"switch-manager","objects":[{"class":"network-device","name":"sw-01","attributes":{"mac":"aa:aa"}}]}' >/dev/null; cmdb show network-device/sw-01 --json | jq -r '.attributes.mac.value')"

echo "== what report --discover sends (D15) =="
out="$(cmdb report --json 2>&1 <<'JSON'
{ "source": "site-manager", "objects": [
  { "ref": "m", "class": "machine", "name": "deep1", "attributes": { "cpu": "Xeon", "cpus": 8, "memory": 1024, "storages": [{"storage":"local"}], "pciDevices": [{"id":"01:00"}],
    "nics": [{"name":"eno1","link":true}], "disks": [{"serial":"S1"}] } },
  { "class": "vm", "name": "firewall", "attributes": { "vmid": 410, "nics": [{"name":"net0"}], "firewall": {"rules":[]}, "authentik": {"flows":[]} } },
  { "class": "lxc", "name": "dns1", "attributes": { "vmid": 411, "nics": [], "disks": [] } },
  { "class": "cluster", "name": "c1", "attributes": { "corosyncLinks": [{"link":0}] } },
  { "class": "storage-pool", "name": "deep-pool", "attributes": { "onNode": {"ref":"m"}, "vdevs": [{"name":"mirror-0"}] } },
  { "ref": "s", "class": "server", "name": "deep-srv", "attributes": { "nics": [], "disks": [] } },
  { "class": "port", "name": "wl0", "attributes": { "asset": {"ref":"s"}, "kind": "wifi", "standard": "wifi6", "bands": ["5"], "channel": 36, "power": 20.5 } },
  { "class": "port", "name": "p1", "attributes": { "asset": {"ref":"s"}, "kind": "rj45", "link": "up", "linkSpeed": "1g", "poe": {"draw":3}, "stp": "forwarding", "vlans": {"mode":"access"}, "seen": [{"mac":"aa"}] } },
  { "class": "device", "name": "sw9", "attributes": { "uptime": 100, "vlans": [{"tag":10,"declared":true}], "clients": [] } },
  { "class": "zone", "name": "deepz", "attributes": { "interface": {"device":"vlan0.10"}, "dhcp": {"start":"a","end":"b"} } },
  { "class": "vpn-peer", "name": "phone", "attributes": { "lastHandshake": "1" } },
  { "class": "datastore", "name": "ds1", "attributes": { "gc": {"state":"ok"}, "restorePoints": [{"id":"100"}], "syncJobs": [] } } ] }
JSON
)"
check "every field a discover report sends is declared" "true" "$(jq -r '.delivered' <<<"${out}" 2>/dev/null || echo "${out}")"
out="$(cmdb report --json <<<'{"source":"switch-manager","objects":[{"class":"port","name":"p1","attributes":{"asset":"deep-srv","link":"down","seen":[],"poe":{"draw":0}}},{"class":"device","name":"sw9","attributes":{"uptime":200,"clients":[{"mac":"bb"}]}}]}')"
check "what moves on every read is no drift" "0" "$(jq '[.result.objects[].drift[]] | length' <<<"${out}")"

echo "== the discovery sweep (D15) =="
# A clean store and config/ of its own: the fixture site. The sources are stubs
# that report from files the test rewrites, module-manager drift a stub too, the
# journal a file. A sweep is read-only for the planes; only the stubs report.
kill "${SVC_PID}" 2>/dev/null; wait "${SVC_PID}" 2>/dev/null
SVC_PID=""
dropdb cmdb && createdb cmdb || bad "could not make the sweep's store"
SW="${T}/sweep"; mkdir -p "${SW}/config/environments" "${SW}/bin"
echo '{"kind":"machine","status":"archived"}' >"${SW}/config/gone.json" # an archived record: desired of nothing
cat >"${SW}/components.json" <<'JSON'
{ "version": 1, "components": [ { "name": "site-src", "cmdbSource": true }, { "name": "old-src", "cmdbSource": true } ] }
JSON
# site-src reports what its file says, and records that --discover was asked.
printf '#!/usr/bin/env bash\necho "$*" >>%q\nnode %q report --json <%q >/dev/null\n' "${SW}/asked" "${CLI}" "${SW}/site.json" >"${SW}/bin/site-src"
# old-src's report verb predates --discover.
cat >"${SW}/bin/old-src" <<BASH
#!/usr/bin/env bash
if [[ " \$* " == *" --discover "* ]]; then echo "[Error] old-src report: unknown option '--discover'" >&2; exit 1; fi
echo plain >>"${SW}/old-asked"
BASH
# module-manager drift: nextcloud's cores differ from desired once told to.
cat >"${SW}/bin/module-manager" <<BASH
#!/usr/bin/env bash
if [[ -e "${SW}/differ" && "\$2" == nextcloud ]]; then
  echo '{"module":"nextcloud","services":{"cluster:vm":{"units":[{"fields":[{"field":"cores","desired":"4","actual":"6"}]}],"unreconciled":[],"adopt":[]}}}'
else echo '{"module":"'\$2'","services":{}}'; fi
BASH
chmod +x "${SW}/bin/"*
cat >"${SW}/site.json" <<'JSON'
{ "source": "site-src", "objects": [
  { "ref": "m", "class": "machine", "name": "tappaas1", "attributes": { "desired": { "file": "tappaas1.json" }, "stage": "operational" } },
  { "class": "vm", "name": "nextcloud", "attributes": { "vmid": 200, "cores": 4, "desired": { "file": "nextcloud.json" }, "onNode": { "ref": "m" } } },
  { "class": "zone", "name": "lan", "attributes": { "vlan": 10, "desired": { "file": "zones.json", "key": "lan" } } } ] }
JSON
echo '{"kind":"machine"}' >"${SW}/config/tappaas1.json"; echo '{"kind":"vm"}' >"${SW}/config/nextcloud.json"; echo '{"kind":"application"}' >"${SW}/config/backup.json"
echo '{"_comment":"x","lan":{"vlan":10}}' >"${SW}/config/zones.json"
: >"${SW}/journal"
export CMDB_COMPONENTS="${SW}/components.json" CMDB_SOURCE_PATH="${SW}/bin:${PATH}" CMDB_SWEEP_JOURNAL="${SW}/journal"
TAPPAAS_CONFIG="${SW}/config" node "${MAIN}" serve >"${T}/svc2.log" 2>&1 &
SVC_PID=$!
sleep 0.2
for _ in $(seq 1 100); do curl -s --unix-socket "${CMDB_SOCKET}" http://cmdb/v1/health >/dev/null 2>&1 && break; sleep 0.1; done
sweep() { cmdb sweep --json; echo "rc=$?" >"${SW}/rc"; }

out="$(sweep)"
check "the first sweep is the baseline: nothing to compare, nothing wrong" "null healthy 0 rc=0" "$(jq -r '"\(.since) \(.status) \(.differences | length)"' <<<"${out}") $(cat "${SW}/rc")"
check "every source was asked for full depth" "report --discover" "$(cat "${SW}/asked")"
check "a source that does not know the flag is asked plainly" "true old-src ok plain" "$(jq -r '.sources[] | select(.source == "old-src") | "\(.fallback) old-src \(if .ok then "ok" else "failed" end)"' <<<"${out}") $(cat "${SW}/old-asked")"
check "the record is a change row, verb sweep" "1" "$(sql "SELECT count(*) FROM change WHERE verb = 'sweep' AND body ? 'counts'")"
check "cmdb sweep --last reads it" "healthy" "$(cmdb sweep --last --json | jq -r '.status')"

# One expected change (a verb reports it), one drift (cores, no verb behind it),
# one unmanaged guest, one missing record.
cmdb report --json >/dev/null <<<'{"source":"module-manager","kind":"change","verb":"module modify","job":"J-9","objects":[{"class":"zone","name":"lan","attributes":{"vlan":11}}]}'
sed -i.bak 's/"vlan": 10/"vlan": 11/; s/"cores": 4/"cores": 6/' "${SW}/site.json"
stray="$(jq '.objects += [{"class":"vm","name":"stray","attributes":{"vmid":999}}]' "${SW}/site.json")"; echo "${stray}" >"${SW}/site.json"
echo '{"gone":{"vlan":30}}' | jq -s '.[0] + {"lan":{"vlan":11}}' >"${SW}/config/zones.json"
touch "${SW}/differ"
out="$(sweep)"
pick() { jq -r --arg k "$1" '[.differences[] | select(.kind == $k) | "\(.class)/\(.name) \(.attribute // "-")"] | join(",")' <<<"${out}"; }
check "the verb's change is expected, with its verb" "zone/lan vlan true module modify" \
    "$(jq -r '.differences[] | select(.name == "lan" and .attribute == "vlan") | "\(.class)/\(.name) \(.attribute) \(.expected) \(.verb)"' <<<"${out}")"
check "the change no verb explains is drift" "vm/nextcloud cores false site-src" \
    "$(jq -r '.differences[] | select(.kind == "changed" and .attribute == "cores") | "\(.class)/\(.name) \(.attribute) \(.expected) \(.source)"' <<<"${out}")"
check "the differ's answer is listed" "vm/nextcloud cluster:vm.cores 4 6" \
    "$(jq -r '.differences[] | select(.kind == "desired") | "\(.class)/\(.name) \(.attribute) \(.before) \(.after)"' <<<"${out}")"
check "a guest nothing declares is unmanaged" "vm/stray -" "$(pick unmanaged)"
check "a record no source saw is missing" "zone/gone -" "$(pick missing)"
check "a missing record is exit 2, critical" "critical rc=2" "$(jq -r '.status' <<<"${out}") $(cat "${SW}/rc")"
check "the counts: the stray guest is drift (it appeared) and unmanaged" "1 2 1 1 1 0" "$(jq -r '.counts | "\(.expected) \(.drift) \(.desired) \(.unmanaged) \(.missing) \(.sourcesFailed)"' <<<"${out}")"
check "the drifted object is marked, as D6 does" "true" "$(cmdb show vm/nextcloud --json | jq '.drift.attributes | has("cores")')"
check "one journal line per difference" "$(jq '.differences | length' <<<"${out}")" "$(jq -s 'length' "${SW}/journal")"
check "a journal line has the fields" "changed vm nextcloud site-src cores 4 6 false" \
    "$(jq -r 'select(.attribute == "cores" and .kind == "changed") | "\(.kind) \(.class) \(.name) \(.source) \(.attribute) \(.before) \(.after) \(.expected)"' "${SW}/journal")"
cmdb sweep --last >"${SW}/text" 2>&1; grep -q "DRIFT" "${SW}/text" && grep -q "expected (module modify)" "${SW}/text" && ok "the report, for people, says which is which" || bad "sweep text: $(head -8 "${SW}/text")"

# Fix the record and the guest: drift alone is exit 1.
echo '{"lan":{"vlan":11}}' >"${SW}/config/zones.json"; rm -f "${SW}/differ"
jq '.objects |= map(select(.name != "stray"))' "${SW}/site.json" >"${SW}/s2"; mv "${SW}/s2" "${SW}/site.json"
sed -i.bak 's/"cores": 6/"cores": 8/' "${SW}/site.json"
cmdb report --json >/dev/null <<<'{"source":"module-manager","kind":"change","verb":"module delete","objects":[{"class":"vm","name":"stray","attributes":{"vmid":999},"end":true}]}'
out="$(sweep)"
check "drift alone is exit 1, a warning" "warning rc=1" "$(jq -r '.status' <<<"${out}") $(cat "${SW}/rc")"
check "a CI retired by a verb went as expected" "true" "$(jq -r '.differences[] | select(.name == "stray" and .attribute == null) | .expected' <<<"${out}")"
out="$(sweep)"
check "nothing changed: exit 0, healthy" "healthy rc=0 0" "$(jq -r '.status' <<<"${out}") $(cat "${SW}/rc") $(jq '.counts.drift' <<<"${out}")"
printf '#!/usr/bin/env bash\necho "pve refused" >&2\nexit 7\n' >"${SW}/bin/site-src"
out="$(sweep)"
check "a source that fails is exit 2, and named" "critical rc=2 site-src" "$(jq -r '.status' <<<"${out}") $(cat "${SW}/rc") $(jq -r '.sources[] | select(.ok | not) | .source' <<<"${out}")"
check "…and what only it saw is missing, not silently fine" "true" "$(jq '.counts.missing >= 3' <<<"${out}")"

# New, not drift: a verb makes an asset; the discovery after it finds its ports
# and fills its fields. Those are new, with the verb; a port of an old asset,
# and a later change of a filled field, are drift.
printf '#!/usr/bin/env bash\necho "$*" >>%q\nnode %q report --json <%q >/dev/null\n' "${SW}/asked" "${CLI}" "${SW}/site.json" >"${SW}/bin/site-src"
cmdb report --json >/dev/null <<<'{"source":"asset-manager","objects":[{"class":"server","name":"srv-old","attributes":{"cpu":"E5"}}]}'
sweep >/dev/null
cmdb report --json >/dev/null <<<'{"source":"site-manager","kind":"change","verb":"node add","job":"J-40","objects":[{"class":"server","name":"srv-04"}]}'
out="$(sweep)"
check "the asset the verb made is expected, by its verb" "true node add null" \
    "$(jq -r '.differences[] | select(.name == "srv-04" and .kind == "appeared" and .attribute == null) | "\(.expected) \(.verb) \(.reason)"' <<<"${out}")"
cmdb report --json >/dev/null <<<'{"source":"site-manager","objects":[
  {"class":"server","name":"srv-04","attributes":{"cpu":"EPYC 7302","memory":64}},
  {"class":"port","name":"srv04-nic0","attributes":{"asset":"srv-04","kind":"rj45"}},
  {"class":"port","name":"srv04-nic1","attributes":{"asset":"srv-04","kind":"rj45"}},
  {"class":"port","name":"old-nic9","attributes":{"asset":"srv-old","kind":"rj45"}}]}'
out="$(sweep)"
check "a port of the asset a verb made is new, with that verb and its owner" \
    "true new node add server/srv-04,true new node add server/srv-04" \
    "$(jq -r '[.differences[] | select(.class == "port" and (.name | startswith("srv04")) and .kind == "appeared" and .attribute == null) | "\(.expected) \(.reason) \(.verb) \(.owner)"] | join(",")' <<<"${out}")"
check "…and its part-of relation with it" "true new,true new" \
    "$(jq -r '[.differences[] | select(.class == "port" and (.name | startswith("srv04")) and ((.attribute // "") | startswith("→part-of"))) | "\(.expected) \(.reason)"] | join(",")' <<<"${out}")"
check "a port of an old asset is drift" "false null" \
    "$(jq -r '.differences[] | select(.name == "old-nic9" and .kind == "appeared" and .attribute == null) | "\(.expected) \(.reason)"' <<<"${out}")"
check "the fields the first observation fills on the verb-made asset are new" "cpu:true:new:node add memory:true:new:node add" \
    "$(jq -r '[.differences[] | select(.name == "srv-04" and .kind == "appeared" and .attribute != null) | "\(.attribute):\(.expected):\(.reason):\(.verb)"] | join(" ")' <<<"${out}")"
check "the counts: new among the expected, the old asset's port drift" "true true" \
    "$(jq -r '"\(.counts.new >= 6) \(.counts.drift >= 1)"' <<<"${out}")"
cmdb sweep --last >"${SW}/text" 2>&1
grep -q "new (of server/srv-04, node add)" "${SW}/text" && grep -q "expected (.* new)" "${SW}/text" && ok "the report, for people, says what is new" || bad "sweep text: $(head -8 "${SW}/text")"
cmdb report --json >/dev/null <<<'{"source":"site-manager","objects":[{"class":"server","name":"srv-04","attributes":{"memory":128}}]}'
out="$(sweep)"
check "a later change of a filled field is drift" "changed false null" \
    "$(jq -r '.differences[] | select(.name == "srv-04" and .attribute == "memory") | "\(.kind) \(.expected) \(.reason)"' <<<"${out}")"

echo "== the store's invariant =="
_ov="$(sql "INSERT INTO attribute (object, name, value, source, validity)
            SELECT object, name, value, 'test', tstzrange(lower(validity) - interval '1 hour', NULL) FROM attribute
             WHERE name = 'cores' AND upper_inf(validity) LIMIT 1")"
grep -q "attribute_no_overlap" <<<"${_ov}" && ok "an overlapping period is refused by the exclusion constraint" || bad "overlap not refused: ${_ov}"

results
