import os, re, json, time
from datetime import datetime, timezone, timedelta

STREAM_ID = os.getenv("STREAM_ID", "stream1")
SEGMENT_DURATION = int(os.getenv("SEGMENT_DURATION", "60"))
TSBD = int(os.getenv("TIME_SHIFT_BUFFER_DEPTH", "43200"))
INTERVAL = int(os.getenv("STITCH_INTERVAL_SECONDS", "2"))

OUT_BASE = f"/output/{STREAM_ID}"

RUN_RE = re.compile(r"run_(\d+)\.json$")
SEG_RE = re.compile(r"seg_(\d+)_(\d+)\.m4s$")  # seg_<run>_<number>.m4s

def parse_utc(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)

def list_runs():
    runs = []
    if not os.path.isdir(OUT_BASE):
        return runs
    for fn in os.listdir(OUT_BASE):
        m = RUN_RE.match(fn)
        if not m:
            continue
        path = os.path.join(OUT_BASE, fn)
        try:
            meta = json.load(open(path, "r", encoding="utf-8"))
            run_id = str(meta["run_id"])
            start_utc = parse_utc(meta["start_utc"])
            start_segment_number = int(meta.get("start_segment_number", 1))
            runs.append((run_id, start_utc, start_segment_number))
        except Exception:
            pass
    runs.sort(key=lambda x: int(x[0]))
    return runs

def list_segments():
    segs = []
    if not os.path.isdir(OUT_BASE):
        return segs
    for fn in os.listdir(OUT_BASE):
        m = SEG_RE.match(fn)
        if not m:
            continue
        run_id, num = m.group(1), int(m.group(2))
        segs.append((run_id, num, fn))
    segs.sort(key=lambda x: (int(x[0]), x[1]))
    return segs

def write_master():
    # Simple master referencing one audio rendition
    path = os.path.join(OUT_BASE, "playlist.m3u8")
    tmp = path + ".tmp"
    content = "\n".join([
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        "#EXT-X-INDEPENDENT-SEGMENTS",
        f'#EXT-X-STREAM-INF:BANDWIDTH=96000,CODECS="mp4a.40.5"',
        "audio.m3u8",
        "",
    ])
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)

def write_hls_media(runs, segs):
    # Build a continuous media playlist with DISCONTINUITY across run boundaries
    # Keep only last TSBD seconds worth of segments (based on computed PDT)
    run_map = {rid: {"start": st, "start_num": sn} for rid, st, sn in runs}

    entries = []
    for run_id, num, fn in segs:
        if run_id not in run_map:
            continue
        start_time = run_map[run_id]["start"] + timedelta(seconds=(num - 1) * SEGMENT_DURATION)
        entries.append((start_time, run_id, num, fn))

    if not entries:
        return

    # retain last TSBD seconds (plus a small grace)
    newest_time = entries[-1][0]
    cutoff = newest_time - timedelta(seconds=TSBD)
    entries = [e for e in entries if e[0] >= cutoff]

    # HLS header
    targetduration = SEGMENT_DURATION
    media_seq = entries[0][2]  # not perfect across run ids, but ok for clients
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        f"#EXT-X-TARGETDURATION:{targetduration}",
        f"#EXT-X-MEDIA-SEQUENCE:{media_seq}",
        "#EXT-X-PLAYLIST-TYPE:EVENT",
    ]

    prev_run = None
    prev_time = None

    # For fMP4 playlist, EXT-X-MAP must be set for each discontinuity/run
    for (t, run_id, num, fn) in entries:
        # gap detection
        if prev_time is not None:
            expected = prev_time + timedelta(seconds=SEGMENT_DURATION)
            if t > expected + timedelta(seconds=1):  # downtime gap
                lines.append("#EXT-X-DISCONTINUITY")
                prev_run = None  # force new EXT-X-MAP

        # run boundary = discontinuity + new init
        if prev_run is None or run_id != prev_run:
            if prev_run is not None:
                lines.append("#EXT-X-DISCONTINUITY")
            lines.append(f'#EXT-X-MAP:URI="init_{run_id}.mp4"')

        # program date time per segment (this is what keeps DVR “continuous”)
        lines.append(f"#EXT-X-PROGRAM-DATE-TIME:{t.isoformat().replace('+00:00','Z')}")
        lines.append(f"#EXTINF:{SEGMENT_DURATION:.3f},")
        lines.append(fn)

        prev_run = run_id
        prev_time = t

    path = os.path.join(OUT_BASE, "audio.m3u8")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)

def write_mpd(runs, segs):
    # Multi-period dynamic MPD. Each packager run becomes a Period.
    # Period start is derived from run start time relative to availabilityStartTime.
    if not runs:
        return

    ast = runs[0][1]  # availabilityStartTime = first run start
    now = datetime.now(timezone.utc)

    # which runs have segments at all?
    segs_by_run = {}
    for run_id, num, fn in segs:
        segs_by_run.setdefault(run_id, []).append(num)

    periods = []
    for run_id, start_utc, start_num in runs:
        nums = segs_by_run.get(run_id, [])
        if not nums:
            continue
        # Period@start in seconds since AST
        pstart = int((start_utc - ast).total_seconds())
        # Choose a conservative startNumber: smallest seen
        min_num = min(nums)
        # media name template
        periods.append((run_id, pstart, min_num))

    if not periods:
        return

    # Build MPD
    # NOTE: minimal MPD, good enough for most players, with gaps as separate Periods.
    mpd = []
    mpd.append('<?xml version="1.0" encoding="UTF-8"?>')
    mpd.append(
        f'<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" '
        f'type="dynamic" '
        f'minimumUpdatePeriod="PT2S" '
        f'timeShiftBufferDepth="PT{TSBD}S" '
        f'availabilityStartTime="{ast.isoformat().replace("+00:00","Z")}">'
    )

    for run_id, pstart, start_number in periods:
        mpd.append(f'  <Period id="run_{run_id}" start="PT{pstart}S">')
        mpd.append('    <AdaptationSet id="1" contentType="audio" mimeType="audio/mp4" codecs="mp4a.40.5" lang="cs">')
        mpd.append('      <Representation id="audio" bandwidth="96000">')
        mpd.append(
            f'        <SegmentTemplate timescale="1" duration="{SEGMENT_DURATION}" '
            f'startNumber="{start_number}" '
            f'initialization="init_{run_id}.mp4" '
            f'media="seg_{run_id}_$Number$.m4s" />'
        )
        mpd.append('      </Representation>')
        mpd.append('    </AdaptationSet>')
        mpd.append('  </Period>')

    mpd.append('</MPD>')

    path = os.path.join(OUT_BASE, "manifest.mpd")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(mpd) + "\n")
    os.replace(tmp, path)

def main():
    os.makedirs(OUT_BASE, exist_ok=True)
    print(f"[STITCHER] OUT_BASE={OUT_BASE} SEGMENT_DURATION={SEGMENT_DURATION} TSBD={TSBD} INTERVAL={INTERVAL}")

    while True:
        runs = list_runs()
        segs = list_segments()

        if runs and segs:
            write_master()
            write_hls_media(runs, segs)
            write_mpd(runs, segs)

        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()