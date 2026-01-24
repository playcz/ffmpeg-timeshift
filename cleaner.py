#!/usr/bin/env python3
import json
import os
import shutil
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, Set

STREAM_ID = os.environ.get("STREAM_ID", "stream1")
BASE_DIR = Path("/output") / STREAM_ID
TIMELINE_DIR = BASE_DIR / "timelines"
STATE_FILE = (BASE_DIR / ".state") / "stitcher_state.json"
BUFFER_DEPTH = int(os.environ.get("TIME_SHIFT_BUFFER_DEPTH", "43200"))
POLL_INTERVAL = int(os.environ.get("CLEANER_INTERVAL", "60"))


def log(message: str) -> None:
    now = datetime.now(timezone.utc).isoformat()
    print(f"[cleaner] {now} {message}", flush=True)


def load_active_timelines() -> Set[str]:
    if not STATE_FILE.exists():
        return set()
    try:
        state = json.loads(STATE_FILE.read_text())
    except json.JSONDecodeError:
        return set()
    return {item["timeline_id"] for item in state.get("segments", [])}


def timeline_started_before(timeline_path: Path, cutoff: datetime) -> bool:
    meta_path = timeline_path / "meta.json"
    if meta_path.exists():
        try:
            meta = json.loads(meta_path.read_text())
            started = meta.get("started_at")
            if started:
                started_at = datetime.fromisoformat(started.replace("Z", "+00:00"))
                return started_at < cutoff
        except json.JSONDecodeError:
            pass
        except ValueError:
            pass
    mtime = datetime.fromtimestamp(timeline_path.stat().st_mtime, tz=timezone.utc)
    return mtime < cutoff


def remove_timeline(timeline_path: Path) -> None:
    try:
        shutil.rmtree(timeline_path)
        log(f"removed timeline {timeline_path.name}")
    except Exception as exc:  # noqa: BLE001
        log(f"failed removing {timeline_path.name}: {exc}")


def main() -> None:
    while True:
        try:
            active_timelines = load_active_timelines()
            cutoff = datetime.now(timezone.utc) - timedelta(seconds=BUFFER_DEPTH)
            if TIMELINE_DIR.exists():
                for timeline_path in TIMELINE_DIR.iterdir():
                    if not timeline_path.is_dir():
                        continue
                    if timeline_path.name in active_timelines:
                        continue
                    if timeline_started_before(timeline_path, cutoff):
                        remove_timeline(timeline_path)
        except Exception as exc:  # noqa: BLE001
            log(f"error: {exc}")
        time.sleep(max(10, POLL_INTERVAL))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
