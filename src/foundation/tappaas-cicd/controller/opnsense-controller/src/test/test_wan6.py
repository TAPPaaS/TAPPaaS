"""Unit tests for the WAN's IPv6 router read and re-learn (#875).

The fixtures are what hrossen's firewall printed: healthy after the WAN was
reconfigured, and stale the day before (the ISP's router replaced, OPNsense
still naming the old one and no default route left).

Run with:
    cd src && python -m unittest test.test_wan6 -v
"""

from __future__ import annotations

import json
import unittest

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


if __name__ == "__main__":
    unittest.main()
