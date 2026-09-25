#!/usr/bin/env python3
"""Local HTTP bridge for the fail-closed detect-secrets Jev gate."""

from __future__ import annotations

import json
import subprocess
import sys
from urllib.error import URLError
from urllib.request import urlopen
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST = "127.0.0.1"
PORT = 48752
IDENTITY = {"service": "firstmate-jev-safety", "protocol": 1}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
        if self.path != "/health":
            self.send_error(404)
            return
        if self.client_address[0] != HOST:
            self.send_error(403)
            return
        body = json.dumps(IDENTITY, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
        if self.path != "/check":
            self.send_error(404)
            return
        if self.client_address[0] != HOST:
            self.send_error(403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(min(length, 4_000_000)).decode("utf-8")
            result = subprocess.run(
                [sys.executable, str(ROOT / ".claude/jev-safety/check.py")],
                input=raw,
                capture_output=True,
                text=True,
                cwd=ROOT,
                timeout=30,
                check=False,
            )
            verdict = json.loads(result.stdout) if result.stdout else {
                "allowed": False,
                "reason": "scanner_unavailable",
            }
            if result.returncode not in (0, 3):
                verdict = {"allowed": False, "reason": "scanner_unavailable"}
        except Exception:
            verdict = {"allowed": False, "reason": "scanner_unavailable"}
        body = json.dumps(verdict, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def ensure() -> None:
    import socket

    with socket.socket() as sock:
        if sock.connect_ex((HOST, PORT)) == 0:
            try:
                with urlopen(f"http://{HOST}:{PORT}/health", timeout=2) as response:
                    if response.status != 200 or json.loads(response.read()) != IDENTITY:
                        raise SystemExit("port 48752 is occupied by a non-Firstmate safety service")
            except (URLError, TimeoutError, OSError, json.JSONDecodeError) as error:
                raise SystemExit("port 48752 is occupied by an unverified service") from error
            return
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "--serve"],
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


if __name__ == "__main__":
    if "--serve" in sys.argv:
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
    else:
        ensure()
