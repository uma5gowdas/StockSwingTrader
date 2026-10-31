#!/usr/bin/env python3
"""Tiny local HTTP stub for shell tests.

Usage: http_stub.py FIXTURE_DIR PORT_FILE REQUEST_LOG

Binds 127.0.0.1 on an ephemeral port, writes the port to PORT_FILE and
serves FIXTURE_DIR/<first path segment> (e.g. GET /company-news?x=1 serves
FIXTURE_DIR/company-news) as application/json. Missing fixtures return 404.
Every request is appended to REQUEST_LOG as "METHOD PATH HEADER_NAMES".
"""
import os
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


FIXTURE_DIR, PORT_FILE, REQUEST_LOG = sys.argv[1], sys.argv[2], sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def _serve(self):
        with open(REQUEST_LOG, "a") as log:
            log.write("%s %s %s\n" % (self.command, self.path, ",".join(sorted(self.headers.keys()))))
        name = self.path.split("?", 1)[0].strip("/").split("/")[0] or "index"
        path = os.path.join(FIXTURE_DIR, os.path.basename(name))
        if not os.path.isfile(path):
            self.send_response(404)
            self.end_headers()
            return
        with open(path, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = _serve
    do_POST = _serve

    def log_message(self, *args):
        pass


class QuickServer(HTTPServer):
    # HTTPServer.server_bind calls socket.getfqdn(), which can block for
    # seconds on macOS; the plain TCP bind is enough for a local stub.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


server = QuickServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".tmp", "w") as fh:
    fh.write(str(server.server_address[1]))
os.rename(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
