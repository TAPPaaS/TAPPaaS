"""The WAN's IPv6 router as OPNsense follows it (#875): read, re-learn.

OPNsense takes its IPv6 default router from one place only: the router
advertisement that answers rtsold's own solicitation. rtsold's script writes
the sender to /tmp/<wan>_routerv6 (`ifctl -6rd`), rc.newwanipv6 sets a static
default route to it, and the WAN_DHCP6 gateway reads the same file. rtsold
solicits only when it starts (the WAN is configured), so a router that changes
later, and sends no advertisement of its own, is never learned: the route
points at a link-local address nobody answers.

`read_wan` is what the ipv6-egress health gate reads; `solicit` asks the link
which router answers now; `relearn_plan` compares the two and `relearn` carries
the plan out the way OPNsense's own scripts do, without renewing the lease:

  1. record the advertising router   ifctl -i <wan> -6rd -a <router>
  2. re-run the IPv6 WAN event       configctl interface newipv6 <wan> force
     (rc.newwanipv6: the default route, the WAN_DHCP6 gateway, the filter)
  3. start rtsold only when it is not running — restarting a running one makes
     its script HUP dhcp6c, which releases the lease and solicits a new one: on
     hrossen that moved the delegated prefix.

`configctl interface reconfigure wan` would do all of it too, IPv4 included,
and renews both leases.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field

# rtsold as OPNsense starts it (interfaces.inc, interface_dhcpv6_configure).
RTSOLD_CMD = ("/usr/sbin/rtsold -d -aiu -p /var/run/rtsold.pid "
              "-A /usr/local/opnsense/scripts/interfaces/rtsold_script.sh "
              "-R /usr/local/opnsense/scripts/interfaces/rtsold_resolvconf.sh")

GATEWAY_NAME = "WAN_DHCP6"

# One ssh: everything the gate and --check report, read-only. The ping to the
# router is link-local, which the firewall itself may reach (pf passes self to
# fe80::/10), and it refreshes the neighbour entry it then reads.
READ_SH = r"""
WANIF=$(php -r 'require_once("config.inc"); $c = config_read_array("interfaces"); echo $c["wan"]["if"] ?? "";')
echo "wanif	${WANIF}"
[ -n "${WANIF}" ] || exit 0
echo "recorded	$(cat /tmp/${WANIF}_routerv6 2>/dev/null | head -n 1)"
echo "prefix	$(cat /tmp/${WANIF}_prefixv6 2>/dev/null | head -n 1)"
echo "route	$(netstat -rn -f inet6 | awk '$1 == "default" { print $2; exit }')"
echo "address	$(ifconfig ${WANIF} | awk '/inet6 / && $2 !~ /^fe80/ { print $2; exit }')"
if [ -f /var/run/rtsold.pid ] && pkill -0 -F /var/run/rtsold.pid 2>/dev/null; then echo "rtsold	yes"; else echo "rtsold	no"; fi
for R in $(cat /tmp/${WANIF}_routerv6 2>/dev/null) $(netstat -rn -f inet6 | awk '$1 == "default" { print $2; exit }'); do
    A=${R%%%*}
    if ping -6 -c 1 -t 2 "${A}%${WANIF}" >/dev/null 2>&1; then P=yes; else P=no; fi
    L=$(ndp -an | awk -v a="${A}%${WANIF}" '$1 == a && $2 !~ /incomplete/ { print $2; exit }')
    echo "neighbour	${A}	${P}	${L}"
done
echo "gateways	$(/usr/local/sbin/pluginctl -r return_gateways_status 2>/dev/null | tr -d '\n')"
"""

# A router solicitation and the advertisements that answer it (rtsol is the
# one-shot rtsold: it runs no script and changes nothing OPNsense keeps).
SOLICIT_SH = r"""
WANIF="%s"
OUT=$(mktemp /tmp/tappaas-ra.XXXXXX)
timeout 6 tcpdump -n -l -vv -i "${WANIF}" 'icmp6 and ip6[40] == 134' > "${OUT}" 2>/dev/null &
sleep 1
rtsol "${WANIF}" >/dev/null 2>&1
wait
cat "${OUT}"
rm -f "${OUT}"
"""


def bare(addr: str) -> str:
    """fe80::1%vtnet1 -> fe80::1 (the zone is the WAN's, always)."""
    return (addr or "").split("%", 1)[0].strip().lower()


@dataclass
class Neighbour:
    address: str
    answers: bool
    lladdr: str = ""


@dataclass
class WanState:
    wanif: str = ""
    recorded: str = ""        # /tmp/<wan>_routerv6: what OPNsense believes
    route: str = ""           # the kernel's IPv6 default route's gateway
    gateway: str = ""         # the WAN_DHCP6 gateway's address
    prefix: str = ""          # /tmp/<wan>_prefixv6: the delegated prefix
    address: str = ""         # the WAN's own global IPv6 address
    rtsold: bool = False
    neighbours: list[Neighbour] = field(default_factory=list)

    def neighbour(self, addr: str) -> Neighbour | None:
        a = bare(addr)
        return next((n for n in self.neighbours if n.address == a), None)

    def to_json(self) -> dict:
        d = asdict(self)
        d["routerAnswers"] = bool(self.route) and bool((self.neighbour(self.route) or Neighbour("", False)).answers)
        return d


def parse_wan(out: str) -> WanState:
    s = WanState()
    for line in out.splitlines():
        key, _, rest = line.partition("\t")
        if key == "wanif":
            s.wanif = rest.strip()
        elif key == "recorded":
            s.recorded = bare(rest)
        elif key == "route":
            s.route = bare(rest)
        elif key == "prefix":
            s.prefix = rest.strip()
        elif key == "address":
            s.address = rest.strip()
        elif key == "rtsold":
            s.rtsold = rest.strip() == "yes"
        elif key == "neighbour":
            f = rest.split("\t")
            a = bare(f[0])
            if a and not s.neighbour(a):
                s.neighbours.append(Neighbour(a, len(f) > 1 and f[1] == "yes", f[2].strip() if len(f) > 2 else ""))
        elif key == "gateways":
            try:
                gws = json.loads(rest or "{}").get("dpinger", {})
            except ValueError:
                gws = {}
            g = gws.get(GATEWAY_NAME) or next(
                (v for v in gws.values() if isinstance(v, dict) and v.get("ipprotocol") == "inet6"), {})
            s.gateway = bare(str(g.get("gateway", "")))
    return s


@dataclass
class Advert:
    router: str
    lifetime: int       # router lifetime in seconds; 0 = "not a default router"
    managed: bool = False


_RA = re.compile(r"\b(fe80::[0-9a-f:]+)\s+>\s+\S+:.*router advertisement", re.I)
_LIFE = re.compile(r"router lifetime (\d+)s")


def parse_adverts(out: str) -> list[Advert]:
    """tcpdump -vv lines: the sender on the header line, the flags on the next."""
    ads: list[Advert] = []
    cur: Advert | None = None
    for line in out.splitlines():
        m = _RA.search(line)
        if m:
            cur = Advert(bare(m.group(1)), -1)
            ads.append(cur)
            continue
        lm = _LIFE.search(line)
        if lm and cur is not None and cur.lifetime < 0:
            cur.lifetime = int(lm.group(1))
            cur.managed = "managed" in line
    seen: dict[str, Advert] = {}
    for a in ads:
        seen.setdefault(a.router, a)
    return list(seen.values())


@dataclass
class RelearnPlan:
    router: str = ""                  # the router that answers now ("" = none)
    steps: list[str] = field(default_factory=list)   # record, newipv6, rtsold
    problems: list[str] = field(default_factory=list)

    def describe(self, s: WanState) -> list[str]:
        out = []
        for st in self.steps:
            if st == "record":
                out.append(f"record the advertising router: ifctl -i {s.wanif} -6rd -a {self.router}")
            elif st == "newipv6":
                out.append(f"re-run the IPv6 WAN event: configctl interface newipv6 {s.wanif} force "
                           f"(default route and {GATEWAY_NAME} to {self.router}; the lease is kept)")
            elif st == "rtsold":
                out.append("start rtsold, which is not running (it solicits once; its script reloads dhcp6c)")
        return out


def relearn_plan(s: WanState, adverts: list[Advert]) -> RelearnPlan:
    """What re-learning would change (pure)."""
    p = RelearnPlan()
    if not s.wanif:
        p.problems.append("the firewall has no WAN interface assigned")
        return p
    routers = [a for a in adverts if a.lifetime != 0]
    if not routers:
        p.problems.append("no router answered a solicitation on the WAN — the ISP link, not the "
                          "firewall's record, is the problem")
        return p
    # The recorded router wins when it still advertises: nothing to re-learn.
    keep = next((a for a in routers if a.router == s.recorded), None)
    p.router = (keep or routers[0]).router
    if s.recorded != p.router:
        p.steps.append("record")
    if "record" in p.steps or s.route != p.router or s.gateway != p.router:
        p.steps.append("newipv6")
    if not s.rtsold:
        p.steps.append("rtsold")
    return p


def apply_script(s: WanState, p: RelearnPlan) -> str:
    """The firewall script that carries out a plan (steps in OPNsense's order)."""
    sh = ""
    if "record" in p.steps:
        sh += f"/usr/local/sbin/ifctl -i {s.wanif} -6rd -a {p.router}\n"
    if "newipv6" in p.steps:
        # configctl queues the event; rc.newwanipv6 takes its lock and runs it.
        sh += f"/usr/local/sbin/configctl interface newipv6 {s.wanif} force >/dev/null\n"
    if "rtsold" in p.steps:
        sh += f"rm -f /tmp/rtsold.{s.wanif}.done\n{RTSOLD_CMD}\n"
    return sh
