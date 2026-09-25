#!/usr/bin/env python3
"""Local HTTP bridge for the fail-closed detect-secrets Jev gate."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import stat
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
HOST = "127.0.0.1"
PORT = 48752
KEY_PATH = ROOT / ".claude" / "jev-safety" / ".gate-key"
GATE_KEY: bytes | None = None


def load_key() -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(KEY_PATH, flags)
    except FileNotFoundError:
        try:
            fd = os.open(KEY_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as key_file:
                key_file.write(secrets.token_hex(32).encode())
        except FileExistsError:
            pass
        fd = os.open(KEY_PATH, flags)
    with os.fdopen(fd, "rb") as key_file:
        metadata = os.fstat(key_file.fileno())
        key = key_file.read()
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600 or len(key) != 64:
        raise SystemExit("local Jev safety gate key has unsafe ownership or permissions")
    try:
        bytes.fromhex(key.decode("ascii"))
    except (UnicodeDecodeError, ValueError) as error:
        raise SystemExit("local Jev safety gate key is invalid") from error
    return key


def proof(nonce: str, key: bytes) -> str:
    return hmac.new(key, nonce.encode("ascii"), hashlib.sha256).hexdigest()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
        parsed = urlsplit(self.path)
        nonce = parse_qs(parsed.query).get("nonce", [""])[0]
        if parsed.path != "/health" or len(nonce) != 64 or any(char not in "0123456789abcdef" for char in nonce):
            self.send_error(404)
            return
        if self.client_address[0] != HOST:
            self.send_error(403)
            return
        body = json.dumps({"nonce": nonce, "proof": proof(nonce, GATE_KEY or b"")}, separators=(",", ":")).encode()
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

    key = load_key()
    with socket.socket() as sock:
        if sock.connect_ex((HOST, PORT)) == 0:
            try:
                nonce = secrets.token_hex(32)
                with urlopen(f"http://{HOST}:{PORT}/health?nonce={nonce}", timeout=2) as response:
                    identity = json.loads(response.read())
                    if response.status != 200 or identity != {"nonce": nonce, "proof": proof(nonce, key)}:
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
        GATE_KEY = load_key()
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
    else:
        ensure()
