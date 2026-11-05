#!/usr/bin/env python3
"""A fake model server for scripts/test-model-client.sh.

POST /v1/messages and POST /chat/completions answer from tests/fixtures. Every request (path,
headers that matter, body) is appended to $FAKE_LLM_LOG as a JSON line. Behaviour by the request's
model name: "flaky" answers 429 once, then works; "down" answers 503 always; "badkey" answers 401;
"slow" never answers within a test's patience.
"""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

fixtures = os.environ["FAKE_LLM_FIXTURES"]
log = os.environ["FAKE_LLM_LOG"]
flaky_seen = set()

def fx(name):
    return open(os.path.join(fixtures, name), "rb").read()

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def reply(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "body": body, "key": self.headers.get("x-api-key"),
                                "version": self.headers.get("anthropic-version"),
                                "auth": self.headers.get("Authorization")}) + "\n")
        model = body.get("model", "")
        anthropic = self.path.endswith("/messages")
        if model == "badkey":
            self.reply(401, json.dumps({"error": {"message": "Incorrect API key provided"}}).encode()); return
        if model == "down":
            self.reply(503, json.dumps({"error": {"message": "overloaded"}}).encode()); return
        if model == "flaky" and self.path not in flaky_seen:
            flaky_seen.add(self.path)
            self.reply(429, json.dumps({"error": {"message": "slow down"}}).encode()); return
        if model == "slow":
            time.sleep(30); return
        if model == "garbage":
            self.reply(200, b"<html>not json</html>"); return
        has_tool_result = any(m.get("role") == "tool" for m in body.get("messages", [])) or any(
            isinstance(m.get("content"), list) and any(b.get("type") == "tool_result" for b in m["content"])
            for m in body.get("messages", []))
        if anthropic:
            self.reply(200, fx("brain-anthropic-text.json" if has_tool_result else "brain-anthropic-response.json"))
        else:
            self.reply(200, fx("brain-openai-text.json" if has_tool_result else "brain-openai-response.json"))

srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.daemon_threads = True
srv.serve_forever()
