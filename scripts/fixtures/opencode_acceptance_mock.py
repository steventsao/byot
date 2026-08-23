#!/usr/bin/env python3
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


protocol, port_file, username, password = sys.argv[1:5]
expected_auth = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != expected_auth:
            self.respond(401, {"message": "unauthorized"})
            return

        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        try:
            if protocol == "v1":
                self.handle_v1(parsed.path, query)
            else:
                self.handle_v2(parsed.path, query)
        except QueryFailure:
            return

    def handle_v1(self, path, query):
        if path == "/global/health":
            self.respond(200, {"healthy": True, "version": "1.18.18"})
        elif path == "/project":
            self.require_query(query, "directory", "/repo")
            self.respond(200, [{"id": "proj_1", "worktree": "/repo", "time": {"created": 1, "updated": 2}, "sandboxes": []}])
        elif path == "/session":
            self.require_query(query, "directory", "/repo")
            self.require_query(query, "scope", "project")
            self.require_query(query, "roots", "true")
            self.respond(200, [])
        else:
            self.respond(404, {"message": "not found"})

    def handle_v2(self, path, query):
        if path == "/api/health":
            self.respond(200, {"healthy": True})
        elif path == "/api/location":
            self.require_query(query, "location[directory]", "/repo")
            self.respond(200, {"directory": "/repo", "workspaceID": "wrk_1", "project": {"id": "proj_1", "directory": "/repo"}})
        elif path == "/api/session":
            self.require_query(query, "directory", "/repo")
            self.require_query(query, "limit", "100")
            self.require_query(query, "order", "desc")
            self.respond(200, {"data": [], "cursor": {}})
        else:
            self.respond(404, {"message": "not found"})

    def require_query(self, query, key, expected):
        if query.get(key) != [expected]:
            self.respond(400, {"message": f"expected {key}={expected}"})
            raise QueryFailure()

    def respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


class QueryFailure(Exception):
    pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(port_file).write_text(str(server.server_address[1]))
server.serve_forever()
