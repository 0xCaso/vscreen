#!/bin/sh
# Builds build/vscreen, build/libvscreen_place.dylib (injected by `vscreen launch`)
# and build/fpsprobe (a test window that logs frames/s).
# PREFIX=<dir> ./build.sh also installs vscreen and the dylib there (e.g. PREFIX=~/.local/bin).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/build"
mkdir -p "$out"
xcrun swiftc -O -swift-version 5 -import-objc-header "$here/Sources/CGVirtualDisplay.h" \
  -framework CoreGraphics -framework AppKit -framework ApplicationServices \
  "$here/Sources/main.swift" -o "$out/vscreen"
xcrun clang -dynamiclib -fobjc-arc -O2 -framework AppKit "$here/Sources/place.m" -o "$out/libvscreen_place.dylib"
xcrun swiftc -O -swift-version 5 "$here/probe/main.swift" -o "$out/fpsprobe"
if [ -n "${PREFIX:-}" ]; then
  mkdir -p "$PREFIX"
  cp "$out/vscreen" "$out/libvscreen_place.dylib" "$PREFIX/"
  echo "installed vscreen to $PREFIX"
fi
echo "built $out/vscreen and $out/fpsprobe"
