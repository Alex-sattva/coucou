#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Unix socket paths are limited to ~100 bytes: keep the throwaway HOME short.
TEST_DIR="$(mktemp -d /tmp/cmcp.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/hook" "$TEST_DIR/h"
# The relay scripts live inside HookServer.swift as Swift string literals: extract the real ones
# (un-escaping `\\` the way the compiler does) so this tests what Coucou installs.
python3 -I - "$TEST_DIR/hook" <<'PY'
import re, sys
src = open("NotchBuddy/Sources/App/HookServer.swift").read()
def literal(name):
    m = re.search(r'private let ' + name + r' = """\n(.*?)\n"""', src, re.S)
    return m.group(1).replace("\\\\", "\\")
open(sys.argv[1] + "/nb-hook", "w").write(literal("nbHookShellWrapper") + "\n")
open(sys.argv[1] + "/nb-hook.py", "w").write(literal("nbHookPythonGitHub") + "\n")
PY
chmod +x "$TEST_DIR/hook/nb-hook" "$TEST_DIR/hook/nb-hook.py"
python3 -I tests/mcp_relay_test.py "$TEST_DIR/hook" "$TEST_DIR/h"
