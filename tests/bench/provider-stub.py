#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
"""A local HTTPS stand-in for an OpenAI-compatible model provider.

  provider-stub.py <key-file> <port> <out-dir> [--ca-dir <dir>]
  provider-stub.py --ca-only --ca-dir <dir>

It binds 127.0.0.1 only (qemu's user network reaches the host's loopback as
10.0.2.2), serves HTTPS with a certificate for 10.0.2.2 and 127.0.0.1 made by a
throwaway CA, and answers:

  GET  /v1/models            200 for the expected key as `Authorization:
                             Bearer <key>`, 401 otherwise
  POST /v1/chat/completions  a minimal chat completion, an SSE stream (one
                             content delta and [DONE]) when the request asks
                             for "stream": true

Per request it appends one JSON line to <out-dir>/requests.jsonl: the method,
the path and, for each header, its name and the SHA-256 of its value, never a
value. The expected key is read from <key-file> and never written anywhere.

The CA (ca.pem, with server.pem and server.key beside it) lives in --ca-dir
(default <out-dir>/ca) and is made once; a build configuration's
provider_ca_file points at ca.pem. --ca-only makes it and exits. The `openssl`
command line tool makes the certificates.
"""
import hashlib
import json
import os
import ssl
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def usage():
    sys.exit(__doc__)


def make_ca(ca_dir):
    """Create ca.pem, server.pem and server.key in ca_dir unless present."""
    os.makedirs(ca_dir, exist_ok=True)
    ca, srv, srv_key = (os.path.join(ca_dir, n) for n in ("ca.pem", "server.pem", "server.key"))
    if all(os.path.exists(p) for p in (ca, srv, srv_key)):
        return ca, srv, srv_key
    ca_key = os.path.join(ca_dir, "ca.key")
    csr = os.path.join(ca_dir, "server.csr")
    ext = os.path.join(ca_dir, "server.ext")
    with open(ext, "w") as f:
        f.write("subjectAltName=IP:10.0.2.2,IP:127.0.0.1\n"
                "basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n")
    run = lambda *a: subprocess.run(a, check=True, capture_output=True)
    run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
        "-subj", "/CN=system-rescuer provider stub CA", "-keyout", ca_key, "-out", ca)
    run("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=10.0.2.2",
        "-keyout", srv_key, "-out", csr)
    run("openssl", "x509", "-req", "-in", csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial",
        "-days", "30", "-extfile", ext, "-out", srv)
    for p in (csr, ext, ca_key):
        os.unlink(p)
    return ca, srv, srv_key


def sha256(value):
    return hashlib.sha256(value.encode("utf-8", "surrogateescape")).hexdigest()


def main(argv):
    ca_dir = None
    ca_only = False
    args = []
    it = iter(argv)
    for a in it:
        if a == "--ca-dir":
            ca_dir = next(it, None) or usage()
        elif a == "--ca-only":
            ca_only = True
        else:
            args.append(a)
    if ca_only:
        if not ca_dir:
            usage()
        print(make_ca(ca_dir)[0])
        return
    if len(args) != 3:
        usage()
    key_file, port, out_dir = args[0], int(args[1]), args[2]
    os.makedirs(out_dir, exist_ok=True)
    ca, srv, srv_key = make_ca(ca_dir or os.path.join(out_dir, "ca"))
    with open(key_file) as f:
        want = "Bearer " + "".join(f.read().split())
    record_path = os.path.join(out_dir, "requests.jsonl")
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "provider-stub"

        def log_message(self, format, *args):  # noqa: A002  # the record is the log
            pass

        def authorized(self):
            return self.headers.get("Authorization") == want

        def record(self, status):
            entry = {
                "method": self.command,
                "path": self.path,
                "status": status,
                "headers": [{"name": k, "sha256": sha256(v)} for k, v in self.headers.items()],
            }
            with lock, open(record_path, "a") as f:
                f.write(json.dumps(entry) + "\n")

        def send(self, status, body, ctype="application/json"):
            self.record(status)
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.split("?")[0] != "/v1/models":
                return self.send(404, b'{"error":{"message":"not found"}}')
            if not self.authorized():
                return self.send(401, b'{"error":{"message":"invalid api key"}}')
            self.send(200, json.dumps({"object": "list", "data": [
                {"id": "stub-model", "object": "model", "owned_by": "stub"}]}).encode())

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            if self.path.split("?")[0] != "/v1/chat/completions":
                return self.send(404, b'{"error":{"message":"not found"}}')
            if not self.authorized():
                return self.send(401, b'{"error":{"message":"invalid api key"}}')
            try:
                req = json.loads(raw or b"{}")
            except ValueError:
                req = {}
            model = req.get("model", "stub-model")
            text = "The provider stub answers."
            if req.get("stream"):
                def chunk(delta, finish=None):
                    return "data: " + json.dumps({
                        "id": "stub-1", "object": "chat.completion.chunk", "created": 0,
                        "model": model,
                        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n"
                body = (chunk({"role": "assistant", "content": ""}) + chunk({"content": text})
                        + chunk({}, "stop") + "data: [DONE]\n\n").encode()
                return self.send(200, body, "text/event-stream")
            self.send(200, json.dumps({
                "id": "stub-1", "object": "chat.completion", "created": 0, "model": model,
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": text}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode())

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(srv, srv_key)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"provider-stub: listening on 127.0.0.1:{port}, CA {ca}, record {record_path}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main(sys.argv[1:])
