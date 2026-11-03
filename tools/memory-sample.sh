#!/bin/bash
# Writes the memory of the running Easy once a minute, as CSV, until Ctrl+C: a long session's curve to look at.
#
#   tools/memory-sample.sh                      every 60 s, to the terminal
#   tools/memory-sample.sh 30 session.csv       every 30 s, to the terminal and to session.csv
#
# footprint_mb is the physical footprint from vmmap, the figure Activity Monitor shows as "Memory"; rss_mb is
# the resident size from ps, which counts shared pages too and is only there for when vmmap cannot read the
# process. See docs/MEMORY.md for what to do between the samples. Written for the bash 3.2 macOS ships.
set -u
INTERVAL=${1:-60}
OUT=${2:-}
PATTERN="Easy.app/Contents/MacOS/SwiftLite"

PID=$(pgrep -f "$PATTERN" | head -1)
if [ -z "$PID" ]; then
  echo "Easy is not running (no process matches $PATTERN)" >&2
  exit 1
fi
echo "sampling Easy (pid $PID) every ${INTERVAL}s; Ctrl+C to stop" >&2

emit() {
  echo "$1"
  if [ -n "$OUT" ]; then echo "$1" >> "$OUT"; fi
}

[ -n "$OUT" ] && : > "$OUT"
emit "time,footprint_mb,rss_mb"
while kill -0 "$PID" 2>/dev/null; do
  # "Physical footprint:  171.2M" -> 171.2 (K, M and G suffixes)
  footprint=$(vmmap -summary "$PID" 2>/dev/null | awk '
    /^Physical footprint:/ {
      v = $3; u = substr(v, length(v)); n = substr(v, 1, length(v) - 1) + 0
      if (u == "K") n /= 1024; else if (u == "G") n *= 1024; else if (u != "M") exit
      printf "%.1f", n; exit
    }')
  rss=$(ps -o rss= -p "$PID" | awk '{ printf "%.1f", $1 / 1024 }')
  emit "$(date '+%Y-%m-%d %H:%M:%S'),$footprint,$rss"
  sleep "$INTERVAL"
done
echo "Easy (pid $PID) has quit" >&2
