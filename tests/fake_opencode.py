#!/usr/bin/env python3
"""A fake `opencode serve` for scripts/test-opencode-server.sh.

Prints the two start-up lines the real server prints, then serves the few routes Mochi uses:
basic auth `opencode:<password>`, POST /api/session, POST /api/session/{id}/prompt (which makes the
server push events from tests/fixtures/opencode-events.txt onto /api/event), interrupt, model,
permission and form replies. Every request body is appended to $FAKE_OPENCODE_LOG as one JSON line.

FAKE_OPENCODE_MODE: nopassword (prints nothing), exit (dies at once).
"""
import base64, json, os, queue, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode = os.environ.get("FAKE_OPENCODE_MODE", "")
args = sys.argv[1:]
port = int(args[args.index("--port") + 1]) if "--port" in args else 0
log = os.environ.get("FAKE_OPENCODE_LOG")
fixture = os.environ.get("FAKE_OPENCODE_FIXTURE")
PASSWORD = "s3cret-pw"

if mode == "exit":
    sys.exit(3)
if mode == "nopassword":
    time.sleep(60)
    sys.exit(0)

subscribers = []
lock = threading.Lock()

def record(method, path, body):
    if log:
        with open(log, "a") as f:
            f.write(json.dumps({"method": method, "path": path, "body": body}) + "\n")

def first_scenario_lines():
    lines = []
    seen = False
    for l in open(fixture).read().split("\n"):
        if l.startswith(": scenario"):
            if seen:
                break
            seen = True
        elif l.startswith("data: "):
            lines.append(l)
    return lines

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def authed(self):
        want = "Basic " + base64.b64encode(("opencode:" + PASSWORD).encode()).decode()
        if self.headers.get("Authorization") != want:
            self.send_json(401, {"_tag": "UnauthorizedError", "message": "Unauthorized"})
            return False
        return True

    def send_json(self, status, obj):
        data = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        return json.loads(raw) if raw else None

    def do_GET(self):
        if not self.authed(): return
        if self.path == "/api/event":
            q = queue.Queue()
            with lock: subscribers.append(q)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            try:
                self.wfile.write(b'data: {"id":"evt_0","type":"server.connected","data":{}}\n\n: heartbeat\n\n')
                self.wfile.flush()
                while True:
                    try: item = q.get(timeout=0.2)
                    except queue.Empty: continue
                    if item is None: break
                    self.wfile.write((item + "\n\n").encode()); self.wfile.flush()
            except Exception:
                pass
            finally:
                with lock:
                    if q in subscribers: subscribers.remove(q)
            return
        if self.path == "/api/session/active":
            self.send_json(200, {"data": {"ses_fake": {"type": "running"}}}); return
        self.send_json(404, {"_tag": "NotFound", "message": "no such route"})

    def do_POST(self):
        if not self.authed(): return
        body = self.body()
        record("POST", self.path, body)
        if self.path == "/api/session":
            self.send_json(200, {"data": {"id": "ses_fake"}}); return
        if self.path.endswith("/prompt"):
            if body and body.get("text") == "bad":
                self.send_json(404, {"_tag": "SessionNotFoundError", "sessionID": "x", "message": "Session not found"}); return
            self.send_json(200, {"data": {"id": "msg_1"}})
            def push():
                for l in first_scenario_lines():
                    with lock:
                        for q in subscribers: q.put(l)
                    time.sleep(0.01)
            threading.Thread(target=push, daemon=True).start(); return
        if self.path.endswith("/interrupt"):
            self.send_json(200, {"interrupted": True}); return
        if self.path.endswith("/reply") or self.path.endswith("/model"):
            self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_json(404, {"_tag": "NotFound", "message": "no such route"})

    def do_DELETE(self):
        if not self.authed(): return
        record("DELETE", self.path, None)
        self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers()

srv = ThreadingHTTPServer(("127.0.0.1", port), H)
srv.daemon_threads = True
sys.stdout.write("server listening on http://127.0.0.1:%d\n" % port)
sys.stdout.flush()
# Split on purpose: the password arrives after the listening line.
time.sleep(0.2)
sys.stdout.write("server password " + PASSWORD + "\n")
sys.stdout.flush()
srv.serve_forever()
