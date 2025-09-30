#!/bin/sh
set -eu

if [ -z "${ICECAST_URL:-}" ]; then
  echo "ICECAST_URL not set" >&2
  exit 1
fi

###############################################################################
# MPEG-DASH + HLS Icecast -> Time‑Shift Encoder
# Requirements implemented:
#  - Input: ICECAST_URL (env)
#  - Output: MPEG-DASH (manifest.mpd, segment_<N>.m4s) + HLS (playlist.m3u8, segment_<N>.ts)
#  - 6 hours rolling history, 30s segments => 6h * 60 / 0.5 = 720 segments retained
#  - Numeric segment naming with continuity after restart
#  - Pruning of segments older than rolling window
#  - Timestamp data so a player can map wall-clock -> segment (segments-index.json + hls-index.json)
###############################################################################

SEG_DIR=/output
DASH_DIR="$SEG_DIR/dash"
HLS_DIR="$SEG_DIR/hls"
mkdir -p "$SEG_DIR"
mkdir -p "$DASH_DIR"
mkdir -p "$HLS_DIR"

SEG_DURATION=60            # seconds per segment
WINDOW_HOURS=6
MAX_SEGMENTS=$((WINDOW_HOURS * 3600 / SEG_DURATION))  # 360 for 6h @ 60s

echo "Starting DASH encoder: ${WINDOW_HOURS}h window, $SEG_DURATION s segments, retain $MAX_SEGMENTS segments" >&2

# Persistent numeric continuity
COUNTER_FILE="$DASH_DIR/segment_counter.state"
START_NUMBER=1
if [ -f "$COUNTER_FILE" ]; then
  LAST=$(grep -E '^[0-9]+$' "$COUNTER_FILE" | tail -n1 || true)
  if [ -n "$LAST" ]; then
    START_NUMBER=$((LAST + 1))
  fi
fi
echo "Continuing at segment index $START_NUMBER" >&2
echo "$START_NUMBER" > "$COUNTER_FILE"

# Clean stray zero-sized init segments
find "$DASH_DIR" -maxdepth 1 -name 'init.m4s' -size 0c -delete 2>/dev/null || true
find "$HLS_DIR" -maxdepth 1 -name '*.ts' -size 0c -delete 2>/dev/null || true

# Helper: ISO8601 UTC formatting for epoch
iso_utc() {
  # usage: iso_utc <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @"$1" +%Y-%m-%dT%H:%M:%SZ
}

# Background pruning using modification time (oldest first) to decide deletions.
prune_loop() {
  while true; do
    # Prune DASH segments
    FILES=$(ls -1 "$DASH_DIR"/segment_*.m4s 2>/dev/null || true)
    COUNT=$(echo "$FILES" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$COUNT" -gt "$MAX_SEGMENTS" ]; then
      REMOVE=$((COUNT - MAX_SEGMENTS))
      # Build epoch filename list, sort by epoch ascending, delete oldest REMOVE
      ls -1 "$DASH_DIR"/segment_*.m4s 2>/dev/null | while read -r f; do [ -f "$f" ] || continue; mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f"); echo "$mt $f"; done \
        | sort -n | head -n "$REMOVE" | awk '{print $2}' | xargs -r rm -f --
    fi
    
    # Prune HLS segments (timestamp-named)
    HLS_FILES=$(ls -1 "$HLS_DIR"/*.ts 2>/dev/null | grep -E '[0-9]{2}-[0-9]{2}-[0-9]{2}\.ts$' || true)
    HLS_COUNT=$(echo "$HLS_FILES" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$HLS_COUNT" -gt "$MAX_SEGMENTS" ]; then
      HLS_REMOVE=$((HLS_COUNT - MAX_SEGMENTS))
      # Build epoch filename list, sort by epoch ascending, delete oldest REMOVE
      ls -1 "$HLS_DIR"/*.ts 2>/dev/null | grep -E '[0-9]{2}-[0-9]{2}-[0-9]{2}\.ts$' | while read -r f; do [ -f "$f" ] || continue; mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f"); echo "$mt $f"; done \
        | sort -n | head -n "$HLS_REMOVE" | awk '{print $2}' | xargs -r rm -f --
    fi
    
    sleep "$SEG_DURATION"
  done
}
prune_loop &

# Mapping / metadata generator: index-dash.json, index-hls.json AND timeshift-meta.json
mapping_loop() {
  while true; do
    TMP_MAP="$SEG_DIR/index-dash.tmp"
    OUT_MAP="$SEG_DIR/index-dash.json"
    HLS_TMP_MAP="$SEG_DIR/index-hls.tmp"
    HLS_OUT_MAP="$SEG_DIR/index-hls.json"
    TMP_META="$SEG_DIR/timeshift-meta.tmp"
    OUT_META="$SEG_DIR/timeshift-meta.json"

    # Enumerate newest DASH segment files (may be fewer during startup)
    SEG_FILES=$(ls -1 "$DASH_DIR"/segment_*.m4s 2>/dev/null | sed -E 's/.*segment_([0-9]+)\.m4s/\1 segment_\1.m4s/' | sort -n | tail -n "$MAX_SEGMENTS" || true)
    
    # Enumerate newest HLS segment files (timestamp-named)
    HLS_SEG_FILES=$(ls -1 "$HLS_DIR"/*.ts 2>/dev/null | grep -E '[0-9]{2}-[0-9]{2}-[0-9]{2}\.ts$' | sort -t- -k1,1n -k2,2n -k3,3n | tail -n "$MAX_SEGMENTS" || true)

    # Generate DASH segments index
    printf '[' > "$TMP_MAP"
    FIRST=1
    EARLIEST_INDEX=""
    LATEST_INDEX=""
    NOW_EPOCH=$(date -u +%s)
    echo "$SEG_FILES" | while read -r LINE; do
      [ -n "$LINE" ] || continue
      IDX=$(echo "$LINE" | awk '{print $1}')
      FILE=$(echo "$LINE" | awk '{print $2}')
      PATH_F="$DASH_DIR/$FILE"
      [ -f "$PATH_F" ] || continue
      # Use mtime as segment END; derive START = end - SEG_DURATION
      END_EPOCH=$(stat -c %Y "$PATH_F" 2>/dev/null || stat -f %m "$PATH_F")
      START_EPOCH=$((END_EPOCH - SEG_DURATION))
      [ -z "$EARLIEST_INDEX" ] && EARLIEST_INDEX=$IDX
      LATEST_INDEX=$IDX
      START_ISO=$(iso_utc "$START_EPOCH")
      END_ISO=$(iso_utc "$END_EPOCH")
      if [ $FIRST -eq 0 ]; then printf ',' >> "$TMP_MAP"; fi
      FIRST=0
      printf '\n  {"index":%s,"file":"%s","start_utc":"%s","end_utc":"%s"}' "$IDX" "$FILE" "$START_ISO" "$END_ISO" >> "$TMP_MAP"
    done
    printf '\n]\n' >> "$TMP_MAP"
    mv -f "$TMP_MAP" "$OUT_MAP"

    # Generate HLS segments index
    printf '[' > "$HLS_TMP_MAP"
    HLS_FIRST=1
    HLS_EARLIEST_TIMESTAMP=""
    HLS_LATEST_TIMESTAMP=""
    echo "$HLS_SEG_FILES" | while read -r FULL_PATH; do
      [ -n "$FULL_PATH" ] || continue
      [ -f "$FULL_PATH" ] || continue
      FILE=$(basename "$FULL_PATH")
      # Extract timestamp from filename (HH-MM-SS.ts)
      TIMESTAMP=$(echo "$FILE" | sed -E 's/([0-9]{2}-[0-9]{2}-[0-9]{2})\.ts/\1/')
      # Use mtime as segment END; derive START = end - SEG_DURATION
      END_EPOCH=$(stat -c %Y "$FULL_PATH" 2>/dev/null || stat -f %m "$FULL_PATH")
      START_EPOCH=$((END_EPOCH - SEG_DURATION))
      [ -z "$HLS_EARLIEST_TIMESTAMP" ] && HLS_EARLIEST_TIMESTAMP=$TIMESTAMP
      HLS_LATEST_TIMESTAMP=$TIMESTAMP
      START_ISO=$(iso_utc "$START_EPOCH")
      END_ISO=$(iso_utc "$END_EPOCH")
      if [ $HLS_FIRST -eq 0 ]; then printf ',' >> "$HLS_TMP_MAP"; fi
      HLS_FIRST=0
      printf '\n  {"timestamp":"%s","file":"%s","start_utc":"%s","end_utc":"%s"}' "$TIMESTAMP" "$FILE" "$START_ISO" "$END_ISO" >> "$HLS_TMP_MAP"
    done
    printf '\n]\n' >> "$HLS_TMP_MAP"
    mv -f "$HLS_TMP_MAP" "$HLS_OUT_MAP"

    # Meta file summarizing window
    GEN_ISO=$(iso_utc "$NOW_EPOCH")
    cat > "$TMP_META" <<EOF
{
  "generated_utc": "$GEN_ISO",
  "segment_duration": $SEG_DURATION,
  "window_hours": $WINDOW_HOURS,
  "max_segments": $MAX_SEGMENTS,
  "dash": {
    "earliest_index": ${EARLIEST_INDEX:-null},
    "latest_index": ${LATEST_INDEX:-null}
  },
  "hls": {
    "earliest_timestamp": "${HLS_EARLIEST_TIMESTAMP:-}",
    "latest_timestamp": "${HLS_LATEST_TIMESTAMP:-}"
  }
}
EOF
    mv -f "$TMP_META" "$OUT_META"

    sleep "$SEG_DURATION"
  done
}
mapping_loop &

# Update counter file periodically to reflect progress (resilience on abrupt stop)
counter_flush_loop() {
  while true; do
    # Use DASH segments as reference for counter (they should be in sync)
    LAST_FILE=$(ls -1 "$DASH_DIR"/segment_*.m4s 2>/dev/null | sed -E 's/.*segment_([0-9]+)\.m4s/\1 segment_\1.m4s/' | sort -n | tail -n1 | awk '{print $1}' || true)
    [ -n "$LAST_FILE" ] && echo "$LAST_FILE" > "$COUNTER_FILE"
    sleep 30
  done
}
counter_flush_loop &

echo "Launching ffmpeg with DASH + HLS output..." >&2
exec ffmpeg -hide_banner -loglevel info \
  -i "$ICECAST_URL" \
  -fflags +genpts \
  -avoid_negative_ts make_zero \
  -c:a aac -b:a 128k -ar 48000 -ac 2 \
  -f dash \
  -seg_duration $SEG_DURATION \
  -use_template 1 -use_timeline 1 \
  -single_file 0 \
  -window_size $MAX_SEGMENTS \
  -extra_window_size 10 \
  -start_number $START_NUMBER \
  -adaptation_sets "id=0,streams=a" \
  -init_seg_name "init.m4s" \
  -media_seg_name "segment_\$Number\$.m4s" \
  -write_prft 1 \
  "$DASH_DIR/manifest.mpd" \
  -c:a aac -b:a 128k -ar 48000 -ac 2 \
  -f hls \
  -hls_time $SEG_DURATION \
  -hls_list_size $MAX_SEGMENTS \
  -hls_flags program_date_time \
  -hls_segment_filename "$HLS_DIR/%H-%M-%S.ts" \
  -strftime 1 \
  -strftime_mkdir 0 \
  "$HLS_DIR/playlist.m3u8"
