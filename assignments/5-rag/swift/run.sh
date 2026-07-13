#!/bin/sh
#
# Build (via xcodebuild) and run the `rag` CLI with MLX's Metal library on the search path.
#
# Why xcodebuild instead of `swift run`: mlx-swift compiles its Metal shaders with a
# build-tool plugin that only runs under Xcode's build system. A plain `swift build`
# produces no `default.metallib`, so `swift run` fails at runtime with
# "Failed to load the default metallib". Building through xcodebuild compiles the
# metallib and bundles it next to the dylibs in PackageFrameworks; we point
# DYLD_FRAMEWORK_PATH there — exactly what mlx-swift-examples' own `mlx-run` does.
#
# Usage:
#   ./run.sh [args…]              # e.g. ./run.sh search "What is the Sun?"
#   ./run.sh --rebuild [args…]    # force a rebuild first
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG=Release
DERIVED_DATA="$ROOT/.build/xcode"
PRODUCTS="$DERIVED_DATA/Build/Products/$CONFIG"
SCHEME=rag
BIN="$PRODUCTS/$SCHEME"

REBUILD=0
if [ "$1" = "--rebuild" ]; then REBUILD=1; shift; fi
[ "$REBUILD" = 1 ] && rm -f "$BIN"

if [ ! -x "$BIN" ]; then
	echo "Building $SCHEME ($CONFIG) via xcodebuild …" >&2
	xcodebuild -quiet -scheme "$SCHEME" -configuration "$CONFIG" \
		-derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS,arch=arm64' \
		-skipPackagePluginValidation -skipMacroValidation build >&2
fi

export DYLD_FRAMEWORK_PATH="$PRODUCTS/PackageFrameworks:$PRODUCTS"
exec "$BIN" "$@"
