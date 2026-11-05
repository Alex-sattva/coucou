#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-opencode-server.XXXXXX")"
cleanup() { pkill -f "$TEST_DIR/fake-opencode" 2>/dev/null || true; rm -rf "$TEST_DIR"; }
trap cleanup EXIT
MODULE_CACHE="${SWIFT_MODULECACHE_PATH:-$PWD/.tmp/module-cache}"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MODULE_CACHE}"
mkdir -p "$MODULE_CACHE"
# The server code is driven against a fake `opencode` (tests/fake_opencode.py): no real OpenCode,
# no login, no model call.
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/AgentSession.swift \
    NotchBuddy/Sources/App/AskQuestion.swift \
    NotchBuddy/Sources/App/OpenCodeEvents.swift \
    NotchBuddy/Sources/App/OpenCodeServer.swift \
    tests/OpenCodeServerTests.swift -o "$TEST_DIR/opencode-server-tests"
cp tests/fake_opencode.py "$TEST_DIR/fake-opencode"
chmod +x "$TEST_DIR/fake-opencode"
FAKE_OPENCODE_CLI="$TEST_DIR/fake-opencode" FAKE_OPENCODE_LOG="$TEST_DIR/requests.log" \
    FAKE_OPENCODE_FIXTURE="$ROOT/tests/fixtures/opencode-events.txt" \
    "$TEST_DIR/opencode-server-tests"
