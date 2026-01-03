#!/usr/bin/env bash
set -euo pipefail

: "${STREAM_ID:?Missing STREAM_ID}"

BASE="/out/${STREAM_ID}"
MPD="${BASE}/dash/manifest.mpd"
HLS="${BASE}/hls/master.m3u8"
HB="${BASE}/stitcher_heartbeat.txt"

test -f "${MPD}"
test -f "${HLS}"
test -f "${HB}"

now=$(date +%s)
mpd_mtime=$(date +%s -r "${MPD}")
hls_mtime=$(date +%s -r "${HLS}")
hb_mtime=$(date +%s -r "${HB}")

# Must be fresh (within last 120s)
test $((now - mpd_mtime)) -lt 120
test $((now - hls_mtime)) -lt 120
test $((now - hb_mtime)) -lt 120