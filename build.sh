#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
toolchain="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
destination="${1:-$source_dir/build/Prism XR.app}"

if [[ -e "$destination" ]]; then
    printf 'Build destination already exists: %s\n' "$destination" >&2
    exit 1
fi
if [[ ! -x "$toolchain/swiftc" || ! -d "$sdk" ]]; then
    printf 'Set DEVELOPER_DIR to an Xcode 27 developer directory.\n' >&2
    exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Prism XR.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

"$toolchain/clang" -fobjc-arc -isysroot "$sdk" -mmacosx-version-min=27.0 \
    -c "$source_dir/Sources/PrismVirtualDisplay.m" -o "$stage/VirtualDisplay.o"
"$toolchain/swiftc" -swift-version 6 -sdk "$sdk" -target arm64-apple-macosx27.0 \
    -O -j 4 -module-name PrismXR -import-objc-header "$source_dir/Sources/PrismVirtualDisplay.h" \
    "$source_dir"/Sources/*.swift "$stage/VirtualDisplay.o" -framework Cocoa -framework CoreGraphics \
    -o "$bundle/Contents/MacOS/Prism XR"

"$toolchain/coremlc" compile \
    "$source_dir/Resources/DepthAnythingV2SmallF16P6.mlpackage" "$bundle/Contents/Resources"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
cp "$source_dir/Resources/Prism.icns" "$source_dir/Resources/Apache-2.0.txt" "$source_dir/Resources/DeskPad-MIT.txt" "$bundle/Contents/Resources/"
/usr/bin/codesign --force --sign - --options runtime "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
mkdir -p "$(dirname "$destination")"
mv "$bundle" "$destination"
printf '%s\n' "$destination"
