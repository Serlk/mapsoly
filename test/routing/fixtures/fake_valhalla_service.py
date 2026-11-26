#!/usr/bin/env python3
"""Stand-in for valhalla_service used by valhalla_service_test.dart.

Same command line (<config.json> <threads>); listens where the config says
and answers /status. POST /crash makes it exit with code 3.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

config = json.load(open(sys.argv[1]))
listen = config["httpd"]["service"]["listen"]
host, port = listen.replace("tcp://", "").rsplit(":", 1)
if not os.path.exists(config["mjolnir"]["tile_extract"]):
    sys.stderr.write("cannot start valhalla: no tiles\n")
    sys.exit(1)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/crash":
            os._exit(3)
        body = json.dumps({"version": "fake", "pid": os.getpid()}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


print("fake valhalla listening on", listen, flush=True)
HTTPServer((host, int(port)), Handler).serve_forever()
