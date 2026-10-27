#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pkill -x Umak 2>/dev/null || true
sleep 0.4

open -n "$ROOT/build/Umak.app" --args --fake-music --demo
sleep "${DEMO_CAPTURE_DELAY:-6}"
mkdir -p "$ROOT/build"
screencapture -x "$ROOT/build/demo.png"
sleep 3
pkill -x Umak 2>/dev/null || true
echo "Captured $ROOT/build/demo.png"
