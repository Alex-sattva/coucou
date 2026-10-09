#!/usr/bin/env python3
"""A fake `claude` for scripts/test-stream-process.sh.

Mimics `claude -p --input-format stream-json --output-format stream-json`: prints a system/init
line, then one `result` line per user line on stdin, and a control_response per control_request.
Every raw stdin line is appended to $FAKE_CLAUDE_LOG; the argv to $FAKE_CLAUDE_LOG.args, the MCP-related environment to $FAKE_CLAUDE_LOG.env.
FAKE_CLAUDE_STUBBORN=1: ignores EOF on stdin, so only SIGTERM stops it.
"""
import json, os, sys, time

log = os.environ.get("FAKE_CLAUDE_LOG")
if log:
    with open(log + ".args", "w") as f:
        f.write(json.dumps(sys.argv[1:]))
    with open(log + ".env", "w") as f:
        f.write(json.dumps({k: v for k, v in os.environ.items() if k.startswith("MCP_") or k.startswith("CLAUDE_CODE_MCP")}))

def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

out({"type": "system", "subtype": "init", "session_id": "fake", "cwd": os.getcwd()})
sys.stderr.write("fake claude started\n")
sys.stderr.flush()

for line in sys.stdin:
    if log:
        with open(log, "a") as f:
            f.write(line)
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if msg.get("type") == "user":
        text = msg["message"]["content"]
        out({"type": "result", "subtype": "success", "is_error": False, "result": "echo: " + text})
    elif msg.get("type") == "control_request":
        out({"type": "control_response",
             "response": {"subtype": "success", "request_id": msg.get("request_id"), "response": {}}})

if os.environ.get("FAKE_CLAUDE_STUBBORN") == "1":
    while True:
        time.sleep(0.2)
