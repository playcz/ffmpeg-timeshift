const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const STREAM_ID = process.env.STREAM_ID;
const OUT_BASE = `/out/${STREAM_ID}`;
const OUT_HLS = path.join(OUT_BASE, "hls");
const OUT_DASH = path.join(OUT_BASE, "dash");

const AUDIO_SR = parseInt(process.env.AUDIO_SR || "48000", 10);
const AUDIO_CH = parseInt(process.env.AUDIO_CH || "2", 10);
const AAC_BITRATE = process.env.AAC_BITRATE || "128k";

const SEG_SECONDS = parseInt(process.env.SEG_SECONDS || "60", 10);
const HISTORY_HOURS = parseInt(process.env.HISTORY_HOURS || "12", 10);
const STITCH_INTERVAL_SEC = parseInt(
  process.env.STITCH_INTERVAL_SEC || "10",
  10
);

const WINDOW_MINUTES = HISTORY_HOURS * 60; // 720 for 12h
const SAFE_MARGIN_MINUTES = 1; // keep 1 minute margin for segment completion
const MIN_OK_SECONDS = SEG_SECONDS - 2; // accept "few seconds" loss, but ensure near-complete

function pad2(n) {
  return String(n).padStart(2, "0");
}

function utcMinuteKey(d) {
  return `${pad2(d.getUTCHours())}${pad2(d.getUTCMinutes())}`;
}

function keyToDateUTC(key) {
  // Key is now HHMM format, reconstruct date from current UTC date
  const now = new Date();
  const hh = parseInt(key.slice(0, 2), 10);
  const mm = parseInt(key.slice(2, 4), 10);
  return new Date(
    Date.UTC(
      now.getUTCFullYear(),
      now.getUTCMonth(),
      now.getUTCDate(),
      hh,
      mm,
      0
    )
  );
}

function run(cmd, args) {
  try {
    execFileSync(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
    return true;
  } catch (e) {
    // keep going, but log
    console.error(`[stitcher] command failed: ${cmd} ${args.join(" ")}`);
    if (e.stdout) console.error(String(e.stdout));
    if (e.stderr) console.error(String(e.stderr));
    return false;
  }
}

function ffprobeDurationSeconds(filePath) {
  try {
    const out = execFileSync(
      "ffprobe",
      [
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        filePath,
      ],
      { stdio: ["ignore", "pipe", "pipe"] }
    )
      .toString()
      .trim();
    const dur = parseFloat(out);
    return Number.isFinite(dur) ? dur : null;
  } catch {
    return null;
  }
}

function ensureSilenceTs(tsPath) {
  // Write a 60s silent TS segment (AAC in TS)
  fs.mkdirSync(path.dirname(tsPath), { recursive: true });
  run("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    `anullsrc=r=${AUDIO_SR}:cl=${AUDIO_CH === 2 ? "stereo" : "mono"}`,
    "-t",
    String(SEG_SECONDS),
    "-c:a",
    "aac",
    "-b:a",
    AAC_BITRATE,
    "-ar",
    String(AUDIO_SR),
    "-ac",
    String(AUDIO_CH),
    "-f",
    "mpegts",
    tsPath,
  ]);
}

function ensureSilenceMp4(mp4Path) {
  // Write a 60s silent MP4 (AAC in MP4)
  fs.mkdirSync(path.dirname(mp4Path), { recursive: true });
  run("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    `anullsrc=r=${AUDIO_SR}:cl=${AUDIO_CH === 2 ? "stereo" : "mono"}`,
    "-t",
    String(SEG_SECONDS),
    "-c:a",
    "aac",
    "-b:a",
    AAC_BITRATE,
    "-ar",
    String(AUDIO_SR),
    "-ac",
    String(AUDIO_CH),
    "-movflags",
    "+faststart",
    mp4Path,
  ]);
}

function ensureMinuteFiles(minuteKey) {
  const tsPath = path.join(OUT_HLS, `${minuteKey}.ts`);
  const mp4Path = path.join(OUT_DASH, `${minuteKey}.mp4`);

  let needTsRecreate = false;
  let needMp4Recreate = false;

  // If exists but zero bytes or too short, replace with silence
  if (fs.existsSync(tsPath)) {
    const stats = fs.statSync(tsPath);
    if (stats.size === 0) {
      console.warn(
        `[stitcher] TS is zero bytes, replacing with silence: ${minuteKey}`
      );
      try {
        fs.unlinkSync(tsPath);
        needTsRecreate = true;
      } catch (e) {
        console.error(`[stitcher] Failed to delete zero-byte TS: ${e.message}`);
      }
    } else {
      const dur = ffprobeDurationSeconds(tsPath);
      if (dur !== null && dur < MIN_OK_SECONDS) {
        console.warn(
          `[stitcher] TS too short (${dur}s), replacing with silence: ${minuteKey}`
        );
        try {
          fs.unlinkSync(tsPath);
          needTsRecreate = true;
        } catch {}
      }
    }
  }
  if (fs.existsSync(mp4Path)) {
    const stats = fs.statSync(mp4Path);
    if (stats.size === 0) {
      console.warn(
        `[stitcher] MP4 is zero bytes, replacing with silence: ${minuteKey}`
      );
      try {
        fs.unlinkSync(mp4Path);
        needMp4Recreate = true;
      } catch (e) {
        console.error(
          `[stitcher] Failed to delete zero-byte MP4: ${e.message}`
        );
      }
    } else {
      const dur = ffprobeDurationSeconds(mp4Path);
      if (dur !== null && dur < MIN_OK_SECONDS) {
        console.warn(
          `[stitcher] MP4 too short (${dur}s), replacing with silence: ${minuteKey}`
        );
        try {
          fs.unlinkSync(mp4Path);
          needMp4Recreate = true;
        } catch {}
      }
    }
  }

  if (!fs.existsSync(tsPath) || needTsRecreate) {
    console.warn(
      `[stitcher] ${
        needTsRecreate ? "Recreating" : "Missing"
      } TS, creating silence: ${minuteKey}`
    );
    ensureSilenceTs(tsPath);
  }
  if (!fs.existsSync(mp4Path) || needMp4Recreate) {
    console.warn(
      `[stitcher] ${
        needMp4Recreate ? "Recreating" : "Missing"
      } MP4, creating silence: ${minuteKey}`
    );
    ensureSilenceMp4(mp4Path);
  }
}

function deleteOldFiles(keepFromKey) {
  // delete files older than keepFromKey- a small buffer
  const keepFromDate = keyToDateUTC(keepFromKey);
  const cutoffMs = keepFromDate.getTime() - 5 * 60 * 1000; // extra 5-min buffer

  for (const dir of [OUT_HLS, OUT_DASH]) {
    if (!fs.existsSync(dir)) continue;
    for (const name of fs.readdirSync(dir)) {
      const m = name.match(/^(\d{12})\.(ts|mp4)$/);
      if (!m) continue;
      const key = m[1];
      const dt = keyToDateUTC(key).getTime();
      if (dt < cutoffMs) {
        try {
          fs.unlinkSync(path.join(dir, name));
        } catch {}
      }
    }
  }
}

function writeHlsPlaylists(minuteKeys) {
  // HLS audio playlist: last 12h (720 segments), each 60s
  const targetDuration = SEG_SECONDS;
  const mediaSeq = 0; // we use absolute filenames; sequence is less important

  const lines = [];
  lines.push("#EXTM3U");
  lines.push("#EXT-X-VERSION:3");
  lines.push(`#EXT-X-TARGETDURATION:${targetDuration}`);
  lines.push(`#EXT-X-MEDIA-SEQUENCE:${mediaSeq}`);

  for (const key of minuteKeys) {
    const dt = keyToDateUTC(key);
    // program date time improves seeking semantics for many clients
    lines.push(`#EXT-X-PROGRAM-DATE-TIME:${dt.toISOString()}`);
    lines.push(`#EXTINF:${SEG_SECONDS.toFixed(3)},`);
    lines.push(`${key}.ts`);
  }

  const audioPath = path.join(OUT_HLS, "playlist.m3u8");
  fs.writeFileSync(audioPath, lines.join("\n") + "\n");

  // Master playlist
  const master = [];
  master.push("#EXTM3U");
  master.push("#EXT-X-VERSION:3");
  master.push(`#EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2"`);
  master.push("playlist.m3u8");

  fs.writeFileSync(path.join(OUT_HLS, "master.m3u8"), master.join("\n") + "\n");
}

function writeDashMpd(minuteKeys) {
  // Minimal dynamic MPD listing MP4-per-minute segments.
  // NOTE: This uses SegmentList. It’s restart-proof and simple for gap-fill.
  const now = new Date();
  const publishTime = now.toISOString();
  const timeShiftBufferDepth = `PT${HISTORY_HOURS}H`;
  const minUpdate = "PT30S";

  // Availability: start at earliest minute
  const ast = keyToDateUTC(minuteKeys[0]).toISOString();

  // Build SegmentURL list (relative paths)
  const segmentUrls = minuteKeys
    .map((k) => `      <SegmentURL media="${k}.mp4" />`)
    .join("\n");

  // Approx bandwidth hint (not critical)
  const bandwidth = 160000;

  const mpd = `<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
     type="dynamic"
     availabilityStartTime="${ast}"
     publishTime="${publishTime}"
     minimumUpdatePeriod="${minUpdate}"
     timeShiftBufferDepth="${timeShiftBufferDepth}"
     profiles="urn:mpeg:dash:profile:isoff-live:2011">
  <Period id="p0" start="PT0S">
    <AdaptationSet id="a0" contentType="audio" mimeType="audio/mp4" segmentAlignment="true" lang="und">
      <Representation id="r0" bandwidth="${bandwidth}" codecs="mp4a.40.2" audioSamplingRate="${AUDIO_SR}">
        <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="${AUDIO_CH}"/>
        <SegmentList timescale="1" duration="${SEG_SECONDS}">
${segmentUrls}
        </SegmentList>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
`;

  fs.writeFileSync(path.join(OUT_DASH, "manifest.mpd"), mpd);
}

function buildMinuteWindowKeys() {
  // We only finalize up to (now - SAFE_MARGIN_MINUTES).
  const now = new Date();
  const end = new Date(now.getTime());
  end.setUTCSeconds(0, 0);
  end.setUTCMinutes(end.getUTCMinutes() - SAFE_MARGIN_MINUTES);

  const keys = [];
  for (let i = WINDOW_MINUTES - 1; i >= 0; i--) {
    const d = new Date(end.getTime() - i * 60 * 1000);
    keys.push(utcMinuteKey(d));
  }
  return keys;
}

function tick() {
  try {
    fs.mkdirSync(OUT_HLS, { recursive: true });
    fs.mkdirSync(OUT_DASH, { recursive: true });

    const minuteKeys = buildMinuteWindowKeys();
    const keepFromKey = minuteKeys[0];

    // Ensure all minutes exist (real or silence)
    for (const key of minuteKeys) {
      ensureMinuteFiles(key);
    }

    // Remove old files
    deleteOldFiles(keepFromKey);

    // Write manifests
    writeHlsPlaylists(minuteKeys);
    writeDashMpd(minuteKeys);

    // Touch a heartbeat file for healthchecks if you want
    fs.writeFileSync(
      path.join(OUT_BASE, "stitcher_heartbeat.txt"),
      new Date().toISOString() + "\n"
    );
  } catch (e) {
    console.error("[stitcher] tick error:", e);
  }
}

console.log(
  `[stitcher] starting for ${STREAM_ID}, window=${WINDOW_MINUTES} minutes, seg=${SEG_SECONDS}s, UTC`
);
tick();
setInterval(tick, STITCH_INTERVAL_SEC * 1000);
