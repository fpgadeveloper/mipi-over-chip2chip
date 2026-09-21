#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
"""filedrop.py - a two-way file drop between the build host and a bench board.

The ZCU106 image has wget and curl but no scp server key on the host side of the
bench loop, and captured frames are far too big for a base64 round trip through
the UART transcript.  This serves one directory over HTTP:

    GET  /<name>        download a file the host put in the directory
    PUT  /<name>        upload (curl -T file http://<host>:<port>/<name>)
    POST /<name>        upload (wget --post-file=file http://<host>:<port>/<name>)

Usage:  filedrop.py DIR [--bind 0.0.0.0] [--port 8123]

Only file names are accepted (no directory traversal, no sub-directories).
Bench LAN only: there is no authentication.
"""

import argparse
import http.server
import os
import posixpath
import shutil
import sys
import urllib.parse


class Handler(http.server.SimpleHTTPRequestHandler):
    def _target(self):
        name = posixpath.basename(urllib.parse.unquote(self.path.split("?", 1)[0]))
        if not name or name in (".", ".."):
            return None
        return os.path.join(self.directory, name)

    def _recv(self):
        path = self._target()
        if path is None:
            self.send_error(400, "bad file name")
            return
        length = self.headers.get("Content-Length")
        try:
            with open(path, "wb") as fh:
                if length is not None:
                    remaining = int(length)
                    while remaining > 0:
                        chunk = self.rfile.read(min(65536, remaining))
                        if not chunk:
                            break
                        fh.write(chunk)
                        remaining -= len(chunk)
                else:
                    shutil.copyfileobj(self.rfile, fh)
        except OSError as exc:
            self.send_error(500, str(exc))
            return
        size = os.path.getsize(path)
        body = f"OK {os.path.basename(path)} {size}\n".encode()
        self.send_response(201)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        sys.stderr.write(f"stored {path} ({size} bytes)\n")
        sys.stderr.flush()

    do_PUT = _recv
    do_POST = _recv


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("directory")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8123)
    args = ap.parse_args()

    os.makedirs(args.directory, exist_ok=True)
    directory = os.path.abspath(args.directory)

    def factory(*a, **kw):
        return Handler(*a, directory=directory, **kw)

    srv = http.server.ThreadingHTTPServer((args.bind, args.port), factory)
    sys.stderr.write(f"filedrop: serving {directory} on {args.bind}:{args.port}\n")
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
