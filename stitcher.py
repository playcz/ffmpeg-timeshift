#!/usr/bin/env python3
import json
import math
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional

STREAM_ID = os.environ.get("STREAM_ID", "stream1")
BASE_DIR = Path("/output") / STREAM_ID
TIMELINE_DIR = BASE_DIR / "timelines"
STATE_DIR = BASE_DIR / ".state"
OUTPUT_DIR = BASE_DIR
STATE_FILE = STATE_DIR / "stitcher_state.json"
BUFFER_DEPTH = int(os.environ.get("TIME_SHIFT_BUFFER_DEPTH", "43200"))
POLL_INTERVAL = int(os.environ.get("STITCHER_POLL_INTERVAL", "5"))
SEGMENT_DURATION = float(os.environ.get("SEGMENT_DURATION", "60"))
AUDIO_BITRATE = os.environ.get("AUDIO_BITRATE", "64000")
AUDIO_SAMPLE_RATE = os.environ.get("AUDIO_SAMPLE_RATE", "48000")
AUDIO_CHANNELS = os.environ.get("AUDIO_CHANNELS", "2")

TIMELINE_PLAYLIST = "audio.m3u8"
TIMELINE_META = "meta.json"

for directory in (TIMELINE_DIR, STATE_DIR, OUTPUT_DIR):
    directory.mkdir(parents=True, exist_ok=True)


def log(message: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    print(f"[stitcher] {now} {message}", flush=True)


def parse_bitrate(value: str) -> int:
    lowered = value.strip().lower()
    if lowered.endswith("k"):
        try:
            return int(float(lowered[:-1]) * 1000)
        except ValueError:
            return 0
    try:
        return int(lowered)
    except ValueError:
        return 0


def load_state() -> Dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            log("state file corrupted, recreating")
    return {
        "next_media_sequence": 0,
        "segment_sequences": {},
        "segments": [],
    }


def save_state(state: Dict) -> None:
    tmp_file = STATE_FILE.with_suffix(".tmp")
    tmp_file.write_text(json.dumps(state, indent=2))
    tmp_file.replace(STATE_FILE)


def read_meta(timeline_path: Path) -> Optional[Dict]:
    meta_path = timeline_path / TIMELINE_META
    if not meta_path.exists():
        return None
    try:
        return json.loads(meta_path.read_text())
    except json.JSONDecodeError:
        return None


def parse_program_datetime(value: Optional[str], fallback: datetime) -> datetime:
    if value:
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            pass
    return fallback


def parse_playlist(timeline_path: Path) -> List[Dict]:
    playlist_path = timeline_path / TIMELINE_PLAYLIST
    if not playlist_path.exists():
        return []
    segments: List[Dict] = []
    current_duration: Optional[float] = None
    current_pdt: Optional[str] = None
    active_map: Optional[str] = None
    discontinuity = False

    for raw_line in playlist_path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#EXTINF:"):
            try:
                current_duration = float(line.split(":", 1)[1].split(",", 1)[0])
            except ValueError:
                current_duration = SEGMENT_DURATION
        elif line.startswith("#EXT-X-PROGRAM-DATE-TIME:"):
            current_pdt = line.split(":", 1)[1].strip()
        elif line.startswith("#EXT-X-MAP:"):
            marker = "URI="
            if marker in line:
                fragment = line.split(marker, 1)[1]
                if fragment.startswith('"'):
                    active_map = fragment.split('"', 2)[1]
                else:
                    active_map = fragment.split(',', 1)[0]
        elif line == "#EXT-X-DISCONTINUITY":
            discontinuity = True
        elif line.startswith("#"):
            continue
        else:
            if current_duration is None:
                current_duration = SEGMENT_DURATION
            segments.append(
                {
                    "uri": line,
                    "duration": current_duration,
                    "program_date_time": current_pdt,
                    "map_uri": active_map,
                    "discontinuity": discontinuity,
                }
            )
            current_duration = None
            current_pdt = None
            discontinuity = False
    return segments


def build_segments() -> List[Dict]:
    all_segments: List[Dict] = []
    if not TIMELINE_DIR.exists():
        return all_segments
    timeline_dirs = sorted(
        [path for path in TIMELINE_DIR.iterdir() if path.is_dir()],
        key=lambda path: path.name,
    )
    for timeline_path in timeline_dirs:
        timeline_id = timeline_path.name
        meta = read_meta(timeline_path)
        if not meta:
            continue
        try:
            timeline_start = datetime.fromisoformat(meta.get("started_at", "").replace("Z", "+00:00"))
        except ValueError:
            continue
        playlist_entries = parse_playlist(timeline_path)
        if not playlist_entries:
            continue
        elapsed = 0.0
        for entry in playlist_entries:
            start_guess = timeline_start + timedelta(seconds=elapsed)
            pdt = parse_program_datetime(entry.get("program_date_time"), start_guess)
            source_uri = entry["uri"]
            media_path = timeline_path / source_uri
            if not media_path.exists():
                elapsed += entry["duration"]
                continue
            all_segments.append(
                {
                    "timeline_id": timeline_id,
                    "source_uri": source_uri,
                    "duration": entry["duration"],
                    "start_time": pdt,
                    "program_date_time": pdt,
                    "map_uri": entry.get("map_uri"),
                    "discontinuity": entry.get("discontinuity", False),
                }
            )
            elapsed += entry["duration"]
    all_segments.sort(key=lambda item: item["start_time"])
    return all_segments


def filter_by_depth(segments: List[Dict]) -> List[Dict]:
    if not segments:
        return segments
    threshold = datetime.now(timezone.utc) - timedelta(seconds=BUFFER_DEPTH)
    return [segment for segment in segments if segment["start_time"] >= threshold]


def assign_sequences(state: Dict, segments: List[Dict]) -> None:
    seq_map = state.setdefault("segment_sequences", {})
    next_seq = state.setdefault("next_media_sequence", 0)
    for segment in segments:
        key = f"{segment['timeline_id']}|{segment['source_uri']}"
        if key not in seq_map:
            seq_map[key] = next_seq
            next_seq += 1
        segment["media_sequence"] = seq_map[key]
    valid_keys = {f"{segment['timeline_id']}|{segment['source_uri']}" for segment in segments}
    stale_keys = set(seq_map.keys()) - valid_keys
    for stale in stale_keys:
        seq_map.pop(stale, None)
    state["next_media_sequence"] = next_seq


def compute_target_duration(segments: List[Dict]) -> int:
    if not segments:
        return max(1, int(math.ceil(SEGMENT_DURATION)))
    maximum = max(segment["duration"] for segment in segments)
    return max(1, int(math.ceil(maximum)))


def format_datetime(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def write_playlist(state: Dict, segments: List[Dict]) -> None:
    playlist_path = OUTPUT_DIR / "playlist.m3u8"
    if not segments:
        skeleton = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:1",
            "#EXT-X-MEDIA-SEQUENCE:0",
        ]
        playlist_path.write_text("\n".join(skeleton) + "\n")
        state["segments"] = []
        save_state(state)
        return

    segments.sort(key=lambda item: item["media_sequence"])
    target_duration = compute_target_duration(segments)
    media_sequence = segments[0]["media_sequence"]

    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        f"#EXT-X-TARGETDURATION:{target_duration}",
        f"#EXT-X-MEDIA-SEQUENCE:{media_sequence}",
    ]

    previous_timeline: Optional[str] = None
    previous_map: Optional[str] = None

    for segment in segments:
        timeline_id = segment["timeline_id"]
        map_uri = segment.get("map_uri") or "init.mp4"
        discontinuity_flag = segment.get("discontinuity", False)

        if previous_timeline is None:
            lines.append(f"#EXT-X-MAP:URI=\"timelines/{timeline_id}/{map_uri}\"")
        elif timeline_id != previous_timeline or discontinuity_flag:
            lines.append("#EXT-X-DISCONTINUITY")
            lines.append(f"#EXT-X-MAP:URI=\"timelines/{timeline_id}/{map_uri}\"")
        elif map_uri != previous_map:
            lines.append(f"#EXT-X-MAP:URI=\"timelines/{timeline_id}/{map_uri}\"")

        lines.append(f"#EXT-X-PROGRAM-DATE-TIME:{format_datetime(segment['program_date_time'])}")
        lines.append(f"#EXTINF:{segment['duration']:.3f},")
        lines.append(f"timelines/{timeline_id}/{segment['source_uri']}")

        previous_timeline = timeline_id
        previous_map = map_uri

    playlist_path.write_text("\n".join(lines) + "\n")
    state["segments"] = [
        {
            "timeline_id": segment["timeline_id"],
            "source_uri": segment["source_uri"],
            "media_sequence": segment["media_sequence"],
            "start_time": format_datetime(segment["start_time"]),
            "duration": segment["duration"],
        }
        for segment in segments
    ]
    save_state(state)


def build_mpd(segments: List[Dict]) -> None:
    from xml.etree import ElementTree as ET

    mpd_path = OUTPUT_DIR / "manifest.mpd"
    if not segments:
        empty = (
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\" minBufferTime=\"PT1S\" mediaPresentationDuration=\"PT0S\"/>\n"
        )
        mpd_path.write_text(empty)
        return

    segments.sort(key=lambda item: item["start_time"])
    first_start = segments[0]["start_time"]
    last_segment = segments[-1]
    total_duration = (last_segment["start_time"] - first_start).total_seconds() + last_segment["duration"]

    timescale = 1000
    mpd = ET.Element(
        "{urn:mpeg:dash:schema:mpd:2011}MPD",
        attrib={
            "type": "static",
            "profiles": "urn:mpeg:dash:profile:isoff-live:2011",
            "minBufferTime": "PT6S",
            "mediaPresentationDuration": f"PT{total_duration:.3f}S",
            "maxSegmentDuration": f"PT{compute_target_duration(segments)}S",
            "availabilityStartTime": format_datetime(first_start),
        },
    )

    grouped: Dict[str, List[Dict]] = {}
    for segment in segments:
        grouped.setdefault(segment["timeline_id"], []).append(segment)

    adaptation_attrib = {
        "mimeType": "audio/mp4",
        "codecs": "mp4a.40.2",
        "startWithSAP": "1",
    }
    bandwidth = parse_bitrate(AUDIO_BITRATE)
    bandwidth_value = str(bandwidth) if bandwidth else "64000"
    representation_attrib = {
        "id": f"{STREAM_ID}-audio",
        "bandwidth": bandwidth_value,
        "audioSamplingRate": AUDIO_SAMPLE_RATE,
    }
    if AUDIO_CHANNELS:
        representation_attrib["numChannels"] = AUDIO_CHANNELS

    global_origin = segments[0]["start_time"]

    for timeline_id, timeline_segments in grouped.items():
        period_offset = (timeline_segments[0]["start_time"] - global_origin).total_seconds()
        period = ET.SubElement(
            mpd,
            "{urn:mpeg:dash:schema:mpd:2011}Period",
            attrib={
                "id": timeline_id,
                "start": f"PT{max(0.0, period_offset):.3f}S",
            },
        )
        adaptation = ET.SubElement(
            period,
            "{urn:mpeg:dash:schema:mpd:2011}AdaptationSet",
            attrib=adaptation_attrib,
        )
        representation = ET.SubElement(
            adaptation,
            "{urn:mpeg:dash:schema:mpd:2011}Representation",
            attrib=representation_attrib,
        )
        segment_list = ET.SubElement(
            representation,
            "{urn:mpeg:dash:schema:mpd:2011}SegmentList",
            attrib={"timescale": str(timescale)},
        )
        ET.SubElement(
            segment_list,
            "{urn:mpeg:dash:schema:mpd:2011}Initialization",
            attrib={"sourceURL": f"timelines/{timeline_id}/init.mp4"},
        )
        segment_timeline = ET.SubElement(
            segment_list,
            "{urn:mpeg:dash:schema:mpd:2011}SegmentTimeline",
        )
        timeline_origin = timeline_segments[0]["start_time"]
        for index, segment in enumerate(timeline_segments):
            offset_ms = int(round((segment["start_time"] - timeline_origin).total_seconds() * timescale))
            duration_ms = int(round(segment["duration"] * timescale))
            attrib = {"d": str(max(duration_ms, 1))}
            if index == 0:
                attrib["t"] = str(max(0, offset_ms))
            ET.SubElement(
                segment_timeline,
                "{urn:mpeg:dash:schema:mpd:2011}S",
                attrib=attrib,
            )
            ET.SubElement(
                segment_list,
                "{urn:mpeg:dash:schema:mpd:2011}SegmentURL",
                attrib={"media": f"timelines/{timeline_id}/{segment['source_uri']}"},
            )

    xml_bytes = ET.tostring(mpd, encoding="utf-8")
    header = b"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
    mpd_path.write_bytes(header + xml_bytes)


def main() -> None:
    if not BASE_DIR.exists():
        log("output base missing, waiting")
    state = load_state()
    while True:
        try:
            segments = build_segments()
            segments = filter_by_depth(segments)
            assign_sequences(state, segments)
            write_playlist(state, segments)
            build_mpd(segments)
            log(f"stitched {len(segments)} segments")
        except Exception as exc:  # noqa: BLE001
            log(f"error: {exc}")
        time.sleep(max(1, POLL_INTERVAL))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
