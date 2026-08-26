#!/bin/bash
# Regenerate zrk.svg, the animated terminal demo in the README.
#
# Records a real run against the local demo server (docs/demo/server.js), whose
# worker pool saturates partway up the ramp — so the spectrogram shows the
# latency tail opening up rather than a flat line. Needs asciinema and node.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cast=${CAST:-$here/zrk.cast}

command -v asciinema >/dev/null || { echo "need asciinema" >&2; exit 1; }
command -v node >/dev/null || { echo "need node" >&2; exit 1; }

zig build -Doptimize=ReleaseFast --build-file "$root/build.zig"

SLOTS=20 SERVICE_MS=8 node "$here/server.js" >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
sleep 1

ZRK=$root/zig-out/bin/zrk TARGET=http://127.0.0.1:8080/ \
  asciinema rec --overwrite -q --window-size 110x20 -c "$here/session.sh" "$cast"

python3 "$here/cast2svg.py" "$cast" "$root/zrk.svg" --fps 10 \
  --title "zrk ramping load from 400 to 3400 req/s against a saturating service"
