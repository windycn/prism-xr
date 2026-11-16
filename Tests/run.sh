#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
"$compiler" -swift-version 6 -O -sdk "$sdk" "$root/Sources/OrientationFusion.swift" "$root/Tests/FusionRegression.swift" -o "$stage/fusion"
"$stage/fusion"
"$compiler" -swift-version 6 -O -sdk "$sdk" "$root/Sources/SpatialCursorRouter.swift" "$root/Tests/CursorRegression.swift" -o "$stage/cursor"
"$stage/cursor"
"$compiler" -swift-version 6 -O -j 4 -sdk "$sdk" "$root/Sources/Workspace.swift" "$root/Sources/CustomLayouts.swift" "$root/Tests/MirrorRegression.swift" -o "$stage/mirror"
"$stage/mirror"
"$compiler" -swift-version 6 -O -sdk "$sdk" "$root/Sources/SpatialFrames.swift" "$root/Tests/FrameEpochRegression.swift" -o "$stage/frames"
"$stage/frames"
if [[ "${1:-}" == "--gpu" ]]; then
  "$compiler" -swift-version 6 -O -sdk "$sdk" "$root/Sources/Workspace.swift" "$root/Sources/CustomLayouts.swift" "$root/Sources/OrientationFusion.swift" "$root/Sources/RayneoTracker.swift" "$root/Sources/SpatialFrames.swift" "$root/Sources/SpatialMetalView.swift" "$root/Tests/MetalRegression.swift" -o "$stage/metal"
  "$stage/metal"
fi
if [[ "${1:-}" == "--hardware" ]]; then
  "$compiler" -swift-version 6 -O -sdk "$sdk" "$root/Sources/OrientationFusion.swift" "$root/Sources/RayneoTracker.swift" "$root/Tests/TrackerRegression.swift" -o "$stage/tracker"
  "$stage/tracker"
fi

if [[ "${1:-}" == "--pacing" ]]; then
  "$compiler" -swift-version 6 -Onone -j 4 -sdk "$sdk" "$root/Sources/Workspace.swift" "$root/Sources/CustomLayouts.swift" "$root/Sources/OrientationFusion.swift" "$root/Sources/RayneoTracker.swift" "$root/Sources/SpatialFrames.swift" "$root/Sources/SpatialMetalView.swift" "$root/Tests/MetalDriverFPS.swift" -o "$stage/pacing"
  "$stage/pacing"
fi
