"""Unit tests for the DhcpManager PXE boot-option methods (design N3).

Asserts — without an OPNsense connection — that the dhcp_boot payloads
carry filename/address/interface/tag through to the raw API, that
set_boot_entry is idempotent (existing entry with the same description is
deleted first), that failures are surfaced, and that the dhcp-manager CLI
verbs stage everything and reconfigure exactly once.

Run with:
    cd src && python -m unittest test.test_dhcp_manager_pxe -v
"""

from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from opnsense_controller.dhcp_manager import DhcpManager
from opnsense_controller import dhcp_manager_cli


def _rows(rows):
    return {"result": {"response": {"rows": rows}}}


def _make_manager(boot_rows=None, tag_rows=None, option_rows=None,
                  fail_add_option=False):
    """DhcpManager wired to a fake client routing raw commands by name."""
    boot_rows = list(boot_rows or [])
    tag_rows = list(tag_rows or [])
    option_rows = list(option_rows or [])

    def run_module(module, **kwargs):
        params = kwargs.get("params", {})
        command = params.get("command")
        if command == "searchBoot":
            return _rows(boot_rows)
        if command == "searchTag":
            return _rows(tag_rows)
        if command == "searchOption":
            return _rows(option_rows)
        if command == "addBoot":
            return {"result": {"response": {"result": "saved", "uuid": "boot-uuid"}}}
        if command == "addTag":
            return {"result": {"response": {"result": "saved", "uuid": "tag-uuid"}}}
        if command == "addOption":
            if fail_add_option:
                return {"result": {"response": {"result": "failed",
                                                "validations": {"option": "bad"}}}}
            return {"result": {"response": {"result": "saved", "uuid": "opt-uuid"}}}
        if command in ("delBoot", "delTag", "delOption"):
            return {"result": {"response": {"result": "deleted"}}}
        if command == "reconfigure":
            return {"result": {"response": {"status": "ok"}}}
        return {"result": {"response": {}}}

    manager = DhcpManager(config=MagicMock())
    manager._client = MagicMock()
    manager._client.run_module.side_effect = run_module
    return manager


def _calls(manager, command):
    """All raw-call param dicts for a given API command."""
    out = []
    for call in manager.client.run_module.call_args_list:
        params = call.kwargs.get("params") or (
            call.args[1] if len(call.args) > 1 else {})
        if isinstance(params, dict) and params.get("command") == command:
            out.append(params)
    return out


class TestSetBootEntry(unittest.TestCase):
    def test_payload_carries_all_fields(self):
        manager = _make_manager()
        result = manager.set_boot_entry(
            filename="ipxe.efi",
            description="TAPPaaS PXE boot (mgmt)",
            address="10.0.0.10",
            interface="lan",
        )
        self.assertTrue(result["changed"])
        (add,) = _calls(manager, "addBoot")
        boot = add["data"]["boot"]
        self.assertEqual(boot["filename"], "ipxe.efi")
        self.assertEqual(boot["address"], "10.0.0.10")
        self.assertEqual(boot["interface"], "lan")
        self.assertEqual(boot["description"], "TAPPaaS PXE boot (mgmt)")
        # applied immediately by default
        self.assertEqual(len(_calls(manager, "reconfigure")), 1)

    def test_idempotent_replaces_existing_entry(self):
        manager = _make_manager(boot_rows=[
            {"uuid": "old-uuid", "description": "TAPPaaS PXE boot (mgmt)",
             "filename": "old.efi"},
        ])
        manager.set_boot_entry(
            filename="ipxe.efi",
            description="TAPPaaS PXE boot (mgmt)",
            address="10.0.0.10",
        )
        (delete,) = _calls(manager, "delBoot")
        self.assertEqual(delete["params"], ["old-uuid"])
        self.assertEqual(len(_calls(manager, "addBoot")), 1)

    def test_tagged_entry_for_ipxe_chain(self):
        manager = _make_manager()
        manager.set_boot_entry(
            filename="http://10.0.0.10:8090/boot.ipxe",
            description="TAPPaaS PXE ipxe-chain (mgmt)",
            interface="lan",
            tag="tag-uuid",
            reconfigure=False,
        )
        (add,) = _calls(manager, "addBoot")
        self.assertEqual(add["data"]["boot"]["tag"], "tag-uuid")
        self.assertEqual(_calls(manager, "reconfigure"), [])

    def test_add_failure_raises(self):
        manager = _make_manager()

        def failing(module, **kwargs):
            params = kwargs.get("params", {})
            if params.get("command") == "addBoot":
                return {"result": {"response": {"result": "failed"}}}
            if params.get("command") == "searchBoot":
                return _rows([])
            return {"result": {"response": {}}}

        manager._client.run_module.side_effect = failing
        with self.assertRaises(RuntimeError):
            manager.set_boot_entry(filename="ipxe.efi", description="x")


class TestDeleteBootEntry(unittest.TestCase):
    def test_delete_missing_is_noop(self):
        manager = _make_manager()
        result = manager.delete_boot_entry("nope")
        self.assertFalse(result["changed"])
        self.assertEqual(_calls(manager, "delBoot"), [])

    def test_delete_existing(self):
        manager = _make_manager(boot_rows=[
            {"uuid": "u1", "description": "TAPPaaS PXE boot (mgmt)"},
        ])
        result = manager.delete_boot_entry("TAPPaaS PXE boot (mgmt)")
        self.assertTrue(result["changed"])
        (delete,) = _calls(manager, "delBoot")
        self.assertEqual(delete["params"], ["u1"])


class TestTagsAndMatchOptions(unittest.TestCase):
    def test_ensure_tag_creates_when_missing(self):
        manager = _make_manager()
        uuid = manager.ensure_dhcp_tag("tappaas_ipxe")
        self.assertEqual(uuid, "tag-uuid")
        (add,) = _calls(manager, "addTag")
        self.assertEqual(add["data"]["tag"]["tag"], "tappaas_ipxe")

    def test_ensure_tag_reuses_existing(self):
        manager = _make_manager(tag_rows=[{"uuid": "have", "tag": "tappaas_ipxe"}])
        self.assertEqual(manager.ensure_dhcp_tag("tappaas_ipxe"), "have")
        self.assertEqual(_calls(manager, "addTag"), [])

    def test_match_option_payload(self):
        manager = _make_manager()
        manager.create_match_option(
            option="175", set_tag="tag-uuid",
            description="TAPPaaS PXE ipxe-match (mgmt)", reconfigure=False,
        )
        (add,) = _calls(manager, "addOption")
        opt = add["data"]["option"]
        self.assertEqual(opt["type"], "match")
        self.assertEqual(opt["option"], "175")
        self.assertEqual(opt["set_tag"], "tag-uuid")


class TestPxeCliFlows(unittest.TestCase):
    def test_enable_stages_then_reconfigures_once(self):
        manager = _make_manager()
        ok = dhcp_manager_cli.pxe_enable(
            manager, zone="mgmt", interface="lan",
            next_server="10.0.0.10", bootfile="ipxe.efi",
            ipxe_script_url="http://10.0.0.10:8090/boot.ipxe",
        )
        self.assertTrue(ok)
        adds = _calls(manager, "addBoot")
        self.assertEqual(len(adds), 2)  # chain entry + plain entry
        self.assertEqual(len(_calls(manager, "reconfigure")), 1)

    def test_enable_degrades_when_match_option_rejected(self):
        # V-2: option "175" may be rejected by the firewall's option
        # catalogue — enable must fall back to the plain entry.
        manager = _make_manager(fail_add_option=True)
        ok = dhcp_manager_cli.pxe_enable(
            manager, zone="mgmt", interface="lan",
            next_server="10.0.0.10", bootfile="ipxe.efi",
            ipxe_script_url="http://10.0.0.10:8090/boot.ipxe",
        )
        self.assertTrue(ok)
        adds = _calls(manager, "addBoot")
        self.assertEqual(len(adds), 1)  # only the plain entry
        self.assertEqual(adds[0]["data"]["boot"]["filename"], "ipxe.efi")

    def test_disable_clears_everything(self):
        manager = _make_manager(
            boot_rows=[
                {"uuid": "b1", "description": "TAPPaaS PXE boot (mgmt)"},
                {"uuid": "b2", "description": "TAPPaaS PXE ipxe-chain (mgmt)"},
            ],
            tag_rows=[{"uuid": "t1", "tag": "tappaas_ipxe"}],
            option_rows=[{"uuid": "o1",
                          "description": "TAPPaaS PXE ipxe-match (mgmt)"}],
        )
        ok = dhcp_manager_cli.pxe_disable(manager, "mgmt")
        self.assertTrue(ok)
        self.assertEqual(len(_calls(manager, "delBoot")), 2)
        self.assertEqual(len(_calls(manager, "delOption")), 1)
        self.assertEqual(len(_calls(manager, "delTag")), 1)
        self.assertEqual(len(_calls(manager, "reconfigure")), 1)

    def test_disable_noop_when_nothing_set(self):
        manager = _make_manager()
        ok = dhcp_manager_cli.pxe_disable(manager, "mgmt")
        self.assertTrue(ok)
        self.assertEqual(_calls(manager, "reconfigure"), [])


if __name__ == "__main__":
    unittest.main()
