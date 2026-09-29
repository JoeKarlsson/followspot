#!/usr/bin/env bash
# Build a self-contained whisper-server for the macOS app.
#
#   macos/build-whisper.sh        # → macos/.whisper/whisper-server
#
# Static (no dylibs) with the Metal shaders embedded, so the binary can be
# copied into the app bundle on its own. Pinned to the same whisper.cpp tag
# as CI.
set -euo pipefail

cd "$(dirname "$0")"
VERSION="${WHISPER_CPP_VERSION:-v1.9.4}"
SRC=".whisper/whisper.cpp-${VERSION}"

if ! command -v cmake >/dev/null; then
  echo "cmake not found: brew install cmake" >&2
  exit 1
fi

if [[ ! -d "$SRC" ]]; then
  mkdir -p .whisper
  git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp "$SRC"
fi

# A CMake cache from another checkout path refuses to reconfigure; start over.
if [[ -f "$SRC/build/CMakeCache.txt" ]] \
  && ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$(cd "$SRC" && pwd)" "$SRC/build/CMakeCache.txt"; then
  rm -rf "$SRC/build"
fi

cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF \
  -DWHISPER_BUILD_TESTS=OFF
cmake --build "$SRC/build" -j --target whisper-server

cp "$SRC/build/bin/whisper-server" .whisper/whisper-server
echo "Built macos/.whisper/whisper-server"
otool -L .whisper/whisper-server | tail -n +2
