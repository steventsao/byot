#!/usr/bin/env python3
"""Real upstream servers, isolated data, and a deterministic local model over TLS."""
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PASSWORD = "byot-local-fixture-only"
REPLY = "BYOT upstream compatibility verified."


class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if body.get("model") == "retired":
            self.send_response(410)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"type": "about:blank", "title": "Gone", "status": 410,
                "detail": "The model 'fixture/retired' has reached its end of life and is no longer available."}).encode())
            return
        common = {"id": "fixture", "created": int(time.time()), "model": body.get("model", "test")}
        self.send_response(200)
        if not body.get("stream"):
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({**common, "object": "chat.completion", "choices": [
                {"index": 0, "message": {"role": "assistant", "content": REPLY}, "finish_reason": "stop"}
            ], "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}).encode())
            return
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            for delta in [{"role": "assistant"}, {"content": "BYOT upstream "}, {"content": "compatibility verified."}]:
                self.wfile.write(("data: " + json.dumps({**common, "object": "chat.completion.chunk", "choices": [
                    {"index": 0, "delta": delta, "finish_reason": None}
                ]}) + "\n\n").encode())
                self.wfile.flush()
                time.sleep(0.2)
            self.wfile.write(("data: " + json.dumps({**common, "object": "chat.completion.chunk", "choices": [
                {"index": 0, "delta": {}, "finish_reason": "stop"}
            ], "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}) + "\n\ndata: [DONE]\n\n").encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


def proxy_handler(port):
    class Proxy(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def forward(self):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            headers = {k: v for k, v in self.headers.items() if k.lower() not in {"host", "connection"}}
            try:
                connection.request(self.command, self.path, body=body, headers=headers)
                response = connection.getresponse()
                self.send_response(response.status)
                for key, value in response.getheaders():
                    if key.lower() not in {"transfer-encoding", "connection", "content-length"}:
                        self.send_header(key, value)
                self.send_header("Connection", "close")
                self.end_headers()
                while chunk := response.read1(16384):
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except ConnectionRefusedError:
                self.send_error(503, "Upstream starting")
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass
            finally:
                connection.close()
                self.close_connection = True

        do_GET = do_POST = do_DELETE = do_PATCH = do_PUT = forward

        def log_message(self, *args):
            pass

    return Proxy


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--tools", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    for port in range(4195, 4200):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))  # Fail instead of disturbing another server.

    cert, key = root / "tls.crt", root / "tls.key"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                    "-keyout", str(key), "-out", str(cert), "-subj", "/CN=BYOT isolated E2E",
                    "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost",
                    "-addext", "basicConstraints=critical,CA:TRUE"], check=True, capture_output=True)
    key.chmod(0o600)
    servers, children = [], []
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    try:
        model = ThreadingHTTPServer(("127.0.0.1", 4198), Model)
        servers.append(model)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        versions = {}
        for major, binary, port, tls_port in [("v1", "opencode", 4196, 4195), ("v2", "opencode2", 4197, 4199)]:
            runtime = root / major
            project = runtime / "project"
            project.mkdir(parents=True)
            # Retain normal process/runtime settings, but never inherit provider
            # credentials or OpenCode overrides from the developer's shell.
            runtime_keys = {"PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR", "TERM"}
            env = {k: v for k, v in os.environ.items() if k in runtime_keys}
            for variable, folder in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                                     ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")]:
                (runtime / folder).mkdir()
                env[variable] = str(runtime / folder)
            env["OPENCODE_SERVER_PASSWORD"] = PASSWORD
            options = {"baseURL": "http://127.0.0.1:4198/v1", "apiKey": "fixture-only"}
            model_config = {"name": "Local acceptance fixture", "limit": {"context": 1048576, "output": 4096}}
            if major == "v1":
                config = {"model": "fixture/test", "autoupdate": False, "snapshot": False, "provider": {"fixture": {
                    "name": "BYOT Fixture", "npm": "@ai-sdk/openai-compatible", "options": options, "models": {"test": model_config}}}}
            else:
                env["OPENCODE_DB"] = str(runtime / "opencode.db")
                model_config["capabilities"] = {"tools": True, "input": ["text"], "output": ["text"]}
                model_config["limit"]["input"] = 1000000
                config = {"model": "fixture/test", "update": "disable", "share": "disabled", "providers": {"fixture": {
                    "name": "BYOT Fixture", "package": "aisdk:@ai-sdk/openai-compatible", "settings": options,
                    "models": {"test": model_config}}}, "permissions": [{"action": "byot_acceptance", "resource": "*", "effect": "ask"}]}
            (project / "opencode.json").write_text(json.dumps(config, indent=2))
            retired_project = runtime / "retired"
            retired_project.mkdir()
            retired_config = json.loads(json.dumps(config))
            retired_config["model"] = "fixture/retired"
            provider_key = "provider" if major == "v1" else "providers"
            retired_config[provider_key]["fixture"]["models"]["retired"] = {
                **model_config, "name": "Retired model fixture"}
            (retired_project / "opencode.json").write_text(json.dumps(retired_config, indent=2))
            executable = str(args.tools.resolve() / "node_modules" / ".bin" / binary)
            versions[major] = subprocess.check_output([executable, "--version"], env=env, text=True).strip().removeprefix("opencode2 v")
            with (runtime / "server.log").open("w") as log:
                child = subprocess.Popen([executable, "serve", "--hostname", "127.0.0.1", "--port", str(port)],
                                         cwd=project, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            children.append(child)
            proxy = ThreadingHTTPServer(("127.0.0.1", tls_port), proxy_handler(port))
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            proxy.socket = context.wrap_socket(proxy.socket, server_side=True)
            servers.append(proxy)
            threading.Thread(target=proxy.serve_forever, daemon=True).start()

        trust = ssl.create_default_context(cafile=str(cert))
        auth = "Basic " + base64.b64encode(f"opencode:{PASSWORD}".encode()).decode()
        for major, port, path in [("v1", 4195, "/global/health"), ("v2", 4199, "/api/health")]:
            for attempt in range(120):
                if stop.is_set() or any(c.poll() is not None for c in children):
                    raise RuntimeError("An upstream server exited; inspect server.log")
                try:
                    request = urllib.request.Request(f"https://127.0.0.1:{port}{path}", headers={"Authorization": auth})
                    with urllib.request.urlopen(request, context=trust, timeout=2) as response:
                        health = json.load(response)
                    (root / major / "health.json").write_text(json.dumps(health, indent=2))
                    break
                except (OSError, ValueError):
                    if attempt == 119:
                        raise
                    stop.wait(0.5)
        schema_request = urllib.request.Request("https://127.0.0.1:4199/openapi.json", headers={"Authorization": auth})
        with urllib.request.urlopen(schema_request, context=trust, timeout=10) as response:
            schema = response.read()
        (root / "v2" / "openapi.json").write_bytes(schema)
        (root / "v2" / "openapi.sha256").write_text(hashlib.sha256(schema).hexdigest() + "\n")
        (root / "ready.json").write_text(json.dumps(versions, indent=2) + "\n")
        print(json.dumps({"ready": True, "root": str(root), "versions": versions}), flush=True)
        while not stop.wait(1):
            if any(c.poll() is not None for c in children):
                raise RuntimeError("An upstream server stopped during the tests")
    finally:
        for child in children:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
