#!/usr/bin/env bash
set -euo pipefail

STREAM_ID="${STREAM_ID:-stream1}"
ICECAST_URL="${ICECAST_URL:-}"

SEGMENT_DURATION="${SEGMENT_DURATION:-5}"
TIME_SHIFT_BUFFER_DEPTH="${TIME_SHIFT_BUFFER_DEPTH:-300}"
PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW="${PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW:-10}"

AUDIO_BITRATE="${AUDIO_BITRATE:-64k}"
AUDIO_SAMPLE_RATE="${AUDIO_SAMPLE_RATE:-48000}"
AUDIO_CHANNELS="${AUDIO_CHANNELS:-2}"

UDP_PORT="${UDP_PORT:-40000}"
UDP_IN="udp://127.0.0.1:${UDP_PORT}"

if [[ -z "${ICECAST_URL}" ]]; then
  echo "ERROR: ICECAST_URL is empty"
  exit 1
fi

OUT_BASE="/output/${STREAM_ID}"
mkdir -p "${OUT_BASE}"

new_run() {
  RUN_ID="$(date -u +%s)"
  RUN_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat > "${OUT_BASE}/run_${RUN_ID}.json" <<EOF
{
  "run_id": "${RUN_ID}",
  "start_utc": "${RUN_START_UTC}",
  "segment_duration": ${SEGMENT_DURATION},
  "start_segment_number": 1
}
EOF
}

new_run

echo "===================================================="
echo "STREAM_ID: ${STREAM_ID}"
echo "ICECAST_URL: ${ICECAST_URL}"
echo "Segment duration: ${SEGMENT_DURATION}s"
echo "Time-shift buffer depth: ${TIME_SHIFT_BUFFER_DEPTH}s"
echo "Audio: AAC-LC ${AUDIO_BITRATE}, ${AUDIO_SAMPLE_RATE}Hz, ${AUDIO_CHANNELS}ch"
echo "Output: ${OUT_BASE}"
echo "RUN_ID: ${RUN_ID} RUN_START_UTC: ${RUN_START_UTC}"
echo "UDP input: ${UDP_IN}"
echo "===================================================="

while true; do
  echo "[INFO] Starting ffmpeg (AAC-LC -> UDP/mpegts) in background..."
  ffmpeg -hide_banner -loglevel info -nostdin -y \
    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
    -i "${ICECAST_URL}" \
    -vn \
    -c:a aac -profile:a aac_low \
    -b:a "${AUDIO_BITRATE}" \
    -ar "${AUDIO_SAMPLE_RATE}" \
    -ac "${AUDIO_CHANNELS}" \
    -f mpegts \
    "udp://127.0.0.1:${UDP_PORT}?pkt_size=1316" \
    &
  FFMPEG_PID=$!

  # give ffmpeg time to start sending packets
  sleep 1.5

  echo "[INFO] Starting Shaka Packager (reading UDP TS)..."
  packager \
    "in=${UDP_IN},input_format=mp2t,stream=audio,init_segment=${OUT_BASE}/init_${RUN_ID}.mp4,segment_template=${OUT_BASE}/seg_${RUN_ID}_\$Number\$.m4s,playlist_name=audio.m3u8,hls_group_id=audio,hls_name=${STREAM_ID}" \
    --segment_duration "${SEGMENT_DURATION}" \
    --time_shift_buffer_depth "${TIME_SHIFT_BUFFER_DEPTH}" \
    --preserved_segments_outside_live_window "${PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW}" \
    --generate_static_live_mpd=false \
    --mpd_output "${OUT_BASE}/manifest.mpd" \
    --hls_master_playlist_output "${OUT_BASE}/playlist.m3u8" \
    --hls_playlist_type LIVE \
    || true

  echo "[WARN] packager stopped, killing ffmpeg..."
  kill "${FFMPEG_PID}" 2>/dev/null || true
  wait "${FFMPEG_PID}" 2>/dev/null || true

  echo "[WARN] Restarting pipeline in 3 seconds..."
  sleep 3

  new_run
  echo "[INFO] New RUN_ID: ${RUN_ID} RUN_START_UTC: ${RUN_START_UTC}"
done