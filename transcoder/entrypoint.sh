#!/usr/bin/env bash
set -euo pipefail

STREAM_ID="${STREAM_ID:-stream1}"
ICECAST_URL="${ICECAST_URL:-}"

SEGMENT_DURATION="${SEGMENT_DURATION:-60}"
TIME_SHIFT_BUFFER_DEPTH="${TIME_SHIFT_BUFFER_DEPTH:-43200}"
PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW="${PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW:-10}"

AUDIO_BITRATE="${AUDIO_BITRATE:-64k}"
AUDIO_SAMPLE_RATE="${AUDIO_SAMPLE_RATE:-48000}"
AUDIO_CHANNELS="${AUDIO_CHANNELS:-2}"

if [[ -z "${ICECAST_URL}" ]]; then
  echo "ERROR: ICECAST_URL is empty"
  exit 1
fi

OUT_BASE="/output/${STREAM_ID}"
mkdir -p "${OUT_BASE}"

HTTP_PORT="${HTTP_PORT:-18080}"
HTTP_PATH="/${STREAM_ID}.mp4"
HTTP_IN="http://127.0.0.1:${HTTP_PORT}${HTTP_PATH}"
HTTP_LISTEN_URL="http://0.0.0.0:${HTTP_PORT}${HTTP_PATH}"

new_run() {
  RUN_ID="$(date -u +%s)"
  RUN_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  RUN_META="${OUT_BASE}/run_${RUN_ID}.json"
  cat > "${RUN_META}" <<EOF
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
echo "Time-shift buffer depth: ${TIME_SHIFT_BUFFER_DEPTH}s (12h)"
echo "Audio: HE-AAC ${AUDIO_BITRATE}, ${AUDIO_SAMPLE_RATE}Hz, ${AUDIO_CHANNELS}ch"
echo "Output: ${OUT_BASE}"
echo "RUN_ID: ${RUN_ID} RUN_START_UTC: ${RUN_START_UTC}"
echo "HTTP input: ${HTTP_IN}"
echo "===================================================="

while true; do
  echo "[INFO] Starting ffmpeg HTTP fMP4 server..."
  ffmpeg -hide_banner -loglevel warning -nostdin -y \
    -fflags +discardcorrupt \
    -err_detect ignore_err \
    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
    -i "${ICECAST_URL}" \
    -vn \
    -c:a libfdk_aac \
    -profile:a aac_he \
    -afterburner 1 \
    -b:a "${AUDIO_BITRATE}" \
    -ar 24000 \
    -ac "${AUDIO_CHANNELS}" \
    -f mp4 \
    -movflags frag_keyframe+empty_moov+default_base_moof \
    -listen 1 \
    "${HTTP_LISTEN_URL}" \
    &
  FFMPEG_PID=$!

  # Give ffmpeg time to start listening
  sleep 1

  echo "[INFO] Starting Shaka Packager (reading fMP4 over HTTP)..."
  packager \
    "in=${HTTP_IN},stream=audio,init_segment=${OUT_BASE}/init_${RUN_ID}.mp4,segment_template=${OUT_BASE}/seg_${RUN_ID}_\$Number\$.m4s" \
    --segment_duration "${SEGMENT_DURATION}" \
    --time_shift_buffer_depth "${TIME_SHIFT_BUFFER_DEPTH}" \
    --preserved_segments_outside_live_window "${PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW}" \
    --start_segment_number 1 \
    --generate_static_live_mpd=false \
    --mpd_output "${OUT_BASE}/packager_${RUN_ID}.mpd" \
    --hls_master_playlist_output "${OUT_BASE}/packager_${RUN_ID}.m3u8" \
    || true

  echo "[WARN] packager stopped, killing ffmpeg..."
  kill "${FFMPEG_PID}" 2>/dev/null || true
  wait "${FFMPEG_PID}" 2>/dev/null || true

  echo "[WARN] Restarting pipeline in 3 seconds..."
  sleep 3

  new_run
  echo "[INFO] New RUN_ID: ${RUN_ID} RUN_START_UTC: ${RUN_START_UTC}"
done