#!/bin/sh
# Build Quiet Driver: the Rust dashboard plus the compiled Swift helper, then
# refresh the app bundle. Requires cargo and the macOS Swift toolchain.
set -eu
cd "$(dirname "$0")"

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
echo "built $APP"
