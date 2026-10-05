"""Exercise service outcomes with real Lua and isolated OS adapters."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LUA = os.environ.get("VPN_NFTSET_LUA") or shutil.which("lua") or shutil.which("luajit")
TELEGRAM_URL = "https://core.telegram.org/resources/cidr.txt"
DOMAIN_URL = "https://lists.example/domains.txt"

COMMAND_ADAPTER = r"""
import json, os, re, sys, time
from pathlib import Path

root = Path(os.environ["VPN_NFTSET_TEST_ROOT"])
name, args = Path(sys.argv[0]).name, sys.argv[1:]
config = json.loads((root / "config.json").read_text())

def record(action):
    with (root / "calls").open("a") as output:
        output.write(action + "\n")

if name == "uci":
    value = config["uci"].get(args[-1].split(".")[-1])
    if value is None:
        sys.exit(1)
    print(" ".join(value) if isinstance(value, list) else value)
elif name in ("curl", "uclient-fetch", "wget"):
    url = next(arg for arg in args if arg.startswith("https://"))
    record("download " + url)
    if name == "uclient-fetch" and "-t" in args:
        sys.exit(1)
    if config.get("block_url") == url:
        (root / "download.waiting").touch()
        deadline = time.monotonic() + 5
        while not (root / "download.release").exists():
            if time.monotonic() > deadline:
                sys.exit(28)
            time.sleep(0.01)
    response = config["downloads"].get(url)
    if response is None:
        sys.exit(22)
    flag = "-o" if name == "curl" else "-O"
    Path(args[args.index(flag) + 1]).write_text(response)
elif name == "nft":
    path = root / "nft.json"
    state = json.loads(path.read_text()) if path.exists() else {"table": False, "sets": {}}
    if args[:2] == ["list", "table"]:
        sys.exit(0 if state["table"] else 1)
    record("nft")
    if args[:2] == ["delete", "table"]:
        state = {"table": False, "sets": {}}
    elif args[:2] == ["add", "element"]:
        state["sets"][args[4]].append(args[5].strip("{} "))
    else:
        batch = Path(args[1]).read_text()
        if config.get("fail_apply") and batch.startswith("flush set"):
            sys.exit(1)
        for line in batch.splitlines():
            if line.startswith("delete table"):
                state = {"table": False, "sets": {}}
            elif line.startswith("add table"):
                state["table"] = True
            elif line.startswith(("add set", "flush set")):
                state["sets"][line.split()[4]] = []
            elif line.startswith("add element"):
                name, addresses = re.match(r"add element inet \S+ (\S+) \{ (.*) \}", line).groups()
                state["sets"][name] = addresses.split(", ")
    path.write_text(json.dumps(state))
elif name == "ip":
    record("ip")
    if args[:3] == ["-6", "addr", "show"]:
        print("inet6 2001:db8::2/64 scope global")
else:
    record(name)
    if name == "dnsmasq" and config.get("fail_dns"):
        sys.exit(1)
"""


@unittest.skipUnless(LUA, "Lua 5.1 or LuaJIT is required")
class ServiceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="vpn nftset service ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.bin, self.cache, self.runtime, self.dnsmasq = (
            self.directory / name for name in ("bin", "cache", "runtime", "dnsmasq.d")
        )
        for directory in (self.bin, self.cache, self.runtime, self.dnsmasq):
            directory.mkdir()
        adapter = self.bin / "adapter"
        adapter.write_text(f"#!{sys.executable}\n" + COMMAND_ADAPTER)
        adapter.chmod(0o755)
        for name in (
            "uci",
            "nft",
            "ip",
            "curl",
            "uclient-fetch",
            "wget",
            "dnsmasq",
            "cron",
            "background-refresh",
        ):
            (self.bin / name).symlink_to(adapter)
        # OpenWrt provides these tools, but does not provide cksum by default.
        for name in (
            "awk",
            "base64",
            "cat",
            "cmp",
            "cp",
            "date",
            "dirname",
            "find",
            "md5sum",
            "mkdir",
            "mktemp",
            "mv",
            "rm",
            "rmdir",
            "sh",
            "sleep",
            "sort",
        ):
            (self.bin / name).symlink_to(shutil.which(name))
        self.crontab, self.route_tables = (
            self.directory / "crontab",
            self.directory / "rt_tables",
        )
        self.crontab.write_text("0 1 * * * /usr/bin/another-job\n")
        self.route_tables.write_text("255 local\n254 main\n200 unrelated\n")
        self.config = {
            "uci": {
                "enabled": "1",
                "nftset_name": "TEST_SET",
                "interface": "wg0",
                "telegram_enabled": "1",
                "auto_update": "0",
                "domains": ["custom.example"],
                "dns_servers": ["8.8.8.8"],
                "ip_addresses": ["8.8.8.8", "2001:db8::1"],
                "gfwlist_urls": [],
                "domainslist_urls": [],
            },
            "downloads": {TELEGRAM_URL: "149.154.160.0/20\n2001:b28:f23d::/48\n"},
        }
        self.env = dict(os.environ)
        self.env.update(
            PATH=str(self.bin),
            LUA_PATH=str(ROOT / "files/root/usr/lib/lua/?.lua") + ";;",
            VPN_NFTSET_TEST_ROOT=str(self.directory),
            VPN_NFTSET_DNSMASQ_DIR=str(self.dnsmasq),
            VPN_NFTSET_CACHE_DIR=str(self.cache),
            VPN_NFTSET_RUNTIME_DIR=str(self.runtime),
            VPN_NFTSET_CRONTAB_FILE=str(self.crontab),
            VPN_NFTSET_ROUTETABLE_FILE=str(self.route_tables),
            VPN_NFTSET_DNSMASQ_SERVICE=str(self.bin / "dnsmasq"),
            VPN_NFTSET_CRON_SERVICE=str(self.bin / "cron"),
            VPN_NFTSET_UPDATER=str(self.bin / "background-refresh"),
            VPN_NFTSET_GENERATOR=str(
                ROOT / "files/root/usr/bin/vpn-nftset-rulegenerator"
            ),
            VPN_NFTSET_DATA_TOOL=str(ROOT / "files/root/usr/bin/vpn-nftset-data"),
            VPN_NFTSET_LUA=LUA,
            VPN_NFTSET_TELEGRAM_SEED=str(
                ROOT / "files/root/usr/share/vpn-nftset/telegram-cidr.txt"
            ),
            VPN_NFTSET_SERVICE_SOURCE=str(ROOT / "files/root/etc/init.d/vpn-nftset"),
        )

    def arguments(self, command):
        pending = self.directory / "config.new"
        pending.write_text(json.dumps(self.config))
        pending.replace(self.directory / "config.json")
        return [
            "sh",
            "-c",
            '. "$VPN_NFTSET_SERVICE_SOURCE"; "$1"',
            "service-test",
            command,
        ]

    def run_service(self, command, expected=0):
        result = subprocess.run(
            self.arguments(command),
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def launch(self, command):
        process = subprocess.Popen(
            self.arguments(command),
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.close_process, process)
        return process

    def close_process(self, process):
        (self.directory / "download.release").touch()
        if process.poll() is None:
            process.terminate()
        process.communicate(timeout=5)

    def wait_for_file(self, path):
        deadline = time.monotonic() + 4
        while not path.exists():
            self.assertLess(
                time.monotonic(), deadline, f"Timed out waiting for {path.name}"
            )
            time.sleep(0.01)

    def calls(self):
        path = self.directory / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def nft_state(self):
        return json.loads((self.directory / "nft.json").read_text())

    def prime_telegram_cache(self):
        self.run_service("start")
        self.run_service("update")

    def test_boot_uses_offline_cache_seed_and_daily_update_job(self):
        source_id = hashlib.md5(DOMAIN_URL.encode()).hexdigest()
        (self.cache / f"{source_id}.domains").write_text("downloaded.example\n")
        self.config["uci"].update(domainslist_urls=[DOMAIN_URL], auto_update="1")
        self.run_service("start")
        self.assertIn(
            "downloaded.example",
            (self.dnsmasq / "vpn-nftset-generated.conf").read_text(),
        )
        self.assertIn("91.108.4.0/22", self.nft_state()["sets"]["TEST_SET_telegram_v4"])
        self.assertFalse(any(call.startswith("download ") for call in self.calls()))
        self.assertIn("4 4 * * * /usr/bin/vpn-nftset-update", self.crontab.read_text())
        self.assertIn("another-job", self.crontab.read_text())
        self.assertIn("201 vpnnftset_wg0", self.route_tables.read_text())

    def test_telegram_refresh_and_cached_boot_keep_manual_addresses(self):
        self.prime_telegram_cache()
        self.config["downloads"][TELEGRAM_URL] = "91.108.4.0/22\n2a0a:f280::/32\n"
        self.run_service("update")
        sets = self.nft_state()["sets"]
        self.assertEqual(sets["TEST_SET_telegram_v4"], ["91.108.4.0/22"])
        self.assertEqual(sets["TEST_SET_telegram_v6"], ["2a0a:f280::/32"])
        self.assertEqual(sets["TEST_SET_v4"], ["8.8.8.8"])
        self.assertEqual(sets["TEST_SET_v6"], ["2001:db8::1"])
        self.config["downloads"] = {}
        self.run_service("start")
        self.assertEqual(self.nft_state()["sets"], sets)

    def test_download_failure_keeps_telegram_cache_and_active_rules(self):
        self.prime_telegram_cache()
        cache, state = (self.cache / "telegram.cidr").read_bytes(), self.nft_state()
        self.config["downloads"] = {}
        self.run_service("update", expected=1)
        self.assertEqual((self.cache / "telegram.cidr").read_bytes(), cache)
        self.assertEqual(self.nft_state(), state)

    def test_invalid_download_keeps_telegram_cache_and_active_rules(self):
        self.prime_telegram_cache()
        cache, state = (self.cache / "telegram.cidr").read_bytes(), self.nft_state()
        self.config["downloads"][TELEGRAM_URL] = "91.108.4.0/22\ninvalid CIDR\n"
        self.run_service("update", expected=1)
        self.assertEqual((self.cache / "telegram.cidr").read_bytes(), cache)
        self.assertEqual(self.nft_state(), state)

    def test_failed_nft_apply_keeps_telegram_cache_and_active_rules(self):
        self.prime_telegram_cache()
        cache, state = (self.cache / "telegram.cidr").read_bytes(), self.nft_state()
        self.config["downloads"][TELEGRAM_URL] = "91.108.4.0/22\n"
        self.config["fail_apply"] = True
        self.run_service("update", expected=1)
        self.assertEqual((self.cache / "telegram.cidr").read_bytes(), cache)
        self.assertEqual(self.nft_state(), state)

    def test_disabling_telegram_clears_only_its_sets(self):
        self.prime_telegram_cache()
        cache = (self.cache / "telegram.cidr").read_bytes()
        self.config["uci"]["telegram_enabled"] = "0"
        self.run_service("update")
        sets = self.nft_state()["sets"]
        self.assertEqual(sets["TEST_SET_telegram_v4"], [])
        self.assertEqual(sets["TEST_SET_telegram_v6"], [])
        self.assertEqual(sets["TEST_SET_v4"], ["8.8.8.8"])
        self.assertEqual((self.cache / "telegram.cidr").read_bytes(), cache)

    def test_domain_changes_reload_dns_and_identical_data_does_not(self):
        self.config["uci"]["domainslist_urls"] = [DOMAIN_URL]
        self.config["downloads"][DOMAIN_URL] = "one.example\n"
        self.run_service("start")
        self.run_service("update")
        restarts = self.calls().count("dnsmasq")
        self.assertEqual(restarts, 2)
        self.run_service("update")
        self.assertEqual(self.calls().count("dnsmasq"), restarts)
        self.config["downloads"][DOMAIN_URL] = "two.example\n"
        self.run_service("update")
        self.assertEqual(self.calls().count("dnsmasq"), restarts + 1)
        self.assertIn(
            "two.example", (self.dnsmasq / "vpn-nftset-generated.conf").read_text()
        )

    def test_failed_dns_restart_retries_identical_domain_data(self):
        self.config["uci"]["domainslist_urls"] = [DOMAIN_URL]
        self.config["downloads"][DOMAIN_URL] = "downloaded.example\n"
        self.run_service("start")
        self.config["fail_dns"] = True
        self.run_service("update", expected=1)
        restarts = self.calls().count("dnsmasq")
        self.config["fail_dns"] = False
        self.run_service("update")
        self.assertEqual(self.calls().count("dnsmasq"), restarts + 1)

    def test_failed_stop_retries_dns_after_configuration_is_removed(self):
        self.run_service("start")
        self.config["fail_dns"] = True
        self.run_service("stop", expected=1)
        self.assertEqual(list(self.dnsmasq.glob("vpn-nftset-*.conf")), [])
        restarts = self.calls().count("dnsmasq")
        self.config["fail_dns"] = False
        self.run_service("stop")
        self.assertEqual(self.calls().count("dnsmasq"), restarts + 1)

    def test_queued_update_after_stop_has_no_effect(self):
        self.prime_telegram_cache()
        cache = (self.cache / "telegram.cidr").read_bytes()
        (self.dnsmasq / "unrelated.conf").write_text("local=/lan/\n")
        self.run_service("stop")
        calls = self.calls()
        self.run_service("update", expected=1)
        self.assertEqual(self.calls(), calls)
        self.assertFalse(self.nft_state()["table"])
        self.assertEqual(list(self.dnsmasq.glob("vpn-nftset-*.conf")), [])
        self.assertEqual((self.cache / "telegram.cidr").read_bytes(), cache)
        self.assertTrue((self.dnsmasq / "unrelated.conf").exists())
        self.assertIn("200 unrelated", self.route_tables.read_text())

    def test_stop_cancels_domain_download_before_it_can_restore_rules(self):
        source_id = hashlib.md5(DOMAIN_URL.encode()).hexdigest()
        cached = self.cache / f"{source_id}.domains"
        cached.write_text("previous.example\n")
        self.config["uci"]["domainslist_urls"] = [DOMAIN_URL]
        self.config["downloads"][DOMAIN_URL] = "new.example\n"
        self.config["block_url"] = DOMAIN_URL
        self.run_service("start")
        update = self.launch("update")
        self.wait_for_file(self.directory / "download.waiting")
        self.run_service("update", expected=1)
        stop = self.launch("stop")
        self.wait_for_file(self.runtime / "cancel-update")
        (self.directory / "download.release").touch()
        update.communicate(timeout=5)
        stdout, stderr = stop.communicate(timeout=5)
        self.assertEqual(update.returncode, 1)
        self.assertEqual(stop.returncode, 0, stdout + stderr)
        self.assertEqual(cached.read_text(), "previous.example\n")
        self.assertFalse(self.nft_state()["table"])
        self.assertEqual(list(self.dnsmasq.glob("vpn-nftset-*.conf")), [])

    def test_telegram_download_works_with_default_uclient_fetch(self):
        (self.bin / "curl").unlink()
        (self.bin / "wget").unlink()
        self.prime_telegram_cache()
        self.assertEqual(
            (self.cache / "telegram.cidr").read_text(),
            "149.154.160.0/20\n2001:b28:f23d::/48\n",
        )


if __name__ == "__main__":
    unittest.main()
