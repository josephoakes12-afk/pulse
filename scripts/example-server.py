#!/usr/bin/env python3
"""Local demo endpoint. Binds only to loopback; never connects to a real project."""

from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path

EXAMPLE = Path(__file__).resolve().parent.parent / "examples" / "summary.json"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/summary":
            self.send_error(404)
            return
        payload = json.loads(EXAMPLE.read_text())
        now = datetime.now(timezone.utc)
        payload["measuredAt"] = now.isoformat().replace("+00:00", "Z")
        for event in payload.get("events", []):
            event["occurredAt"] = (now - timedelta(minutes=15)).isoformat().replace("+00:00", "Z")
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    print("Demo summary: http://127.0.0.1:8765/summary", flush=True)
    HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
