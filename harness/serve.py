#!/usr/bin/env python3
"""serve.py PORT ROOT — static server that reports and applies Content-Encoding: gzip.

Usage: python3 harness/serve.py 8080 web

The download-size number only means something if it is the number of bytes the
browser actually pulls, so this serves the same files the plain server does but
gzip-encodes them when the client offers gzip and gzip actually helps. Every
response is logged to stderr as `<path> raw=<n> sent=<n> enc=<...>`.
"""
import gzip
import http.server
import os
import sys

ROOT = sys.argv[2] if len(sys.argv) > 2 else "."
COMPRESSIBLE = {".html", ".js", ".mjs", ".css", ".wasm", ".bin", ".xz"}


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def do_GET(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            path = os.path.join(path, "index.html")
        if not os.path.isfile(path):
            self.send_error(404)
            return
        with open(path, "rb") as fh:
            raw = fh.read()
        enc = None
        body = raw
        if os.path.splitext(path)[1].lower() in COMPRESSIBLE and "gzip" in self.headers.get("Accept-Encoding", ""):
            gz = gzip.compress(raw, 9)
            if len(gz) < len(raw):
                body, enc = gz, "gzip"
        sys.stderr.write(f"{self.path} raw={len(raw)} sent={len(body)} enc={enc}\n")
        self.send_response(200)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Length", str(len(body)))
        if enc:
            self.send_header("Content-Encoding", enc)
        self.end_headers()
        self.wfile.write(body)


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
