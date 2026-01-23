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

if [[ -z "${ICECAST_URL}" ]]; then
  echo "ERROR: ICECAST_URL is empty"
  exit 1
fi

OUT_BASE="/output/${STREAM_ID}"
HLS_DIR="${OUT_BASE}"
DASH_DIR="${OUT_BASE}"
SEG_DIR="${OUT_BASE}"

mkdir -p "${HLS_DIR}" "${DASH_DIR}" "${SEG_DIR}"

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
  echo "[INFO] Starting Shaka Packager (background, reading UDP)..."
  packager \
    "in=${UDP_IN},stream=audio,init_segment=${SEG_DIR}/init.mp4,segment_template=${SEG_DIR}/seg_\$Number\$.m4s,playlist_name=audio.m3u8,hls_group_id=audio,hls_name=${STREAM_ID}" \
    --segment_duration "${SEGMENT_DURATION}" \
    --time_shift_buffer_depth "${TIME_SHIFT_BUFFER_DEPTH}" \
    --preserved_segments_outside_live_window "${PRESERVED_SEGMENTS_OUTSIDE_LIVE_WINDOW}" \
    --generate_static_live_mpd=false \
    --mpd_output "${DASH_DIR}/manifest.mpd" \
    --hls_master_playlist_output "${HLS_DIR}/playlist.m3u8" \
    --hls_playlist_type LIVE \
    --utc_timings "urn:mpeg:dash:utc:http-xsdate:2014=https://time.akamai.com/?iso" \
    &
  PACKAGER_PID=$!

  # give packager time to bind UDP socket
  sleep 0.5

  echo "[INFO] Starting ffmpeg (writing HE-AAC into UDP/mpegts)..."
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
    || true

  echo "[WARN] ffmpeg stopped, killing packager..."
  kill "${PACKAGER_PID}" 2>/dev/null || true
  wait "${PACKAGER_PID}" 2>/dev/null || true

  echo "[WARN] Pipeline stopped. Restarting in 3 seconds..."
  sleep 3
done