#!/bin/sh
set -eu

if [ -z "${ICECAST_URL:-}" ]; then
  echo "ICECAST_URL not set" >&2
  exit 1
fi

# Temporary probe to ensure source is reachable (5 second timeout)
if ! timeout 5 wget -q --spider "$ICECAST_URL" 2>/dev/null; then
  echo "Warning: Could not reach $ICECAST_URL (continuing, ffmpeg may retry)" >&2
fi

SEG_DIR=/output
mkdir -p "$SEG_DIR"

# Use strftime-based filenames (UTC) for deterministic time-based navigation.
# Example filename: 20240915T142300Z.ts

# Derive next HLS media sequence number from existing playlist if available.
# Priority:
# 1. Parse existing EXT-X-MEDIA-SEQUENCE + number of listed segments.
# 2. Count existing segment files.
# 3. Fallback to 0.
START_NUM=0
if [ -f /output/playlist.m3u8 ]; then
  BASE_SEQ=$(grep -E "^#EXT-X-MEDIA-SEQUENCE:" /output/playlist.m3u8 | tail -n1 | cut -d: -f2 || true)
  SEG_LINES=$(grep -E "\.ts$" /output/playlist.m3u8 | wc -l | tr -d ' ' || true)
  if [ -n "${BASE_SEQ}" ] && [ "$SEG_LINES" -gt 0 ]; then
    # Next sequence after last listed segment
    START_NUM=$((BASE_SEQ + SEG_LINES))
  fi
fi
if [ "$START_NUM" -eq 0 ]; then
  TOTAL_TS=$(ls -1 "$SEG_DIR"/*.ts 2>/dev/null | wc -l | tr -d ' ' || true)
  if [ "$TOTAL_TS" -gt 0 ]; then
    START_NUM=$TOTAL_TS
  fi
fi
echo "Calculated start sequence: $START_NUM" >&2

## (LL-HLS support removed) ##

exec ffmpeg -hide_banner -loglevel info \
  -i "$ICECAST_URL" \
  -c:a aac -b:a 128k \
  -f hls \
  -hls_time 15 \
  -hls_list_size 1440 \
  -hls_flags delete_segments+program_date_time+append_list \
  -start_number $START_NUM \
  -strftime 1 \
  -hls_segment_filename "$SEG_DIR/%Y%m%dT%H%M%S.ts" \
  /output/playlist.m3u8
