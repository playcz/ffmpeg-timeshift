#!/usr/bin/env bash
set -euo pipefail

: "${STREAM_ID:?Missing STREAM_ID}"
: "${ICECAST_URL:?Missing ICECAST_URL}"

AUDIO_SR="${AUDIO_SR:-48000}"
AUDIO_CH="${AUDIO_CH:-2}"
AAC_BITRATE="${AAC_BITRATE:-128k}"

SEG_SECONDS="${SEG_SECONDS:-60}"
HISTORY_HOURS="${HISTORY_HOURS:-12}"
STITCH_INTERVAL_SEC="${STITCH_INTERVAL_SEC:-10}"

export AUDIO_SR AUDIO_CH

OUT_BASE="/out/${STREAM_ID}"
OUT_HLS="${OUT_BASE}/hls"
OUT_DASH="${OUT_BASE}/dash"
TMP_HLS="${OUT_BASE}/.tmp_hls"
TMP_DASH="${OUT_BASE}/.tmp_dash"

mkdir -p "${OUT_HLS}" "${OUT_DASH}" "${TMP_HLS}" "${TMP_DASH}"

# FIFOs for liquidsoap WAV output - one for each ffmpeg instance
rm -f /tmp/hls.wav /tmp/dash.wav
mkfifo /tmp/hls.wav
mkfifo /tmp/dash.wav

echo "[timeshift] Starting liquidsoap..."
liquidsoap /app/liquidsoap.liq &
LS_PID=$!

# HLS segments: UTC minute key filenames, TS audio segments
# Write to temp directory, renamer will move when complete
run_ffmpeg_hls () {
  echo "[timeshift] Starting ffmpeg (HLS segment writer)..."
  ffmpeg -hide_banner -loglevel info \
    -fflags +genpts \
    -thread_queue_size 1024 \
    -i /tmp/hls.wav \
    -c:a aac -b:a "${AAC_BITRATE}" -ar "${AUDIO_SR}" -ac "${AUDIO_CH}" \
    -f segment \
    -segment_time "${SEG_SECONDS}" \
    -strftime 1 \
    -reset_timestamps 1 \
    "${TMP_HLS}/%H%M.ts"
}

# DASH segments: UTC minute key filenames, MP4 audio per minute
# (Restart-safe because filenames are time-based)
# Write to temp directory, renamer will move when complete
run_ffmpeg_dash () {
  echo "[timeshift] Starting ffmpeg (DASH segment writer - MP4 per minute)..."
  ffmpeg -hide_banner -loglevel info \
    -fflags +genpts \
    -thread_queue_size 1024 \
    -i /tmp/dash.wav \
    -c:a aac -b:a "${AAC_BITRATE}" -ar "${AUDIO_SR}" -ac "${AUDIO_CH}" \
    -f segment \
    -segment_time "${SEG_SECONDS}" \
    -strftime 1 \
    -reset_timestamps 1 \
    -segment_format mp4 \
    -movflags +faststart \
    "${TMP_DASH}/%H%M.mp4"
}

# Monitor for completed segments and atomically move them
rename_completed_segments () {
  echo "[timeshift] Starting segment renamer..."
  while true; do
    # Find files in temp dirs that haven't been modified in 3 seconds (complete)
    find "${TMP_HLS}" -name "*.ts" -type f -mmin +0.05 2>/dev/null | while read -r file; do
      target="${OUT_HLS}/$(basename "$file")"
      if [ -f "$file" ]; then
        mv "$file" "$target" 2>/dev/null && echo "[renamer] HLS: $(basename "$target")"
      fi
    done
    
    find "${TMP_DASH}" -name "*.mp4" -type f -mmin +0.05 2>/dev/null | while read -r file; do
      target="${OUT_DASH}/$(basename "$file")"
      if [ -f "$file" ]; then
        mv "$file" "$target" 2>/dev/null && echo "[renamer] DASH: $(basename "$target")"
      fi
    done
    
    sleep 2
  done
}

# keep both ffmpegs alive
(  while true; do
    run_ffmpeg_hls || echo "[timeshift] ffmpeg(HLS) exited, restarting in 1s..."
    sleep 1
  done
) &
FF_HLS_PID=$!

(
  while true; do
    run_ffmpeg_dash || echo "[timeshift] ffmpeg(DASH) exited, restarting in 1s..."
    sleep 1
  done
) &
FF_DASH_PID=$!

# Start segment renamer
(
  while true; do
    rename_completed_segments || echo "[timeshift] renamer exited, restarting in 1s..."
    sleep 1
  done
) &
RENAMER_PID=$!

echo "[timeshift] Starting stitcher..."
node /app/stitcher.js &
ST_PID=$!

cleanup () {
  echo "[timeshift] Shutting down..."
  kill "${ST_PID}" 2>/dev/null || true
  kill "${RENAMER_PID}" 2>/dev/null || true
  kill "${FF_HLS_PID}" 2>/dev/null || true
  kill "${FF_DASH_PID}" 2>/dev/null || true
  kill "${LS_PID}" 2>/dev/null || true
  exit 0
}
trap cleanup SIGINT SIGTERM

wait