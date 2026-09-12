#!/usr/bin/env python3
"""HAProxy health sidecar for one MySQL node.

Exposes two HTTP endpoints that HAProxy's httpchk hits directly:
  GET /write -> 200 iff this node's global read_only is OFF (it's the writable primary)
  GET /read  -> 200 iff this node's global read_only is ON  (it's a replica, safe to read from)
Anything else (connection refused, replication broken enough to matter) -> 503.

Kept dependency-free (stdlib only + the mysql CLI already present on the mysql image)
so the sidecar image stays tiny and doesn't need its own MySQL client library pinned
to the server version.
"""
import http.server
import os
import subprocess
import sys

MYSQL_HOST = os.environ["MYSQL_HOST"]
MYSQL_USER = os.environ.get("MYSQL_HEALTH_USER", "root")
MYSQL_PASSWORD = os.environ["MYSQL_HEALTH_PASSWORD"]


def read_only() -> bool:
    try:
        out = subprocess.run(
            [
                "mysql", "-h", MYSQL_HOST, "-u", MYSQL_USER,
                f"-p{MYSQL_PASSWORD}", "-N", "-B",
                "-e", "SELECT @@read_only",
            ],
            capture_output=True, text=True, timeout=3,
        )
        if out.returncode != 0:
            return None
        return out.stdout.strip() == "1"
    except Exception:
        return None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quiet; HAProxy polls every few seconds
        pass

    def do_GET(self):
        ro = read_only()
        if self.path == "/write":
            ok = ro is False
        elif self.path == "/read":
            ok = ro is True
        elif self.path == "/health":
            ok = ro is not None
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200 if ok else 503)
        self.end_headers()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8081"))
    http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
