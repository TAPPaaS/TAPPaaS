# dashboards.nix — the shipped Grafana dashboards per class (ADR-046 D7):
# node, guest, pool, datastore and published service, each for one CI chosen in
# its variable, so the console links to them with ?var-ci=<id> (a pool with
# var-node=<its node's id>&var-pool=<name>). Grafana provisions the directory
# this returns (logging.nix, provision.dashboards). A sibling .nix, not JSON
# files, because update-os carries a module's .nix files to the guest.
{ pkgs }:
let
  ds = { type = "prometheus"; uid = "prometheus"; };
  panel = i: title: unit: exprs: {
    id = i + 1;
    type = "timeseries";
    inherit title;
    datasource = ds;
    gridPos = { x = if (i - (i / 2) * 2) == 0 then 0 else 12; y = (i / 2) * 8; w = 12; h = 8; };
    fieldConfig.defaults = { inherit unit; };
    targets = builtins.genList (n: {
      refId = builtins.elemAt [ "A" "B" "C" "D" ] n;
      expr = (builtins.elemAt exprs n).expr;
      legendFormat = (builtins.elemAt exprs n).legend;
    }) (builtins.length exprs);
  };
  q = expr: legend: { inherit expr legend; };
  textVar = name: label: { inherit name label; type = "textbox"; query = ""; };
  dashboard = uid: title: vars: panels: {
    inherit uid title;
    tags = [ "tappaas" "performance" ];
    schemaVersion = 39;
    editable = false;
    time = { from = "now-24h"; to = "now"; };
    templating.list = vars;
    annotations.list = [];
    panels = builtins.genList (i: (builtins.elemAt panels i) i) (builtins.length panels);
  };
  ci = ''tappaas_ci_id="$ci"'';
  dashboards = {
    "tappaas-node" = dashboard "tappaas-node" "TAPPaaS · node" [ (textVar "ci" "Node CI id") ] [
      (i: panel i "CPU used" "percent" [ (q "avg(proxmox_node_cpustat_cpu{${ci}}) * 100" "cpu") ])
      (i: panel i "Memory used" "percent" [ (q "sum(proxmox_node_memory_memused{${ci}}) / sum(proxmox_node_memory_memtotal{${ci}}) * 100" "used") ])
      (i: panel i "Pressure (some, 60 s)" "percent" [ (q "max by (resource) (tappaas_node_psi_some_avg60{${ci}})" "{{resource}}") ])
      (i: panel i "Pressure (full, 60 s)" "percent" [ (q "max by (resource) (tappaas_node_psi_full_avg60{${ci}})" "{{resource}}") ])
      (i: panel i "ZFS pool wait" "s" [ (q "max by (pool) (tappaas_zpool_write_wait_seconds{${ci}})" "{{pool}} write") (q "max by (pool) (tappaas_zpool_read_wait_seconds{${ci}})" "{{pool}} read") ])
      (i: panel i "Network" "Bps" [ (q "sum(rate(proxmox_node_network_receive_total{${ci}}[5m]))" "in") (q "sum(rate(proxmox_node_network_transmit_total{${ci}}[5m]))" "out") ])
    ];
    "tappaas-guest" = dashboard "tappaas-guest" "TAPPaaS · guest" [ (textVar "ci" "Guest CI id") ] [
      (i: panel i "CPU used, of its cores" "percent" [ (q "avg(proxmox_vm_cpu{${ci}}) * 100" "cpu") ])
      (i: panel i "Memory working set" "percent" [ (q "sum(tappaas_guest_memory_used_bytes{${ci}}) / sum(proxmox_vm_maxmem{${ci}}) * 100" "working set") ])
      (i: panel i "Pressure" "percent" [ (q "max(proxmox_vm_pressurecpusome{${ci}})" "cpu") (q "max(proxmox_vm_pressurememorysome{${ci}})" "memory") (q "max(proxmox_vm_pressureiosome{${ci}})" "io") ])
      (i: panel i "Disk" "Bps" [ (q "sum(rate(proxmox_vm_diskread_total{${ci}}[5m]))" "read") (q "sum(rate(proxmox_vm_diskwrite_total{${ci}}[5m]))" "write") ])
      (i: panel i "Network" "Bps" [ (q "sum(rate(proxmox_vm_netin_total{${ci}}[5m]))" "in") (q "sum(rate(proxmox_vm_netout_total{${ci}}[5m]))" "out") ])
      (i: panel i "Inside: filesystem free" "percent" [ (q "min by (mountpoint) (node_filesystem_avail_bytes{${ci}} / node_filesystem_size_bytes{${ci}}) * 100" "{{mountpoint}}") ])
    ];
    "tappaas-pool" = dashboard "tappaas-pool" "TAPPaaS · storage pool" [ (textVar "node" "Its node's CI id") (textVar "pool" "Pool") ] [
      (i: panel i "Write latency" "s" [ (q ''max(tappaas_zpool_write_wait_seconds{tappaas_ci_id="$node", pool="$pool"})'' "write") ])
      (i: panel i "Read latency" "s" [ (q ''max(tappaas_zpool_read_wait_seconds{tappaas_ci_id="$node", pool="$pool"})'' "read") ])
    ];
    "tappaas-datastore" = dashboard "tappaas-datastore" "TAPPaaS · backup datastore" [ (textVar "ci" "Backup server CI id") ] [
      (i: panel i "Datastore used" "bytes" [ (q "max by (id) ({__name__=~\"pbs_datastore_used\", ${ci}})" "{{id}}") ])
      (i: panel i "Datastore available" "bytes" [ (q "max by (id) ({__name__=~\"pbs_datastore_avail(able)?\", ${ci}})" "{{id}}") ])
      (i: panel i "CPU" "percent" [ (q "avg({__name__=~\"pbs_cpustat_cpu\", ${ci}}) * 100" "cpu") ])
      (i: panel i "Memory used" "bytes" [ (q "max({__name__=~\"pbs_memory_memused\", ${ci}})" "used") ])
    ];
    "tappaas-service" = dashboard "tappaas-service" "TAPPaaS · published service" [ (textVar "ci" "Route CI id") ] [
      (i: panel i "Response time (p50, p95, p99)" "s" [
        (q "histogram_quantile(0.5, sum by (le) (rate(caddy_http_request_duration_seconds_bucket{${ci}}[5m])))" "p50")
        (q "histogram_quantile(0.95, sum by (le) (rate(caddy_http_request_duration_seconds_bucket{${ci}}[5m])))" "p95")
        (q "histogram_quantile(0.99, sum by (le) (rate(caddy_http_request_duration_seconds_bucket{${ci}}[5m])))" "p99") ])
      (i: panel i "Requests by status class" "reqps" [ (q "sum by (code) (rate(caddy_http_request_duration_seconds_count{${ci}}[5m]))" "{{code}}") ])
      (i: panel i "Errors (5xx)" "percent" [ (q ''sum(rate(caddy_http_request_duration_seconds_count{${ci}, code="5xx"}[5m])) / sum(rate(caddy_http_request_duration_seconds_count{${ci}}[5m])) * 100'' "5xx") ])
      (i: panel i "Probe from inside the site" "s" [ (q "max(probe_duration_seconds{${ci}})" "response") ])
      (i: panel i "Probe up" "percentunit" [ (q "avg_over_time(probe_success{${ci}}[15m])" "up") ])
      (i: panel i "Certificate expires in" "d" [ (q "min((probe_ssl_earliest_cert_expiry{${ci}} - time()) / 86400)" "days") ])
    ];
  };
in
pkgs.linkFarm "tappaas-dashboards" (map (uid: {
  name = "${uid}.json";
  path = pkgs.writeText "${uid}.json" (builtins.toJSON dashboards.${uid});
}) (builtins.attrNames dashboards))
