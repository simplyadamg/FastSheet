#!/bin/zsh
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
swift build -c release
APP="$ROOT/FinderStack.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/arm64-apple-macosx/release/FinderStack" "$APP/Contents/MacOS/FinderStack"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
echo "Built $APP"
