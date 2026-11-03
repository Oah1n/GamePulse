#!/usr/bin/env python3
"""A dependency-free local fixture server for the GamePulse bridge contract."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TOKEN = os.environ.get("GAMEPULSE_TOKEN", "")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/v1/status":
            self.send_error(404)
            return
        if TOKEN and self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.send_error(401)
            return

        payload = json.loads((ROOT / "status.json").read_text(encoding="utf-8"))
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[GamePulse bridge] {format % args}")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
    print("GamePulse bridge listening on http://127.0.0.1:8765")
    server.serve_forever()
