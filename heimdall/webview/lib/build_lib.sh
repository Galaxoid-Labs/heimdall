#!/usr/bin/env bash
# Rebuild libwebview.a / .lib from the vendored upstream source.
# Vendored from webview/webview @ 0.12.0 — see upstream/VENDOR.txt.
#
# Run from this directory:  ./build_lib.sh
set -euo pipefail
cd "$(dirname "$0")"

SRC=upstream/src/webview.cc
INC=upstream/include

case "$(uname -s)" in
  Darwin)
    SDK=$(xcrun --show-sdk-path)
    c++ -std=c++17 -DWEBVIEW_STATIC -I"$INC" -isysroot "$SDK" \
        -c "$SRC" -o /tmp/heimdall_webview.o
    ar rcs libwebview.a /tmp/heimdall_webview.o
    echo "built libwebview.a (macOS)"
    ;;
  Linux)
    # Requires: pkg-config, webkit2gtk-4.1 dev headers.
    c++ -std=c++17 -DWEBVIEW_STATIC -I"$INC" \
        $(pkg-config --cflags webkit2gtk-4.1) \
        -c "$SRC" -o /tmp/heimdall_webview.o
    ar rcs libwebview.a /tmp/heimdall_webview.o
    echo "built libwebview.a (Linux)"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows: build webview.lib with MSVC (cl /std:c++17 /DWEBVIEW_STATIC ...)." >&2
    echo "Not yet automated — see DEVELOPMENT.md Phase 7." >&2
    exit 1
    ;;
  *)
    echo "Unsupported platform: $(uname -s)" >&2
    exit 1
    ;;
esac
