#!/usr/bin/env python3

"""Print a compact JSON box tree and fragmented-MP4 full-box flags."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


CONTAINERS = {"moov", "trak", "mdia", "minf", "stbl", "dinf", "mvex", "moof", "traf"}
FULL_BOXES = {"mfhd", "tfhd", "tfdt", "trun", "trex"}


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from(">I", data, offset)[0]


def u64(data: bytes, offset: int) -> int:
    return struct.unpack_from(">Q", data, offset)[0]


def walk(data: bytes, start: int, end: int, path: str) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    offset = start
    while offset < end:
        if end - offset < 8:
            raise ValueError(f"truncated box header at {offset}")
        size = u32(data, offset)
        box_type = data[offset + 4 : offset + 8].decode("latin-1")
        header_size = 8
        if size == 1:
            if end - offset < 16:
                raise ValueError(f"truncated extended box at {offset}")
            size = u64(data, offset + 8)
            header_size = 16
        elif size == 0:
            size = end - offset
        if size < header_size or offset + size > end:
            raise ValueError(f"invalid {box_type} size {size} at {offset}")

        payload = offset + header_size
        entry: dict[str, object] = {
            "path": f"{path}/{box_type}",
            "offset": offset,
            "size": size,
        }
        if box_type in FULL_BOXES:
            if payload + 4 > offset + size:
                raise ValueError(f"truncated full box {box_type}")
            version_and_flags = u32(data, payload)
            entry["version"] = version_and_flags >> 24
            entry["flags"] = f"0x{version_and_flags & 0x00FFFFFF:06x}"
            if box_type in {"mfhd", "tfhd"} and payload + 8 <= offset + size:
                entry["identifier"] = u32(data, payload + 4)
            elif box_type == "tfdt":
                version = version_and_flags >> 24
                entry["base_decode_time"] = (
                    u64(data, payload + 4) if version == 1 else u32(data, payload + 4)
                )
            elif box_type == "trun" and payload + 8 <= offset + size:
                entry["sample_count"] = u32(data, payload + 4)

        if box_type in CONTAINERS:
            entry["children"] = walk(
                data,
                payload,
                offset + size,
                str(entry["path"]),
            )
        result.append(entry)
        offset += size
    return result


def flatten(entries: list[dict[str, object]]) -> list[dict[str, object]]:
    flattened: list[dict[str, object]] = []
    for entry in entries:
        flattened.append(entry)
        children = entry.get("children")
        if isinstance(children, list):
            flattened.extend(flatten(children))
    return flattened


def assert_apple_layout(initialization: list[dict[str, object]], media: list[dict[str, object]]) -> None:
    initialization_boxes = flatten(initialization)
    media_boxes = flatten(media)
    if [entry["path"] for entry in initialization[:2]] != ["root/ftyp", "root/moov"]:
        raise AssertionError("Apple initialization does not begin with ftyp/moov")
    if sum(entry["path"].endswith("/trak") for entry in initialization_boxes) != 2:
        raise AssertionError("Apple initialization does not contain two tracks")
    if sum(entry["path"].endswith("/trex") for entry in initialization_boxes) != 2:
        raise AssertionError("Apple initialization does not contain two trex defaults")
    if [entry["path"] for entry in media[:2]] != ["root/moof", "root/mdat"]:
        raise AssertionError("Apple media fragment does not contain moof/mdat")
    trafs = [entry for entry in media_boxes if entry["path"].endswith("/traf")]
    truns = [entry for entry in media_boxes if entry["path"].endswith("/trun")]
    tfhds = [entry for entry in media_boxes if entry["path"].endswith("/tfhd")]
    tfdts = [entry for entry in media_boxes if entry["path"].endswith("/tfdt")]
    if len(trafs) != 2 or len(tfhds) != 2 or len(tfdts) != 2:
        raise AssertionError("Apple media fragment does not contain two complete traf headers")
    if len(truns) < 2:
        raise AssertionError("Apple media fragment does not contain media runs")
    if any(entry.get("version") != 1 for entry in tfdts):
        raise AssertionError("expected 64-bit Apple tfdt boxes")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("initialization", type=Path)
    parser.add_argument("media", type=Path)
    arguments = parser.parse_args()
    initialization = walk(arguments.initialization.read_bytes(), 0, arguments.initialization.stat().st_size, "root")
    media = walk(arguments.media.read_bytes(), 0, arguments.media.stat().st_size, "root")
    assert_apple_layout(initialization, media)
    print(json.dumps({"initialization": initialization, "media": media}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
