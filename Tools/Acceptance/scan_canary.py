#!/usr/bin/env python3
"""Scan exported app data and redacted logs for a secret canary without printing it."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from typing import Iterable, Iterator


CHUNK_SIZE = 1024 * 1024


class CanaryScanError(ValueError):
    pass


def _iter_files(roots: Iterable[Path]) -> Iterator[Path]:
    for root in roots:
        if root.is_file():
            yield root
            continue
        if not root.is_dir():
            raise CanaryScanError("a scan root does not exist")
        for directory, _, filenames in os.walk(root, followlinks=False):
            for filename in sorted(filenames):
                path = Path(directory, filename)
                if not path.is_symlink():
                    yield path


def _contains(file_path: Path, needle: bytes) -> bool:
    overlap = b""
    with file_path.open("rb") as file:
        while chunk := file.read(CHUNK_SIZE):
            candidate = overlap + chunk
            if needle in candidate:
                return True
            overlap = candidate[-(len(needle) - 1) :] if len(needle) > 1 else b""
    return False


def scan_paths(
    needle: bytes,
    roots: Iterable[Path],
    *,
    excluded_paths: Iterable[Path] = (),
) -> dict[str, object]:
    if not needle:
        raise CanaryScanError("the canary is empty")

    excluded = {path.resolve() for path in excluded_paths}
    scanned_files = 0
    scanned_bytes = 0
    matching_file_count = 0
    unreadable_file_count = 0

    for path in _iter_files(roots):
        try:
            resolved = path.resolve()
            if resolved in excluded:
                continue
            size = path.stat().st_size
            found = _contains(path, needle)
        except OSError:
            unreadable_file_count += 1
            continue
        scanned_files += 1
        scanned_bytes += size
        if found:
            matching_file_count += 1

    if unreadable_file_count:
        raise CanaryScanError(f"{unreadable_file_count} file(s) could not be scanned")
    if scanned_files == 0:
        raise CanaryScanError("no files were scanned")
    return {
        "status": "fail" if matching_file_count else "pass",
        "scannedFileCount": scanned_files,
        "scannedByteCount": scanned_bytes,
        "matchingFileCount": matching_file_count,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--needle-file",
        required=True,
        type=Path,
        help="a file outside the scan roots containing only the canary value",
    )
    parser.add_argument("roots", nargs="+", type=Path, help="files or directories to scan")
    arguments = parser.parse_args()

    try:
        needle = arguments.needle_file.read_bytes().rstrip(b"\r\n")
        result = scan_paths(
            needle,
            arguments.roots,
            excluded_paths=(arguments.needle_file,),
        )
    except OSError:
        print("Canary scan failed without disclosing the canary: an input file could not be read", file=sys.stderr)
        return 2
    except CanaryScanError as error:
        print(f"Canary scan failed without disclosing the canary: {error}", file=sys.stderr)
        return 2

    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if result["matchingFileCount"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
