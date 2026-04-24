#!/bin/bash

set -euo pipefail
shopt -s nullglob

swift build --disable-sandbox -c release
codesign --entitlements Sources/MiniboxRun/entitlements.plist -s - .build/release/minibox-run

