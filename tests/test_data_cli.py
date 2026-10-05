import ipaddress
import os
from pathlib import Path
import random
import resource
import shutil
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
LUA = os.environ.get("VPN_NFTSET_LUA") or shutil.which("lua") or shutil.which("luajit")


@unittest.skipUnless(LUA, "Lua 5.1 or LuaJIT is required")
class DataCliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="vpn-nftset-data-")
        self.addCleanup(temporary.cleanup)
        self.source = Path(temporary.name) / "source"
        self.output = Path(temporary.name) / "output"
        self.env = dict(
            os.environ, LUA_PATH=str(ROOT / "files/root/usr/lib/lua/?.lua") + ";;"
        )

    def run_cli(self, *operation, **options):
        return subprocess.run(
            [
                LUA,
                str(ROOT / "files/root/usr/bin/vpn-nftset-data"),
                *operation,
                str(self.source),
                str(self.output),
            ],
            env=self.env,
            capture_output=True,
            text=True,
            **options,
        )

    def test_cidr_normalization_matches_standard_library(self):
        rng = random.Random(42)
        addresses = ["0.0.0.0/0", "::/0", "::ffff:192.0.2.123/128"]
        for width in (32, 128):
            addresses.extend(
                f"{ipaddress.ip_address(rng.getrandbits(width))}/{rng.randrange(width + 1)}"
                for _ in range(100)
            )
        self.source.write_text("\r\n".join(addresses))
        result = self.run_cli("parse-cidrs")
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = {ipaddress.ip_network(value, strict=False) for value in addresses}
        actual = [
            ipaddress.ip_network(value)
            for value in self.output.read_text().splitlines()
        ]
        self.assertEqual(set(actual), expected)
        self.assertEqual(len(actual), len(expected))

    def test_output_flush_failure_returns_nonzero(self):
        # Force a real buffered file write to fail on close, without mocking Lua I/O.
        def limit_output():
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))

        self.source.write_text("example.com\n")
        result = self.run_cli("parse-domains", "plain", preexec_fn=limit_output)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr)
        self.assertEqual(self.output.stat().st_size, 1)


if __name__ == "__main__":
    unittest.main()
