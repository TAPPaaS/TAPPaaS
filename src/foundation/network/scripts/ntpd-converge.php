<?php
/*
 * ntpd-converge.php — the firewall's time service, as TAPPaaS needs it (#716).
 *
 * Piped to `php /dev/stdin` on the firewall by network/update.sh. Idempotent:
 * prints CHANGED when it wrote config.xml, UNCHANGED otherwise; the caller then
 * restarts ntpd either way (pluginctl -s ntpd restart re-renders ntpd.conf).
 *
 * orphan = 16 — orphan mode OFF. OPNsense always writes `tos orphan <n>` and
 * defaults <n> to 12, so a firewall that has lost its upstream keeps answering
 * at stratum 12 with zero root dispersion. Clients accept that, and never move
 * on to a second server. At 16 an unsynchronised ntpd says so (leap 3), and
 * timesyncd moves down its list to the public servers guests now carry.
 *
 * iburst on every upstream — after the restart, eight quick exchanges instead
 * of one per poll, so the firewall is disciplined again within seconds rather
 * than after several 512 s polls (OPNsense hard-codes maxpoll 9).
 */
require_once("config.inc");
require_once("util.inc");

global $config;

if (!isset($config['ntpd']) || !is_array($config['ntpd'])) {
    $config['ntpd'] = [];
}

$changed = [];

if (($config['ntpd']['orphan'] ?? '') !== '16') {
    $config['ntpd']['orphan'] = '16';
    $changed[] = 'orphan=16';
}

$servers = array_values(array_filter(explode(' ', $config['system']['timeservers'] ?? '')));
$want = implode(' ', $servers);
if ($want !== '' && ($config['ntpd']['iburst'] ?? '') !== $want) {
    $config['ntpd']['iburst'] = $want;
    $changed[] = 'iburst=' . $want;
}

if ($changed) {
    write_config('TAPPaaS (#716): ntpd orphan mode off, iburst on every upstream');
    echo 'CHANGED ' . implode('; ', $changed) . "\n";
} else {
    echo "UNCHANGED\n";
}
