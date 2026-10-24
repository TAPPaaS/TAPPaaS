"""Unit tests for the WAN's IPv6 router read and re-learn (#875).

The fixtures are what hrossen's firewall printed: healthy after the WAN was
reconfigured, and stale the day before (the ISP's router replaced, OPNsense
still naming the old one and no default route left).

Run with:
    cd src && python -m unittest test.test_wan6 -v
"""

from __future__ import annotations

import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import MagicMock, patch

from opnsense_controller.wan6 import (
    Advert, apply_script, parse_adverts, parse_wan, relearn_plan,
)

OLD = "fe80::ff:fe91:2291"
NEW = "fe80::47:ff:fe00:168"


def gateways(gw: str) -> str:
    return json.dumps({"dpinger": {
        "ipv4-gateway": {"gateway": "80.248.138.1", "ipprotocol": "inet", "name": "ipv4-gateway"},
        "WAN_DHCP6": {"gateway": f"{gw}%vtnet1", "ipprotocol": "inet6", "name": "WAN_DHCP6", "status": "none"},
    }})


HEALTHY = "\n".join([
    "wanif\tvtnet1",
    f"recorded\t{NEW}",
    "prefix\t2a13:e747:a210:4500::/56",
    f"route\t{NEW}%vtnet1",
    "address\t2a13:e740:292:978c::545",
    "rtsold\tyes",
    f"neighbour\t{NEW}\tyes\t02:47:00:00:01:68",
    f"neighbour\t{NEW}%vtnet1\tyes\t02:47:00:00:01:68",
    f"gateways\t{gateways(NEW)}",
])

STALE = "\n".join([
    "wanif\tvtnet1",
    f"recorded\t{OLD}",
    "prefix\t2a13:e747:a210:8200::/56",
    "route\t",
    "address\t2a13:e740:292:978c::aba",
    "rtsold\tyes",
    f"neighbour\t{OLD}\tno\t",
    f"gateways\t{gateways(OLD)}",
])

# tcpdump -n -vv on the WAN while rtsol solicits (hrossen, 2026-10-24).
TCPDUMP = """\
07:58:29.506868 IP6 (flowlabel 0xde832, hlim 255, next-header ICMPv6 (58) payload length: 48) fe80::47:ff:fe00:168 > ff02::1: [icmp6 sum ok] ICMP6, router advertisement, length 48
\thop limit 64, Flags [managed], pref medium, router lifetime 3600s, reachable time 0ms, retrans timer 0ms
\t  prefix info option (3), length 32 (4): 2a13:e740:292:978c::/64, Flags [onlink], valid time 3600s, pref. time 2700s
\t    0x0000:  4080 0000 0e10 0000 0a8c 0000 0000 2a13
"""


class TestParse(unittest.TestCase):
    def test_healthy(self):
        s = parse_wan(HEALTHY)
        self.assertEqual((s.wanif, s.recorded, s.route, s.gateway), ("vtnet1", NEW, NEW, NEW))
        self.assertEqual(s.prefix, "2a13:e747:a210:4500::/56")
        self.assertTrue(s.rtsold)
        self.assertEqual(len(s.neighbours), 1, "the route and the record are one neighbour")
        self.assertTrue(s.to_json()["routerAnswers"])

    def test_stale(self):
        s = parse_wan(STALE)
        self.assertEqual((s.recorded, s.route, s.gateway), (OLD, "", OLD))
        self.assertFalse(s.neighbour(OLD).answers)
        self.assertFalse(s.to_json()["routerAnswers"])

    def test_no_wan(self):
        self.assertEqual(parse_wan("wanif\t\n").wanif, "")

    def test_adverts(self):
        ads = parse_adverts(TCPDUMP)
        self.assertEqual([(a.router, a.lifetime, a.managed) for a in ads], [(NEW, 3600, True)])

    def test_no_answer(self):
        self.assertEqual(parse_adverts("tcpdump: listening on vtnet1\n"), [])


class TestPlan(unittest.TestCase):
    def test_nothing_to_do(self):
        p = relearn_plan(parse_wan(HEALTHY), [Advert(NEW, 3600)])
        self.assertEqual((p.router, p.steps, p.problems), (NEW, [], []))

    def test_stale_router(self):
        s = parse_wan(STALE)
        p = relearn_plan(s, [Advert(NEW, 3600)])
        self.assertEqual(p.steps, ["record", "newipv6"])
        script = apply_script(s, p)
        self.assertLess(script.index("-6rd -a " + NEW), script.index("interface newipv6 vtnet1 force"))
        self.assertNotIn("reconfigure", script, "the lease is not renewed")
        self.assertNotIn("rtsold", script, "a running rtsold is left alone")

    def test_route_only(self):
        # The record is right, the route went: the event alone puts it back.
        s = parse_wan(HEALTHY.replace(f"route\t{NEW}%vtnet1", "route\t"))
        self.assertEqual(relearn_plan(s, [Advert(NEW, 3600)]).steps, ["newipv6"])

    def test_rtsold_down(self):
        s = parse_wan(HEALTHY.replace("rtsold\tyes", "rtsold\tno"))
        p = relearn_plan(s, [Advert(NEW, 3600)])
        self.assertEqual(p.steps, ["rtsold"])
        self.assertIn("/usr/sbin/rtsold -d -aiu", apply_script(s, p))

    def test_recorded_still_advertising_wins(self):
        p = relearn_plan(parse_wan(HEALTHY), [Advert("fe80::99", 1800), Advert(NEW, 3600)])
        self.assertEqual((p.router, p.steps), (NEW, []))

    def test_no_router_answers(self):
        p = relearn_plan(parse_wan(STALE), [Advert(NEW, 0)])
        self.assertEqual(p.steps, [])
        self.assertIn("no router answered", p.problems[0])


class TestRelearn(unittest.TestCase):
    """ipv6-manager relearn: --check-mode changes nothing; --apply runs the plan, then apply."""

    def run_relearn(self, states, check_mode):
        from opnsense_controller import ipv6_cli
        fw = MagicMock(return_value="")
        after = MagicMock(return_value=True)
        reads = iter(states)
        with patch.object(ipv6_cli, "read_wan", side_effect=lambda h: next(reads)), \
             patch.object(ipv6_cli, "solicit", return_value=[Advert(NEW, 3600)]), \
             patch.object(ipv6_cli, "_fw", fw), redirect_stdout(io.StringIO()) as out:
            ok = ipv6_cli.relearn("10.0.0.1", check_mode, after=after, settle_seconds=0)
        return ok, fw, after, out.getvalue()

    def test_check_mode_changes_nothing(self):
        ok, fw, after, out = self.run_relearn([parse_wan(STALE)], True)
        self.assertTrue(ok)
        fw.assert_not_called()
        after.assert_not_called()
        self.assertIn(f"would record the advertising router: ifctl -i vtnet1 -6rd -a {NEW}", out)
        self.assertIn(f"recorded router:   {OLD} (does not answer", out)

    def test_apply_then_converge(self):
        ok, fw, after, out = self.run_relearn([parse_wan(STALE), parse_wan(HEALTHY)], False)
        self.assertTrue(ok)
        self.assertIn("interface newipv6 vtnet1 force", fw.call_args[0][1])
        after.assert_called_once()
        self.assertIn(f"the WAN's IPv6 router is {NEW}", out)

    def test_apply_that_does_not_take_fails(self):
        ok, _, after, _ = self.run_relearn([parse_wan(STALE), parse_wan(STALE)], False)
        self.assertFalse(ok)
        after.assert_not_called()

    def test_nothing_to_do_still_converges(self):
        ok, fw, after, _ = self.run_relearn([parse_wan(HEALTHY)], False)
        self.assertTrue(ok)
        fw.assert_not_called()
        after.assert_called_once()


if __name__ == "__main__":
    unittest.main()
