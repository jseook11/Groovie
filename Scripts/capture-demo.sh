#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pkill -x Groovie 2>/dev/null || true
sleep 0.4

open -n "$ROOT/build/Groovie.app" --args --fake-music --demo
sleep "${DEMO_CAPTURE_DELAY:-6}"
mkdir -p "$ROOT/build"
screencapture -x "$ROOT/build/demo.png"
sleep 3
pkill -x Groovie 2>/dev/null || true
echo "Captured $ROOT/build/demo.png"
