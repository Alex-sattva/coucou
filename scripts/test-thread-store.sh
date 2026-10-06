#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-thread-store.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# Keep clang's module cache inside the checkout. On a machine whose only toolchain is
# the Command Line Tools the default cache lands somewhere the sandbox refuses to
# write, and the compiler dies with "Operation not permitted".
MODULE_CACHE="${SWIFT_MODULECACHE_PATH:-$PWD/.tmp/module-cache}"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MODULE_CACHE}"
mkdir -p "$MODULE_CACHE"
# `ThreadStore.swift` owns `HarnessThread` and imports only Combine + Foundation;
# `WorkspaceRouting.swift` supplies `KeywordRouter.normalize`, which the store's
# search reuses. Neither pulls in AppKit or SwiftUI, so both compile standalone.
# `-swift-version 6 -strict-concurrency=complete` mirrors `NotchBuddy/project.yml`, so the
# suite is checked in the same language mode the app ships in.
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/WorkspaceRouting.swift \
    NotchBuddy/Sources/App/ThreadStore.swift \
    tests/ThreadStoreTests.swift -o "$TEST_DIR/thread-store-tests"
"$TEST_DIR/thread-store-tests"
