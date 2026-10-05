#!/usr/bin/env python3
"""Serve actual application templates/assets with controlled local API fixtures.

The LuCI platform wrappers are simulated by render_ui.lua. No router or network
subscription is contacted. Run: python3 tests/preview_ui.py --port 8765
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "files/root/www/luci-static/resources"
LUA = os.environ.get("VPN_NFTSET_LUA") or shutil.which("lua") or shutil.which("luajit")
CUSTOM = ["githubusercontent.com", "stackexchange.com", "google.com", "feedly.com", "twitter.com", "golang.org", "apple.com", "forms.gle", "page.link", "fastly.net", "medium.com", "sre.google", "github.blog", "example.com", "specific.example.net/ns#5353"]
SOURCE_URLS = ["https://example.com/gfwlist.txt", "https://example.com/domains.txt"]
SOURCES = [{"id": hashlib.md5(url.encode()).hexdigest(), "url": url, "kind": "gfw" if index == 0 else "plain", "count": 0, "status": "ok", "cached": True, "last_success": 1790903400} for index, url in enumerate(SOURCE_URLS)]
DOMAINS = sorted({"google.com", "cdn.example.com", "githubusercontent.com", "avatars0.githubusercontent.com", "substack.com", "news.ycombinator.com", "telegram.org", "notexample.com", "example.net", *[f"service{index:03d}.example.org" for index in range(130)]})


class PreviewHandler(BaseHTTPRequestHandler):
    custom_entries = None
    updating_until = 0

    def send(self, body, content_type="application/json", status=200):
        encoded = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path.startswith("/luci-static/resources/"):
            name = parsed.path.rsplit("/", 1)[-1]
            if name not in {"vpn-nftset.js", "vpn-nftset.css"}:
                self.send("Not found", "text/plain", 404)
                return
            self.send((ASSETS / name).read_bytes(), "text/javascript" if name.endswith(".js") else "text/css")
            return
        if "/catalog" in parsed.path:
            self.catalog(query)
            return
        language = query.get("lang", ["zh-cn"])[0]
        state = query.get("state", ["normal"])[0]
        with tempfile.TemporaryDirectory(prefix="vpn-ui-preview-") as directory:
            args = [LUA, "tests/render_ui.lua", language, state]
            if self.custom_entries is not None and state != "empty":
                path = Path(directory) / "custom.txt"
                path.write_text("\n".join(self.custom_entries))
                args.append(str(path))
            output = subprocess.run(args, cwd=ROOT, check=True, capture_output=True).stdout.decode()
        preview_note = "Local interface preview · Simulated data" if language == "en" else "本地界面预览 · 模拟数据"
        output = output.replace('<main>', '<main><div style="margin-bottom:14px;padding:9px 12px;background:#fff6df;border:1px solid #eddda8;border-radius:7px;font-size:12px;color:#806328">' + preview_note + '</div>', 1)
        if state != "normal":
            output = output.replace('data-catalog-url="/cgi-bin/luci/admin/services/vpn-nftset/catalog"', f'data-catalog-url="/cgi-bin/luci/admin/services/vpn-nftset/catalog/{state}"')
        self.send(output, "text/html; charset=utf-8")

    def catalog(self, query):
        state = self.path.split("/catalog/", 1)[-1].split("?", 1)[0] if "/catalog/" in self.path else "normal"
        if state == "load-error":
            self.send(json.dumps({"error": "fixture_load_error"}), status=503)
            return
        entries = [] if state == "empty" else (self.custom_entries if self.custom_entries is not None else CUSTOM)
        custom = {entry.split("/", 1)[0] for entry in entries}
        sources = [dict(source) for source in SOURCES]
        if state == "failed":
            sources[0]["status"] = "download_failed"
        downloaded = [] if state == "empty" else DOMAINS
        rows = []
        needle = query.get("q", [""])[0].lower()
        selected = query.get("source", [""])[0]
        for index, domain in enumerate(downloaded):
            provenance = [sources[index % 2]]
            if index % 9 == 0:
                provenance = sources
            for source in provenance:
                source["count"] += 1
            if needle not in domain or (selected and all(source["id"] != selected for source in provenance)):
                continue
            row = {"domain": domain, "custom": domain in custom, "sources": [{key: source[key] for key in ("id", "url", "kind")} for source in provenance]}
            parents = [parent for parent in custom if domain.endswith("." + parent)]
            if parents:
                row["covered_by"] = max(parents, key=len)
            rows.append(row)
        size = max(10, min(100, int(query.get("page_size", [25])[0])))
        pages = max(1, (len(rows) + size - 1) // size)
        page = max(1, min(pages, int(query.get("page", [1])[0])))
        data = {"rows": rows[(page - 1) * size:page * size], "total": len(rows), "page": page, "pages": pages, "page_size": size,
                "counts": {"custom": len(custom), "downloaded": len(downloaded), "total": len(custom | set(downloaded))}, "sources": sources,
                "enabled": state != "disabled", "auto_update": True, "running": time.time() < self.updating_until,
                "refresh_status": "failed" if state == "failed" else "ok",
                "telegram": {"url": "https://core.telegram.org/resources/cidr.txt", "count": 14, "enabled": True, "cached": state != "empty", "status": "bundled" if state == "empty" else "ok", "last_success": 1790903400 if state != "empty" else None}}
        check = query.get("check", [""])[0]
        if check:
            parents = [domain for domain in downloaded if check.endswith("." + domain)]
            data["overlap"] = {"exact": check in downloaded, "parent": max(parents, key=len) if parents else None, "subdomains": sum(domain.endswith("." + check) for domain in downloaded)}
        self.send(json.dumps(data))

    def do_POST(self):
        values = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode(), keep_blank_values=True)
        if values.get("token") != ["fixture-token"]:
            self.send(json.dumps({"error": "invalid_token"}), status=403)
            return
        if self.path.endswith("/refresh"):
            type(self).updating_until = time.time() + 2.5
            self.send(json.dumps({"started": True}))
        elif self.path == "/save":
            type(self).custom_entries = values.get("cbid.vpn-nftset.cfg-dnsmasq_nftset.domains", [""])[0].splitlines()
            self.send_response(303)
            self.send_header("Location", "/")
            self.end_headers()
        else:
            self.send("Not found", "text/plain", 404)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not LUA:
        parser.error("Lua 5.1 or LuaJIT is required. Set VPN_NFTSET_LUA to its executable path.")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), PreviewHandler)
    print(f"UI preview: http://127.0.0.1:{args.port}/ (fixtures: ?state=empty|failed|disabled|invalid|load-error&lang=en)", flush=True)
    server.serve_forever()
