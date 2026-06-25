# logging — tests

## How to run
- `./test.sh <vmname>` (e.g. `./test.sh logging`). The vmname argument is required; `-h`/`--help` prints usage.
- Non-default instances can be targeted with `TAPPAAS_VMID_OVERRIDE=…` and `TAPPAAS_ZONE0_OVERRIDE=…` (issue #196).
- There is NO deep tier — `./test.sh` runs all checks unconditionally.
- All checks SSH into the VM (`tappaas@<vmname>.<zone0>.internal`, zone0 defaults to `mgmt`) and curl localhost service endpoints; the run is live against the VM but has no fast/deep split.

## Standard (fast) tests
- Check 1 — SSH: asserts `ssh tappaas@<VM_HOST> exit 0` succeeds.
- Check 2 — Loki ready: asserts `curl http://127.0.0.1:3100/ready` response contains `ready`.
- Check 3 — Loki metrics: asserts `http://127.0.0.1:3100/metrics` returns HTTP 200.
- Check 4 — Grafana login: asserts `http://127.0.0.1:3000/login` returns HTTP 200 or 302.
- Check 5 — Grafana health: asserts `http://127.0.0.1:3000/api/health` JSON shows `"database":…"ok"`.
- Check 6 — Promtail metrics: asserts `http://127.0.0.1:9080/metrics` returns HTTP 200.
- Check 7 — Syslog port: asserts the syslog ingest port `tcp/1514` is in LISTEN state (`ss -lnt`).
- Check 8 — Loki ingest: asserts Loki has ≥1 `job` label value (`/loki/api/v1/label/job/values`), i.e. at least one log stream from the local journal has been received.

## Deep tests (live; --deep / TAPPAAS_TEST_DEEP=1)
- None — there is no deep tier. Because the standard checks only confirm endpoints are up and that ≥1 job label exists, the following remain unverified: remote/syslog log ingestion actually reaching Loki (only the local journal scrape is implied by check 8), retention/compaction behaviour, Grafana dashboards/datasource wiring, alerting, and end-to-end log query results.

## Coverage notes
- All eight checks are liveness/health probes of localhost endpoints over SSH; none validate log content, query results, or external syslog clients shipping to `tcp/1514`.
- Check 8 is the only ingest assertion and it is weak: it only requires ≥1 job label value to exist (from the local systemd-journal scrape), not that a specific source or remote sender's logs arrived.
- No teardown/cleanup logic and no fixtures — the test is purely read-only against an already-installed VM.
- No deep tier means there is no separate live-integration gate; the standard run is itself live and fails if the VM is unreachable.
