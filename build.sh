#!/bin/sh
# Build Quiet Driver. One Swift toolchain, one binary, no other build system.
#
#   ./build.sh            build, test, and refresh ./Quiet Driver.app
#   ./build.sh --install  also install into /Applications
#
# The binary is the whole driver: the daemon, the per-app worker, the MCP stdio
# bridge and the dashboard are modes of the same executable.
set -eu
cd "$(dirname "$0")"

INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1
APP="Quiet Driver.app"
mkdir -p .build

SOURCES=$(find Sources -name '*.swift' | sort)
LIBRARY=$(find Sources -name '*.swift' ! -name 'main.swift' | sort)

echo "== self-tests"
# shellcheck disable=SC2086
swiftc -O -o .build/selftest $LIBRARY Tests/main.swift
./.build/selftest

echo "== driver"
# shellcheck disable=SC2086
swiftc -O -o .build/quiet-driver $SOURCES

echo "== bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/quiet-driver "$APP/Contents/MacOS/agent-driver"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/docs"
cp docs/preview.png "$APP/Contents/Resources/docs/preview.png" 2>/dev/null || true

if [ "$INSTALL" = "1" ]; then
  echo "== install"
  # Stop the running daemon *and its workers*. A daemon keeps its worker
  # children alive for its whole life, so leaving one running means the next
  # test measures the old worker while believing it is the new one.
  pkill -f "Quiet Driver.app/Contents/MacOS/agent-driver" 2>/dev/null || true
  sleep 1.5
  rm -rf "/Applications/$APP"
  cp -R "$APP" "/Applications/$APP"
  # The daemon is an agent process: it must never take focus on launch.
  echo "installed /Applications/$APP"
fi

echo "built $APP"
