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

UDP_PORT="${UDP_PORT:-40000}"
UDP_IN="udp://127.0.0.1:${UDP_PORT}"

STITCHER_POLL_INTERVAL="${STITCHER_POLL_INTERVAL:-5}"
CLEANER_INTERVAL="${CLEANER_INTERVAL:-60}"

export STREAM_ID ICECAST_URL SEGMENT_DURATION TIME_SHIFT_BUFFER_DEPTH \
  PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW AUDIO_BITRATE AUDIO_SAMPLE_RATE \
  AUDIO_CHANNELS UDP_PORT STITCHER_POLL_INTERVAL CLEANER_INTERVAL

if [[ -z "${ICECAST_URL}" ]]; then
  echo "ERROR: ICECAST_URL is empty"
  exit 1
fi

OUT_BASE="/output/${STREAM_ID}"
TIMELINE_DIR="${OUT_BASE}/timelines"
STATE_DIR="${OUT_BASE}/.state"
mkdir -p "${TIMELINE_DIR}" "${STATE_DIR}" "${OUT_BASE}"

cleanup_children() {
  if [[ -n "${PACKAGER_PID:-}" ]]; then
    kill "${PACKAGER_PID}" 2>/dev/null || true
    wait "${PACKAGER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${FFMPEG_PID:-}" ]]; then
    kill "${FFMPEG_PID}" 2>/dev/null || true
    wait "${FFMPEG_PID}" 2>/dev/null || true
  fi
  if [[ -n "${STITCHER_PID:-}" ]]; then
    kill "${STITCHER_PID}" 2>/dev/null || true
    wait "${STITCHER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${CLEANER_PID:-}" ]]; then
    kill "${CLEANER_PID}" 2>/dev/null || true
    wait "${CLEANER_PID}" 2>/dev/null || true
  fi
}

trap 'cleanup_children; exit 0' INT TERM

echo "[INFO] Starting stitcher worker..."
python3 /app/stitcher.py &
STITCHER_PID=$!

echo "[INFO] Starting cleaner worker..."
python3 /app/cleaner.py &
CLEANER_PID=$!

echo "===================================================="
echo "STREAM_ID: ${STREAM_ID}"
echo "ICECAST_URL: ${ICECAST_URL}"
echo "Segment duration: ${SEGMENT_DURATION}s"
echo "Time-shift buffer depth: ${TIME_SHIFT_BUFFER_DEPTH}s (12h)"
echo "Preserved outside live window: ${PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW} segments"
echo "Audio: ${AUDIO_BITRATE}, ${AUDIO_SAMPLE_RATE}Hz, ${AUDIO_CHANNELS}ch"
echo "Output: ${OUT_BASE}"
echo "UDP input: ${UDP_IN}"
echo "===================================================="

while true; do
  TIMELINE_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
  CURRENT_TIMELINE_DIR="${TIMELINE_DIR}/${TIMELINE_ID}"
  mkdir -p "${CURRENT_TIMELINE_DIR}"

  cat >"${CURRENT_TIMELINE_DIR}/meta.json" <<META
{
  "timeline_id": "${TIMELINE_ID}",
  "started_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "stream_id": "${STREAM_ID}",
  "segment_duration": ${SEGMENT_DURATION},
  "time_shift_buffer_depth": ${TIME_SHIFT_BUFFER_DEPTH},
  "audio_bitrate": "${AUDIO_BITRATE}",
  "audio_sample_rate": ${AUDIO_SAMPLE_RATE},
  "audio_channels": ${AUDIO_CHANNELS}
}
META

  echo "[INFO] Timeline ${TIMELINE_ID}: starting Shaka Packager..."
  packager \
    "in=${UDP_IN},stream=audio,init_segment=${CURRENT_TIMELINE_DIR}/init.mp4,segment_template=${CURRENT_TIMELINE_DIR}/seg_\$Number\$.m4s,playlist_name=audio.m3u8,hls_group_id=audio,hls_name=${STREAM_ID}" \
    --segment_duration "${SEGMENT_DURATION}" \
    --time_shift_buffer_depth "${TIME_SHIFT_BUFFER_DEPTH}" \
    --preserved_segments_outside_live_window "${PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW}" \
    --generate_static_live_mpd=false \
    --mpd_output "${CURRENT_TIMELINE_DIR}/manifest.mpd" \
    --hls_master_playlist_output "${CURRENT_TIMELINE_DIR}/master.m3u8" \
    --hls_playlist_type LIVE \
    --utc_timings "urn:mpeg:dash:utc:http-xsdate:2014=https://time.akamai.com/?iso" \
    &
  PACKAGER_PID=$!

  # give packager time to bind UDP socket
  sleep 0.5

  echo "[INFO] Timeline ${TIMELINE_ID}: starting ffmpeg..."
  ffmpeg \
    -hide_banner -loglevel warning \
    -nostdin -y \
    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
    -i "${ICECAST_URL}" \
    -vn \
    -c:a aac \
    -b:a "${AUDIO_BITRATE}" \
    -ar "${AUDIO_SAMPLE_RATE}" \
    -ac "${AUDIO_CHANNELS}" \
    -f mpegts \
    "udp://127.0.0.1:${UDP_PORT}?pkt_size=1316" \
    &
  FFMPEG_PID=$!

  wait "${FFMPEG_PID}" 2>/dev/null || true

  echo "[WARN] Timeline ${TIMELINE_ID}: ffmpeg stopped, stopping packager..."
  kill "${PACKAGER_PID}" 2>/dev/null || true
  wait "${PACKAGER_PID}" 2>/dev/null || true

  unset FFMPEG_PID
  unset PACKAGER_PID

  echo "[WARN] Pipeline stopped. Restarting in 3 seconds..."
  sleep 3
done