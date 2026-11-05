#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-model-client.XXXXXX")"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TEST_DIR"; }
trap cleanup EXIT
MODULE_CACHE="${SWIFT_MODULECACHE_PATH:-$PWD/.tmp/module-cache}"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MODULE_CACHE}"
mkdir -p "$MODULE_CACHE"
# The brain's model clients against a fake server (tests/fake_llm.py): no provider, no key, no network.
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/AgentSession.swift \
    NotchBuddy/Sources/App/AssistantLogic.swift \
    NotchBuddy/Sources/App/SafeWebURL.swift \
    NotchBuddy/Sources/App/AskQuestion.swift \
    NotchBuddy/Sources/App/ModelClient.swift \
    NotchBuddy/Sources/App/BrainLoop.swift \
    tests/ModelClientTests.swift -o "$TEST_DIR/model-client-tests"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
FAKE_LLM_FIXTURES="$ROOT/tests/fixtures" FAKE_LLM_LOG="$TEST_DIR/requests.log" python3 tests/fake_llm.py "$PORT" &
SERVER_PID=$!
disown
for _ in $(seq 1 50); do (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
FAKE_LLM_PORT="$PORT" FAKE_LLM_LOG="$TEST_DIR/requests.log" "$TEST_DIR/model-client-tests"
