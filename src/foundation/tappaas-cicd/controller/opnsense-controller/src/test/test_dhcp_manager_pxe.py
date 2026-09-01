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

import subprocess
import unittest
from unittest.mock import MagicMock, patch

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


class TestSetOption(unittest.TestCase):
    """create_set_option — explicit dhcp-option 66/67 (#546)."""

    def test_set_option_payload(self):
        manager = _make_manager()
        manager.create_set_option(
            option="66", value="10.4.0.10",
            description="iotLocal option66", interface="opt1",
            reconfigure=False,
        )
        (add,) = _calls(manager, "addOption")
        opt = add["data"]["option"]
        self.assertEqual(opt["type"], "set")
        self.assertEqual(opt["option"], "66")
        self.assertEqual(opt["value"], "10.4.0.10")
        self.assertEqual(opt["interface"], "opt1")
        # not applied when reconfigure=False
        self.assertEqual(_calls(manager, "reconfigure"), [])

    def test_set_option_idempotent_replaces(self):
        manager = _make_manager(option_rows=[
            {"uuid": "old-66", "description": "iotLocal option66"},
        ])
        manager.create_set_option(
            option="66", value="10.4.0.10",
            description="iotLocal option66", reconfigure=False,
        )
        (delete,) = _calls(manager, "delOption")
        self.assertEqual(delete["params"], ["old-66"])
        self.assertEqual(len(_calls(manager, "addOption")), 1)

    def test_set_option_no_interface_omits_field(self):
        manager = _make_manager()
        manager.create_set_option(
            option="67", value="pxelinux.0",
            description="iotLocal option67", reconfigure=False,
        )
        (add,) = _calls(manager, "addOption")
        self.assertNotIn("interface", add["data"]["option"])

    def test_set_option_failure_raises(self):
        manager = _make_manager(fail_add_option=True)
        with self.assertRaises(RuntimeError):
            manager.create_set_option(
                option="66", value="x", description="iotLocal option66",
                reconfigure=False,
            )


def _fake_fw(responses=None):
    """A _fw_sh replacement recording scripts, answering by content."""
    scripts = []

    def fw_sh(config, script):
        scripts.append(script)
        stdout = ""
        if "pluginctl" in script:
            stdout = "vtnet0\n"
        elif "rm -f" in script:
            stdout = (responses or {}).get("rm", "removed\n")
        elif "cat " in script and "TAPPAAS_EOF" not in script:
            stdout = (responses or {}).get("cat", "")
        return subprocess.CompletedProcess(
            args=["ssh"], returncode=0, stdout=stdout, stderr="")

    return fw_sh, scripts


class TestRenderConf(unittest.TestCase):
    def test_negated_tag_and_chainload(self):
        conf = dhcp_manager_cli._render_conf(
            "vtnet0", "10.0.0.10", "snp.efi",
            "http://10.0.0.10:8090/boot.ipxe")
        self.assertIn("dhcp-match=set:tappaas-ipxe,175", conf)
        # The loop-breaker: non-iPXE clients only, servername AND address.
        self.assertIn("dhcp-boot=tag:vtnet0,tag:!tappaas-ipxe,"
                      "snp.efi,10.0.0.10,10.0.0.10", conf)
        self.assertIn("dhcp-boot=tag:vtnet0,tag:tappaas-ipxe,"
                      "http://10.0.0.10:8090/boot.ipxe", conf)

    def test_no_chainload_line_without_url(self):
        conf = dhcp_manager_cli._render_conf(
            "vtnet0", "10.0.0.10", "snp.efi", None)
        self.assertNotIn("tag:tappaas-ipxe,http", conf)


class TestPxeCliFlows(unittest.TestCase):
    def test_enable_writes_drop_in(self):
        manager = _make_manager()
        fw_sh, scripts = _fake_fw()
        with patch.object(dhcp_manager_cli, "_fw_sh", fw_sh):
            ok = dhcp_manager_cli.pxe_enable(
                manager, MagicMock(), zone="mgmt", interface="lan",
                next_server="10.0.0.10", bootfile="snp.efi",
                ipxe_script_url="http://10.0.0.10:8090/boot.ipxe",
            )
        self.assertTrue(ok)
        deploy = [s for s in scripts if "TAPPAAS_EOF" in s]
        self.assertEqual(len(deploy), 1)
        self.assertIn("tag:!tappaas-ipxe", deploy[0])
        self.assertIn("configctl dnsmasq restart", deploy[0])
        # No legacy entries -> no API reconfigure needed.
        self.assertEqual(_calls(manager, "reconfigure"), [])

    def test_enable_migrates_legacy_api_entries(self):
        manager = _make_manager(
            boot_rows=[{"uuid": "b1",
                        "description": "TAPPaaS PXE boot (mgmt)"}],
            tag_rows=[{"uuid": "t1", "tag": "tappaas_ipxe"}],
        )
        fw_sh, _ = _fake_fw()
        with patch.object(dhcp_manager_cli, "_fw_sh", fw_sh):
            ok = dhcp_manager_cli.pxe_enable(
                manager, MagicMock(), zone="mgmt", interface="lan",
                next_server="10.0.0.10", bootfile="snp.efi",
                ipxe_script_url=None,
            )
        self.assertTrue(ok)
        self.assertEqual(len(_calls(manager, "delBoot")), 1)
        self.assertEqual(len(_calls(manager, "delTag")), 1)
        self.assertEqual(len(_calls(manager, "reconfigure")), 1)

    def test_disable_removes_drop_in(self):
        manager = _make_manager()
        fw_sh, scripts = _fake_fw()
        with patch.object(dhcp_manager_cli, "_fw_sh", fw_sh):
            ok = dhcp_manager_cli.pxe_disable(manager, MagicMock(), "mgmt")
        self.assertTrue(ok)
        self.assertTrue(any("rm -f" in s for s in scripts))
        self.assertEqual(_calls(manager, "reconfigure"), [])

    def test_status_reads_drop_in(self):
        manager = _make_manager()
        fw_sh, _ = _fake_fw(responses={
            "cat": "dhcp-match=set:tappaas-ipxe,175\n"})
        with patch.object(dhcp_manager_cli, "_fw_sh", fw_sh):
            self.assertTrue(
                dhcp_manager_cli.pxe_status(manager, MagicMock(), "mgmt"))

    def test_status_disabled_when_absent(self):
        manager = _make_manager()
        fw_sh, _ = _fake_fw(responses={"cat": ""})
        with patch.object(dhcp_manager_cli, "_fw_sh", fw_sh):
            self.assertFalse(
                dhcp_manager_cli.pxe_status(manager, MagicMock(), "mgmt"))


class TestHostPinning(unittest.TestCase):
    """pin_host_macs: raw setHost/addHost (the ansible dnsmasq_host module
    silently drops hwaddr — stage-1 finding)."""

    def _manager(self, host_rows):
        manager = _make_manager()

        def run_module(module, **kwargs):
            params = kwargs.get("params", {})
            command = params.get("command")
            if command == "searchHost":
                return _rows(host_rows)
            if command in ("setHost", "addHost"):
                return {"result": {"response": {"result": "saved",
                                                "uuid": "host-uuid"}}}
            if command == "reconfigure":
                return {"result": {"response": {"status": "ok"}}}
            return {"result": {"response": {}}}

        manager._client.run_module.side_effect = run_module
        return manager

    def test_pin_updates_shipped_entry_in_place(self):
        # The firewall SHIPS tappaas1-9 host entries (DNS pin, no MAC).
        manager = self._manager([
            {"uuid": "u4", "host": "tappaas4", "domain": "mgmt.internal",
             "ip": "10.0.0.13", "hwaddr": "", "descr": ""},
        ])
        manager.pin_host_macs("tappaas4", "10.0.0.13",
                              ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"],
                              domain="mgmt.internal")
        (set_call,) = _calls(manager, "setHost")
        self.assertEqual(set_call["params"], ["u4"])
        host = set_call["data"]["host"]
        self.assertEqual(host["hwaddr"],
                         "aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02")
        self.assertEqual(host["ip"], "10.0.0.13")
        self.assertEqual(len(_calls(manager, "reconfigure")), 1)

    def test_pin_creates_when_missing(self):
        manager = self._manager([])
        manager.pin_host_macs("tappaas7", "10.0.0.16", ["aa:bb:cc:dd:ee:07"],
                              domain="mgmt.internal")
        (add_call,) = _calls(manager, "addHost")
        self.assertEqual(add_call["data"]["host"]["host"], "tappaas7")

    def test_clear_pinning_keeps_entry(self):
        manager = self._manager([
            {"uuid": "u9", "host": "tappaas9", "domain": "mgmt.internal",
             "ip": "10.0.0.18", "hwaddr": "aa:bb:cc:dd:ee:09", "descr": "x"},
        ])
        ok = dhcp_manager_cli.host_del(manager, "tappaas9", "mgmt.internal")
        self.assertTrue(ok)
        (set_call,) = _calls(manager, "setHost")
        self.assertEqual(set_call["data"]["host"]["hwaddr"], "")
        self.assertEqual(set_call["data"]["host"]["ip"], "10.0.0.18")


if __name__ == "__main__":
    unittest.main()
