import base64
import hashlib
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "files/root/usr/bin/vpn-nftset-rulegenerator"
DATA_TOOL = ROOT / "files/root/usr/bin/vpn-nftset-data"
LUA = os.environ.get("VPN_NFTSET_LUA") or shutil.which("lua") or shutil.which("luajit")
NFTSETS = "4#inet#vpnnftset_fw#VPN_v4,6#inet#vpnnftset_fw#VPN_v6"


@unittest.skipUnless(LUA, "Lua 5.1 or LuaJIT is required")
class RuleGeneratorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vpn-nftset-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.cache = self.home / "cache"
        self.runtime = self.home / "runtime"
        self.conf = self.home / "dnsmasq"
        for directory in (self.cache, self.runtime, self.conf):
            directory.mkdir()
        self.responses = {}
        self.requests = []
        self.slow_started = threading.Event()
        self.slow_release = threading.Event()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append(self.path)
                if self.path == "/slow":
                    owner.slow_started.set()
                    owner.slow_release.wait(10)
                code, content = owner.responses.get(self.path, (404, b"missing"))
                self.send_response(code)
                self.end_headers()
                self.wfile.write(content)

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.restart_log = self.home / "restarts"
        restart = self.home / "dnsmasq-init"
        restart.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$1" >> "$VPN_NFTSET_RESTART_LOG"\n'
        )
        restart.chmod(0o755)
        self.env = dict(
            os.environ,
            VPN_NFTSET_LUA=LUA,
            VPN_NFTSET_DATA=str(DATA_TOOL),
            LUA_PATH=str(ROOT / "files/root/usr/lib/lua/?.lua") + ";;",
            VPN_NFTSET_DNSMASQ_INIT=str(restart),
            VPN_NFTSET_RESTART_LOG=str(self.restart_log),
        )

    def stop_server(self):
        self.slow_release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(3)

    def url(self, path):
        return "http://127.0.0.1:%s%s" % (self.server.server_port, path)

    def source_id(self, path):
        return hashlib.md5(self.url(path).encode()).hexdigest()

    def command(self, *args, restart=False):
        command = [
            "sh",
            str(GENERATOR),
            "-d",
            str(self.conf),
            "-c",
            str(self.cache),
            "-r",
            str(self.runtime),
            "-i",
            NFTSETS,
        ]
        if not restart:
            command.append("-n")
        return command + list(args)

    def run_generator(self, *args, code=0, restart=False):
        result = subprocess.run(
            self.command(*args, restart=restart),
            env=self.env,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def generated(self):
        return (self.conf / "vpn-nftset-generated.conf").read_text()

    def test_plain_and_gfw_sources_produce_unique_cached_rules(self):
        self.responses["/plain"] = (
            200,
            b" B.Example.com\r\nexample.com\nexample.com.\ns3-ap-*.amazonaws.com\n",
        )
        self.responses["/gfw"] = (
            200,
            base64.b64encode(
                b"[AutoProxy]\n||example.com\n|https://avatars.githubusercontent.com/image.png\n@@||exception.example\n"
            ),
        )
        self.run_generator(
            "-u",
            self.url("/plain"),
            "-w",
            self.url("/gfw"),
            "-s",
            "8.8.8.8",
            "-s",
            "::1#5353",
        )
        self.assertEqual(
            (self.cache / (self.source_id("/plain") + ".domains")).read_text(),
            "b.example.com\nexample.com\n",
        )
        self.assertEqual(
            (self.cache / (self.source_id("/gfw") + ".domains")).read_text(),
            "avatars.githubusercontent.com\nexample.com\n",
        )
        self.assertEqual(self.generated().count("nftset=/example.com/"), 1)
        self.assertIn(
            "server=/avatars.githubusercontent.com/::1#5353\n", self.generated()
        )
        self.assertEqual(
            (self.runtime / (self.source_id("/plain") + ".status")).read_text(), "ok\n"
        )
        self.assertGreater(
            int((self.cache / (self.source_id("/plain") + ".success")).read_text()), 0
        )

    def test_custom_dns_override_keeps_child_and_unrelated_domains(self):
        self.responses["/plain"] = (
            200,
            b"example.com\nsub.example.com\nnotexample.com\n",
        )
        (self.conf / "vpn-nftset-domains.conf").write_text(
            "server=/example.com/9.9.9.9\nnftset=/example.com/" + NFTSETS + "\n"
        )
        self.run_generator("-u", self.url("/plain"), "-s", "8.8.8.8")
        self.assertNotIn("server=/example.com/", self.generated())
        self.assertIn("server=/sub.example.com/8.8.8.8\n", self.generated())
        self.assertIn("nftset=/notexample.com/", self.generated())
        self.assertIn(
            "example.com\n",
            (self.cache / (self.source_id("/plain") + ".domains")).read_text(),
        )

    def test_unchanged_list_does_not_reload_dnsmasq(self):
        self.responses["/plain"] = (200, b"example.com\n")
        self.run_generator("-u", self.url("/plain"), restart=True)
        self.run_generator("-u", self.url("/plain"), restart=True)
        self.assertEqual(self.restart_log.read_text(), "restart\n")

    def test_failed_updates_keep_previous_cache_and_rules(self):
        self.responses["/plain"] = (200, b"stable.example\n")
        self.run_generator("-u", self.url("/plain"), "-s", "8.8.8.8")
        previous = self.generated()
        cache = self.cache / (self.source_id("/plain") + ".domains")
        cached = cache.read_bytes()
        for response, status in [
            ((503, b"Unavailable"), "download_failed"),
            ((200, b"<html>Error</html>"), "invalid_data"),
            ((200, b"good.example\nnot a domain\n"), "invalid_data"),
            ((200, b"s3-ap-*.amazonaws.com\n"), "invalid_data"),
        ]:
            with self.subTest(status=status, content=response[1]):
                self.responses["/plain"] = response
                self.run_generator("-u", self.url("/plain"), "-s", "8.8.8.8", code=1)
                self.assertEqual(self.generated(), previous)
                self.assertEqual(cache.read_bytes(), cached)
                self.assertEqual(
                    (self.runtime / (self.source_id("/plain") + ".status")).read_text(),
                    status + "\n",
                )

    def test_invalid_base64_cannot_replace_successful_gfw_cache(self):
        self.responses["/gfw"] = (200, base64.b64encode(b"||stable.example\n"))
        self.run_generator("-w", self.url("/gfw"))
        previous = self.generated()
        self.responses["/gfw"] = (200, b"%%%invalid-base64")
        self.run_generator("-w", self.url("/gfw"), code=1)
        self.assertEqual(self.generated(), previous)
        self.assertEqual(
            (self.runtime / (self.source_id("/gfw") + ".status")).read_text(),
            "invalid_data\n",
        )

    def test_offline_reboot_restores_persistent_cache_without_network(self):
        self.responses["/plain"] = (200, b"stable.example\n")
        self.run_generator("-u", self.url("/plain"))
        previous = self.generated()
        shutil.rmtree(self.runtime)
        shutil.rmtree(self.conf)
        self.responses["/plain"] = (503, b"offline")
        before_requests = len(self.requests)
        self.run_generator("-u", self.url("/plain"), "-o")
        self.assertEqual(self.generated(), previous)
        self.assertEqual(len(self.requests), before_requests)

    def test_withdrawn_sources_and_legacy_generated_files_stop_applying(self):
        self.responses["/one"] = (200, b"one.example\n")
        self.responses["/two"] = (200, b"two.example\n")
        self.run_generator("-u", self.url("/one"), "-u", self.url("/two"))
        legacy = self.conf / "vpn-nftset-gen_old.conf"
        legacy.write_text("nftset=/legacy.example/" + NFTSETS + "\n")
        self.run_generator("-u", self.url("/one"), "-o")
        self.assertIn("one.example", self.generated())
        self.assertNotIn("two.example", self.generated())
        self.assertFalse(legacy.exists())
        self.run_generator("-o")
        self.assertEqual(self.generated(), "")

    def test_legacy_migration_skips_wildcards_without_widening_domains(self):
        legacy_id = hashlib.md5((self.url("/gfw") + "\n").encode()).hexdigest()
        legacy = self.conf / ("vpn-nftset-gen_" + legacy_id + ".conf")
        legacy.write_text(
            "nftset=/legacy.example/"
            + NFTSETS
            + "\nnftset=/s3-ap-*.amazonaws.com/"
            + NFTSETS
            + "\n"
        )
        result = self.run_generator("-w", self.url("/gfw"), "-o")
        self.assertIn("Skipped 1 unsupported wildcard domain(s)", result.stderr)
        self.assertEqual(self.generated(), "nftset=/legacy.example/" + NFTSETS + "\n")
        self.assertEqual(
            (self.cache / (self.source_id("/gfw") + ".domains")).read_text(),
            "legacy.example\n",
        )
        self.assertFalse(legacy.exists())
        self.assertEqual(self.requests, [])
        result = self.run_generator("-w", self.url("/gfw"), "-o")
        self.assertEqual(result.stderr, "")
        self.responses["/gfw"] = (503, b"offline")
        result = self.run_generator("-w", self.url("/gfw"), code=1)
        self.assertNotIn("Invalid domain:", result.stderr)
        self.assertNotIn("unsupported wildcard", result.stderr)
        self.assertEqual(self.generated(), "nftset=/legacy.example/" + NFTSETS + "\n")

    def test_concurrent_update_cannot_replace_running_update(self):
        self.responses["/slow"] = (200, b"slow.example\n")
        self.responses["/other"] = (200, b"other.example\n")
        first = subprocess.Popen(
            self.command("-u", self.url("/slow")),
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            self.assertTrue(self.slow_started.wait(5))
            second = subprocess.run(
                self.command("-u", self.url("/other")),
                env=self.env,
                text=True,
                capture_output=True,
                timeout=5,
            )
            self.assertEqual(second.returncode, 1)
            self.assertIn("already running", second.stderr)
            self.assertNotIn("/other", self.requests)
        finally:
            self.slow_release.set()
            output, error = first.communicate(timeout=5)
        self.assertEqual(first.returncode, 0, output + error)
        self.assertIn("slow.example", self.generated())
        self.assertNotIn("other.example", self.generated())
        self.assertFalse((self.runtime / "update.lock").exists())

    def test_fallback_downloaders_use_supported_options(self):
        payload = self.home / "source-domains"
        payload.write_text("stable.example\n")
        for adapter in ("uclient-fetch", "wget"):
            with self.subTest(adapter=adapter):
                binaries = self.home / adapter
                binaries.mkdir()
                for command in (
                    "sh",
                    "mkdir",
                    "cat",
                    "rm",
                    "mktemp",
                    "cp",
                    "mv",
                    "cmp",
                    "awk",
                    "md5sum",
                    "sort",
                    "date",
                ):
                    (binaries / command).symlink_to(shutil.which(command))
                downloader = binaries / adapter
                downloader.write_text(
                    f"""#!/bin/sh
for argument do
    case "$argument" in
        -t) [ '{adapter}' = wget ] || exit 2 ;;
        --connect-timeout|--max-time) exit 2 ;;
    esac
done
while [ "$#" -gt 0 ]; do
    if [ "$1" = -O ]; then cp "$VPN_NFTSET_DOWNLOAD_PAYLOAD" "$2"; exit; fi
    shift
done
exit 1
"""
                )
                downloader.chmod(0o755)
                if adapter == "uclient-fetch":
                    unused = binaries / "wget"
                    unused.write_text("#!/bin/sh\nexit 99\n")
                    unused.chmod(0o755)
                self.env.update(
                    PATH=str(binaries), VPN_NFTSET_DOWNLOAD_PAYLOAD=str(payload)
                )
                self.run_generator("-u", self.url("/plain"))
                self.assertEqual(
                    self.generated(), "nftset=/stable.example/" + NFTSETS + "\n"
                )
                self.assertEqual(self.requests, [])

    def test_stale_update_lock_recovers_and_missing_pid_is_not_stolen(self):
        lock = self.runtime / "update.lock"
        lock.mkdir()
        (lock / "pid").write_text("2147483647\n")
        self.run_generator("-o")
        self.assertEqual(self.generated(), "")
        lock.mkdir()
        result = subprocess.run(
            self.command("-o"), env=self.env, text=True, capture_output=True, timeout=5
        )
        self.assertEqual(result.returncode, 1)
        self.assertTrue(lock.exists())
        self.assertIn("already running", result.stderr)

    def test_cancelled_download_cannot_commit_cache_or_rules(self):
        self.responses["/plain"] = (200, b"stable.example\n")
        self.run_generator("-u", self.url("/plain"))
        previous = self.generated()
        self.responses["/slow"] = (200, b"obsolete.example\n")
        cancel = self.runtime / "cancel-update"
        self.env["VPN_NFTSET_CANCEL_FILE"] = str(cancel)
        first = subprocess.Popen(
            self.command("-u", self.url("/slow")),
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            self.assertTrue(self.slow_started.wait(5))
            cancel.touch()
        finally:
            self.slow_release.set()
            output, error = first.communicate(timeout=5)
        self.assertEqual(first.returncode, 1, output + error)
        self.assertIn("cancelled", error)
        self.assertEqual(self.generated(), previous)
        self.assertFalse((self.cache / (self.source_id("/slow") + ".domains")).exists())
        self.assertFalse((self.runtime / "update.lock").exists())


if __name__ == "__main__":
    unittest.main()
