#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-stream-process.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
MODULE_CACHE="${SWIFT_MODULECACHE_PATH:-$PWD/.tmp/module-cache}"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MODULE_CACHE}"
mkdir -p "$MODULE_CACHE"
# ClaudeStreamProcess drives `claude`; here that is a fake (tests/fake_claude.py) found through a
# throwaway HOME, so the real CLI and the real login are never touched.
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/AgentSession.swift \
    NotchBuddy/Sources/App/AssistantLogic.swift \
    NotchBuddy/Sources/App/SafeWebURL.swift \
    NotchBuddy/Sources/App/AskQuestion.swift \
    NotchBuddy/Sources/App/PipeBuffer.swift \
    NotchBuddy/Sources/App/ClaudeCodeRun.swift \
    NotchBuddy/Sources/App/ClaudeStreamProcess.swift \
    tests/StreamProcessTests.swift -o "$TEST_DIR/stream-process-tests"
mkdir -p "$TEST_DIR/home/.local/bin"
cp "$ROOT/tests/fake_claude.py" "$TEST_DIR/home/.local/bin/claude"
chmod +x "$TEST_DIR/home/.local/bin/claude"
HOME="$TEST_DIR/home" PATH="/usr/bin:/bin" FAKE_CLAUDE_LOG="$TEST_DIR/fake-claude.log" \
    "$TEST_DIR/stream-process-tests"
