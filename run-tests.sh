#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
mkdir -p "$ROOT_DIR/.build/selftest" "$ROOT_DIR/.build/clang-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-cache"
ARCH="$(uname -m)"
SWIFTC_SDK_ARGS=()
if [[ -n "${SDKROOT:-}" ]]; then
  SWIFTC_SDK_ARGS=(-sdk "$SDKROOT")
fi
swiftc \
  "${SWIFTC_SDK_ARGS[@]}" \
  -target "$ARCH-apple-macosx13.0" \
  "$ROOT_DIR/Sources/WindowSnap/LayoutEngine.swift" \
  "$ROOT_DIR/Tests/LayoutEngineSelfTest.swift" \
  -o "$ROOT_DIR/.build/selftest/LayoutEngineSelfTest"
"$ROOT_DIR/.build/selftest/LayoutEngineSelfTest"
