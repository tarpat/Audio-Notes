#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p "$ROOT/.build/module-cache" "$ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
swift build -c release --scratch-path "$ROOT/.build"
swift "$ROOT/scripts/create-icon.swift" "$ROOT/Resources/AppIcon.icns"
APP="$ROOT/.build/Audio Notes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/LectureRecorder" "$APP/Contents/MacOS/LectureRecorder"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
open "$APP"
