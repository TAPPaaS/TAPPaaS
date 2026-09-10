# Subnet-filtering overlay for the source-NAT deep test (ADR-016 / #239).
#
# Reproduces the behaviour that makes source NAT necessary at all: an appliance
# whose firmware accepts TCP only from its own /24 and silently drops anything
# else. The Alfen NG5 charger in #239 is the reference — OPNsense passed every
# packet and the *device* dropped them, which is why a firewall rule permitting
# the traffic was not enough and the fault took weeks to find.
#
# ALLOW-LIST, not a drop rule. The obvious spelling is to keep the port open
# and add "saddr != <cidr> drop", and it does not work: the shared webserver
# overlay puts the port in allowedTCPPorts, whose accept is evaluated first, so
# the drop is never reached and every source is served. Deep run 7 caught it —
# the device answered from the client zone with no masquerade in place, which
# would have made the whole test meaningless while looking green.
#
# So the port is taken back OUT of allowedTCPPorts and the only way in is an
# explicit accept for the local /24. Everything else meets the firewall's
# default policy, which DROPS rather than rejects — and the drop is what makes
# this faithful: the real device leaves the client hanging ("searching
# indefinitely", in #239's words) instead of returning an immediate RST.
#
# With masquerade in place the packets arrive sourced from the zone gateway,
# which IS inside the accepted /24, and the same listener answers normally.
# That flip — unreachable, then reachable, with nothing changed on the device —
# is the whole assertion.

{ config, lib, pkgs, ... }:

let
  cfg = config.tappaas.test;
in
{
  options.tappaas.test.acceptOnlyFrom = lib.mkOption {
    type = lib.types.str;
    default = "";
    example = "10.4.20.0/24";
    description = ''
      CIDR this host accepts webserver connections from. Anything outside it is
      dropped, imitating firmware that filters by source subnet. Empty disables
      the filter, leaving the plain test webserver.
    '';
  };

  config = lib.mkIf (cfg.acceptOnlyFrom != "") {
    networking.nftables.enable = true;

    # The webserver overlay opened this port to everyone, and that accept is
    # evaluated before the source check below — so the port has to come OUT of
    # the blanket allow-list for the filter to mean anything.
    #
    # 22 is named explicitly rather than cleared wholesale: openssh puts it
    # here, and the harness reaches this VM over ssh to probe it. Run 9 cleared
    # the list entirely and locked the test out of its own probe — the device
    # answered a masqueraded request from the client zone while the control
    # said it was down, because the control could no longer log in.
    networking.firewall.allowedTCPPorts = lib.mkForce [ 22 ];

    networking.firewall.extraInputRules = ''
      tcp dport ${toString cfg.webserverPort} ip saddr ${cfg.acceptOnlyFrom} accept
    '';
  };
}
