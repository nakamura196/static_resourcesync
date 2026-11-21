#!/usr/bin/env python3
"""Minimal ResourceSync 1.1 harvester (Python standard library only).

Usage:
  First sync (downloads all resources, or first N with --limit):
    python3 resourcesync_harvest.py https://example.org/site/ ./mirror --limit 10

  Incremental sync (reads Change List; downloads created/updated, removes deleted):
    python3 resourcesync_harvest.py https://example.org/site/ ./mirror
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {
    "sm": "http://www.sitemaps.org/schemas/sitemap/0.9",
    "rs": "http://www.openarchives.org/rs/terms/",
}
STATE_FILE = ".resourcesync_state.json"
USER_AGENT = "static-resourcesync-harvester/0.1"


def fetch_bytes(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def discover_capability_list(target: str) -> str:
    """Resolve a site URL or capabilitylist.xml URL to the Capability List URL."""
    if target.endswith(".xml"):
        return target

    # Try HTML <link rel="resourcesync" href="..."> discovery first
    try:
        html = fetch_bytes(target, timeout=15).decode("utf-8", errors="replace")
        m = re.search(
            r'<link[^>]+rel=["\']resourcesync["\'][^>]+href=["\']([^"\']+)["\']',
            html,
            re.IGNORECASE,
        )
        if not m:
            m = re.search(
                r'<link[^>]+href=["\']([^"\']+)["\'][^>]+rel=["\']resourcesync["\']',
                html,
                re.IGNORECASE,
            )
        if m:
            return urllib.parse.urljoin(target, m.group(1))
    except urllib.error.URLError:
        pass

    return urllib.parse.urljoin(target.rstrip("/") + "/", "resourcesync/capabilitylist.xml")


def parse_capability_list(xml_bytes: bytes) -> dict[str, str]:
    root = ET.fromstring(xml_bytes)
    caps: dict[str, str] = {}
    for url_el in root.findall("sm:url", NS):
        loc = url_el.findtext("sm:loc", default="", namespaces=NS).strip()
        md = url_el.find("rs:md", NS)
        cap = md.attrib.get("capability") if md is not None else None
        if loc and cap:
            caps[cap] = loc
    return caps


def parse_resource_list(xml_bytes: bytes) -> tuple[str | None, list[dict]]:
    root = ET.fromstring(xml_bytes)
    root_md = root.find("rs:md", NS)
    at = root_md.attrib.get("at") if root_md is not None else None
    items = []
    for url_el in root.findall("sm:url", NS):
        loc = url_el.findtext("sm:loc", default="", namespaces=NS).strip()
        lastmod = url_el.findtext("sm:lastmod", default="", namespaces=NS).strip()
        md = url_el.find("rs:md", NS)
        hash_attr = md.attrib.get("hash", "") if md is not None else ""
        md5 = hash_attr.removeprefix("md5:") if hash_attr.startswith("md5:") else None
        length_s = md.attrib.get("length") if md is not None else None
        length = int(length_s) if length_s and length_s.isdigit() else None
        if loc:
            items.append({"loc": loc, "lastmod": lastmod, "md5": md5, "length": length})
    return at, items


def parse_change_list(xml_bytes: bytes) -> tuple[str | None, str | None, list[dict]]:
    root = ET.fromstring(xml_bytes)
    root_md = root.find("rs:md", NS)
    from_ts = root_md.attrib.get("from") if root_md is not None else None
    until_ts = root_md.attrib.get("until") if root_md is not None else None
    events = []
    for url_el in root.findall("sm:url", NS):
        loc = url_el.findtext("sm:loc", default="", namespaces=NS).strip()
        md = url_el.find("rs:md", NS)
        change = md.attrib.get("change") if md is not None else None
        dt = md.attrib.get("datetime") if md is not None else None
        if loc and change and dt:
            events.append({"loc": loc, "change": change, "datetime": dt})
    return from_ts, until_ts, events


def local_path_for(out_dir: Path, url: str) -> Path:
    parsed = urllib.parse.urlparse(url)
    rel = urllib.parse.unquote(parsed.path.lstrip("/"))
    dest = (out_dir / rel).resolve()
    out_root = out_dir.resolve()
    if out_root != dest and out_root not in dest.parents:
        raise ValueError(f"refusing to write outside output dir: {url}")
    return dest


def download_and_verify(
    url: str,
    dest: Path,
    expected_md5: str | None = None,
    expected_length: int | None = None,
) -> tuple[str, int]:
    data = fetch_bytes(url)
    actual_len = len(data)
    actual_md5 = hashlib.md5(data).hexdigest()

    if expected_length is not None and actual_len != expected_length:
        raise RuntimeError(
            f"length mismatch for {url}: expected {expected_length}, got {actual_len}"
        )
    if expected_md5 is not None and actual_md5 != expected_md5:
        raise RuntimeError(
            f"md5 mismatch for {url}: expected {expected_md5}, got {actual_md5}"
        )

    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    return actual_md5, actual_len


def load_state(out_dir: Path) -> dict | None:
    p = out_dir / STATE_FILE
    if not p.is_file():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def save_state(out_dir: Path, state: dict) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / STATE_FILE).write_text(
        json.dumps(state, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def first_sync(caps: dict[str, str], out_dir: Path, limit: int | None) -> int:
    rl_url = caps.get("resourcelist")
    if not rl_url:
        print("Error: capability list has no resourcelist", file=sys.stderr)
        return 1

    print(f"Fetching Resource List: {rl_url}")
    at, items = parse_resource_list(fetch_bytes(rl_url))
    total = len(items)
    target_items = items[:limit] if limit is not None else items
    print(f"Found {total} resources (downloading {len(target_items)})")

    downloaded: dict[str, dict] = {}
    for idx, item in enumerate(target_items, 1):
        loc = item["loc"]
        dest = local_path_for(out_dir, loc)
        md5, length = download_and_verify(
            loc, dest, expected_md5=item["md5"], expected_length=item["length"]
        )
        downloaded[loc] = {"md5": md5, "length": length, "lastmod": item["lastmod"]}
        print(f"  [{idx}/{len(target_items)}] OK {loc} ({length} bytes, md5 verified)")

    # Record current changelist events as already reflected in this baseline
    seen_events: list[str] = []
    cl_url = caps.get("changelist")
    if cl_url:
        try:
            _, _, events = parse_change_list(fetch_bytes(cl_url))
            seen_events = [f"{e['datetime']}|{e['change']}|{e['loc']}" for e in events]
        except urllib.error.URLError:
            pass

    save_state(
        out_dir,
        {
            "last_sync": at,
            "limit": limit,
            "files": downloaded,
            "seen_events": seen_events,
        },
    )
    print(f"Initial sync complete: {len(downloaded)} files verified and saved to {out_dir}")
    return 0


def incremental_sync(caps: dict[str, str], out_dir: Path, state: dict) -> int:
    cl_url = caps.get("changelist")
    if not cl_url:
        print("Error: capability list has no changelist", file=sys.stderr)
        return 1

    print(f"Fetching Change List: {cl_url}")
    _, until_ts, events = parse_change_list(fetch_bytes(cl_url))
    seen = set(state.get("seen_events", []))
    new_events = [
        e for e in events if f"{e['datetime']}|{e['change']}|{e['loc']}" not in seen
    ]

    if not new_events:
        print(f"No new changes since last sync ({state.get('last_sync')}). Already up to date.")
        return 0

    # Fetch Resource List metadata for md5/length verification of created/updated items
    rl_meta: dict[str, dict] = {}
    rl_url = caps.get("resourcelist")
    if rl_url:
        _, rl_items = parse_resource_list(fetch_bytes(rl_url))
        rl_meta = {item["loc"]: item for item in rl_items}

    files: dict[str, dict] = state.get("files", {})
    counts = {"created": 0, "updated": 0, "deleted": 0}

    for ev in new_events:
        loc = ev["loc"]
        change = ev["change"]
        dest = local_path_for(out_dir, loc)
        key = f"{ev['datetime']}|{change}|{loc}"

        if change in ("created", "updated"):
            meta = rl_meta.get(loc, {})
            md5, length = download_and_verify(
                loc,
                dest,
                expected_md5=meta.get("md5"),
                expected_length=meta.get("length"),
            )
            files[loc] = {"md5": md5, "length": length, "lastmod": ev["datetime"]}
            counts[change] += 1
            print(f"  [{change.upper()}] {loc} ({length} bytes, md5 verified)")
        elif change == "deleted":
            if dest.is_file():
                dest.unlink()
            files.pop(loc, None)
            counts["deleted"] += 1
            print(f"  [DELETED] {loc}")

        seen.add(key)

    state["last_sync"] = until_ts or state.get("last_sync")
    state["files"] = files
    state["seen_events"] = sorted(seen)
    save_state(out_dir, state)
    print(
        f"Incremental sync complete: {counts['created']} created, "
        f"{counts['updated']} updated, {counts['deleted']} deleted."
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Minimal ResourceSync 1.1 harvester (standard library only)."
    )
    parser.add_argument(
        "target",
        help="Site URL (e.g. https://nakamura196.github.io/lda/) or capabilitylist.xml URL",
    )
    parser.add_argument("output_dir", help="Local directory to mirror files into")
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Download only the first N resources on the initial sync (useful for demos)",
    )
    args = parser.parse_args(argv)

    cap_url = discover_capability_list(args.target)
    print(f"Capability List: {cap_url}")
    caps = parse_capability_list(fetch_bytes(cap_url))

    out_dir = Path(args.output_dir)
    state = load_state(out_dir)
    if state is None:
        return first_sync(caps, out_dir, args.limit)
    return incremental_sync(caps, out_dir, state)


if __name__ == "__main__":
    sys.exit(main())
