#!/bin/sh
# Build Quiet Driver: the Rust dashboard plus the compiled Swift helper, then
# refresh the app bundle. Requires cargo and the macOS Swift toolchain.
#
#   ./build.sh            build and refresh ./Quiet Driver.app
#   ./build.sh --install  also install into /Applications
set -eu
cd "$(dirname "$0")"

INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

echo "== helper"
mkdir -p .build
swiftc -O -o .build/quiet-driver-helper swift/helper.swift

echo "== driver"
cargo build --release
cargo test --release -q

echo "== bundle"
APP="Quiet Driver.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp target/release/agent-driver "$APP/Contents/MacOS/agent-driver"
cp .build/quiet-driver-helper "$APP/Contents/MacOS/quiet-driver-helper"
cp swift/helper.swift "$APP/Contents/Resources/helper.swift"

if [ "$INSTALL" = "1" ]; then
  echo "== install"
  # Stop the running daemon so the new binary can take the port.
  pkill -f "Quiet Driver.app/Contents/MacOS/agent-driver" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP"
  cp -R "$APP" "/Applications/$APP"
  echo "installed /Applications/$APP"
fi

echo "built $APP"
