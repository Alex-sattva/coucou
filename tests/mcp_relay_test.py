#!/usr/bin/env python3
"""Tests the `nb-hook --mcp` relay (the Python and shell scripts that HookServer.swift installs)
against a fake Coucou on a Unix socket. Usage: mcp_relay_test.py <hook-dir> <home>"""
import json, os, socket, subprocess, sys, threading, time

hook_dir, home = sys.argv[1], sys.argv[2]
sock_dir = os.path.join(home, "Library/Application Support/NotchBuddy")
os.makedirs(sock_dir, exist_ok=True)
sock_path = os.path.join(sock_dir, "nb.sock")
failures = 0

def check(label, ok):
    global failures
    print(("  ✓ " if ok else "  ✗ ") + label)
    if not ok: failures += 1

seen = []
def serve(reply_for):
    if os.path.exists(sock_path): os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path); srv.listen(8); srv.settimeout(0.2)
    stop = threading.Event()
    def loop():
        while not stop.is_set():
            try: c, _ = srv.accept()
            except socket.timeout: continue
            except OSError: break
            buf = b""
            while b"\n" not in buf:
                d = c.recv(65536)
                if not d: break
                buf += d
            env = json.loads(buf.split(b"\n")[0])
            seen.append(env)
            reply = reply_for(env)
            if reply is not None and "id" in env["rpc"]:
                c.sendall((json.dumps(reply) + "\n").encode())
            c.close()
    t = threading.Thread(target=loop, daemon=True); t.start()
    return lambda: (stop.set(), srv.close(), os.path.exists(sock_path) and os.unlink(sock_path))

def echo(env):
    return {"jsonrpc": "2.0", "id": env["rpc"].get("id"), "result": {"owner": env["coucou_owner"], "method": env["rpc"]["method"]}}

def start(cmd):
    e = dict(os.environ, HOME=home, COUCOU_ROLE="worker", COUCOU_RUNTIME="claude", COUCOU_OWNER="sess-1")
    return subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=e, text=True, bufsize=1)

def send(p, obj):
    p.stdin.write((obj if isinstance(obj, str) else json.dumps(obj)) + "\n"); p.stdin.flush()

def read_line(p, timeout=5):
    out = []
    t = threading.Thread(target=lambda: out.append(p.stdout.readline()), daemon=True)
    t.start(); t.join(timeout)
    return out[0] if out and out[0] else None

for label, cmd in [("python relay", ["/usr/bin/python3", os.path.join(hook_dir, "nb-hook.py"), "--mcp"]),
                   ("shell wrapper", ["/bin/sh", os.path.join(hook_dir, "nb-hook"), "--mcp"])]:
    print(label)
    stop_server = serve(echo)
    seen.clear()
    p = start(cmd)
    send(p, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    line = read_line(p)
    check("a reply arrives while stdin is still open (streams)", line is not None)
    reply = json.loads(line) if line else {}
    check("reply is the app's line, verbatim", reply.get("result", {}).get("method") == "initialize" and reply.get("id") == 1)
    check("owner is the environment's, relayed", reply.get("result", {}).get("owner") == "sess-1")
    env = seen[0] if seen else {}
    check("envelope kind", env.get("coucou_kind") == "mcp")
    check("envelope role, runtime, owner", (env.get("coucou_role"), env.get("coucou_runtime"), env.get("coucou_owner")) == ("worker", "claude", "sess-1"))
    check("envelope carries the rpc", env.get("rpc", {}).get("method") == "initialize")
    send(p, {"jsonrpc": "2.0", "method": "notifications/initialized"})
    send(p, "not json at all")
    send(p, "")
    send(p, {"jsonrpc": "2.0", "id": 9, "result": {}})            # a client response: ignored
    send(p, {"jsonrpc": "2.0", "id": "two", "method": "tools/call", "params": {"name": "report", "arguments": {"line": "x"}}})
    line2 = read_line(p)
    reply2 = json.loads(line2) if line2 else {}
    check("the next reply is for the next request (notification and junk printed nothing)", reply2.get("id") == "two")
    check("the notification reached the app", any(e["rpc"]["method"] == "notifications/initialized" for e in seen))
    check("junk and client responses never reached the app", len(seen) == 3)
    p.stdin.close(); p.wait(timeout=5)
    check("exits when stdin closes", p.returncode == 0)
    stop_server()

print("brain role")
# A threaded fake app: the brain's call is answered after 32 s (past the worker's 30 s limit), like
# ask_user waiting for the user. The worker's identical call must give up at 30 s; the brain's must not.
def serve_threaded(reply_for):
    if os.path.exists(sock_path): os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path); srv.listen(8); srv.settimeout(0.2)
    stop = threading.Event()
    def handle(c):
        buf = b""
        while b"\n" not in buf:
            d = c.recv(65536)
            if not d: break
            buf += d
        env = json.loads(buf.split(b"\n")[0])
        seen.append(env)
        reply = reply_for(env)
        if reply is not None and "id" in env["rpc"]:
            c.sendall((json.dumps(reply) + "\n").encode())
        c.close()
    def loop():
        while not stop.is_set():
            try: c, _ = srv.accept()
            except socket.timeout: continue
            except OSError: break
            threading.Thread(target=handle, args=(c,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()
    return lambda: (stop.set(), srv.close(), os.path.exists(sock_path) and os.unlink(sock_path))

def slow(env):
    if env["rpc"].get("method") == "tools/call":
        time.sleep(32)
    return {"jsonrpc": "2.0", "id": env["rpc"].get("id"), "result": {"role": env["coucou_role"], "owner": env["coucou_owner"]}}

seen.clear()
stop_server = serve_threaded(slow)
def start_role(role, runtime, owner):
    e = dict(os.environ, HOME=home, COUCOU_ROLE=role, COUCOU_RUNTIME=runtime, COUCOU_OWNER=owner)
    return subprocess.Popen(["/usr/bin/python3", os.path.join(hook_dir, "nb-hook.py"), "--mcp"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=e, text=True, bufsize=1)
brain = start_role("brain", "claude-brain", "mochi-brain")
worker = start_role("worker", "claude", "sess-1")
call = {"jsonrpc": "2.0", "id": 21, "method": "tools/call", "params": {"name": "ask_user", "arguments": {}}}
send(brain, call); send(worker, call)
wl = read_line(worker, timeout=36)
check("a worker's tool call still gives up at 30 s", wl is not None and json.loads(wl).get("error", {}).get("message") == "Coucou is not running")
bl = read_line(brain, timeout=10)
bres = json.loads(bl).get("result", {}) if bl else {}
check("the brain's tool call waits past 30 s for its answer", bres.get("role") == "brain")
check("the brain envelope carries role, runtime and owner",
      any((e.get("coucou_role"), e.get("coucou_runtime"), e.get("coucou_owner")) == ("brain", "claude-brain", "mochi-brain") for e in seen))
brain.stdin.close(); worker.stdin.close(); brain.wait(timeout=5); worker.wait(timeout=5)
stop_server()

print("app not running")
p = start(["/usr/bin/python3", os.path.join(hook_dir, "nb-hook.py"), "--mcp"])
send(p, {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {}})
line = read_line(p)
err = json.loads(line) if line else {}
check("an unreachable app gives JSON-RPC error -32000", err.get("error", {}).get("code") == -32000 and err.get("id") == 7)
check("with a plain message", err.get("error", {}).get("message") == "Coucou is not running")
send(p, {"jsonrpc": "2.0", "method": "notifications/initialized"})
send(p, {"jsonrpc": "2.0", "id": 8, "method": "ping"})
line = read_line(p)
check("a notification stays silent, the next request still gets its error", json.loads(line).get("id") == 8 if line else False)
p.stdin.close(); p.wait(timeout=5)

print("app that never answers")
def silent(env): return None
stop_server = serve(silent)
# the relay's own 5 s timeout for non-tool calls
p = start(["/usr/bin/python3", os.path.join(hook_dir, "nb-hook.py"), "--mcp"])
send(p, {"jsonrpc": "2.0", "id": 11, "method": "ping"})
t0 = time.time()
line = read_line(p, timeout=9)
check("a silent app ends in an error within the 5 s timeout", line is not None and time.time() - t0 < 8 and json.loads(line).get("id") == 11)
p.stdin.close(); p.wait(timeout=5)
stop_server()

print("")
if failures == 0: print("All tests passed.")
else:
    print(f"{failures} test(s) failed."); sys.exit(1)
