"""Unit tests for node_provisioner.util.derive_node_ip (#673).

The node number is a sequence: tappaasN gets <subnet>.<9+N> for any N, and the
addresses run out where the mgmt DHCP pool begins (.100) — not at a fixed count
of nodes. Mirrors cluster/config-network.sh node_mgmt_ip(), whose own test is
cluster/lib/test-node-mgmt-ip.sh.

Run with:
    cd src && python -m unittest test.test_util -v
"""

from __future__ import annotations

import unittest

from node_provisioner.util import derive_node_ip

MGMT = "10.0.0.144"  # the cicd's own address — only its subnet is used


class TestDeriveNodeIp(unittest.TestCase):
    def test_the_first_nodes(self):
        self.assertEqual(derive_node_ip("tappaas1", MGMT), "10.0.0.10")
        self.assertEqual(derive_node_ip("tappaas9", MGMT), "10.0.0.18")

    def test_beyond_the_old_ceiling_of_nine(self):
        self.assertEqual(derive_node_ip("tappaas10", MGMT), "10.0.0.19")
        self.assertEqual(derive_node_ip("tappaas42", MGMT), "10.0.0.51")

    def test_the_last_address_before_the_pool(self):
        self.assertEqual(derive_node_ip("tappaas90", MGMT), "10.0.0.99")

    def test_a_number_whose_address_is_in_the_pool(self):
        self.assertIsNone(derive_node_ip("tappaas91", MGMT))
        self.assertIsNone(derive_node_ip("tappaas1000", MGMT))

    def test_tappaas0_has_no_address_of_its_own(self):
        # .9 is not a node address; node numbering starts at 1.
        self.assertIsNone(derive_node_ip("tappaas0", MGMT))

    def test_a_name_that_is_not_a_node(self):
        for name in ("firewall", "tappaas", "tappaas1a", "dh-test1", "TAPPAAS1"):
            self.assertIsNone(derive_node_ip(name, MGMT), name)

    def test_the_subnet_comes_from_the_mgmt_address(self):
        self.assertEqual(derive_node_ip("tappaas2", "192.168.7.20"), "192.168.7.11")


if __name__ == "__main__":
    unittest.main()
