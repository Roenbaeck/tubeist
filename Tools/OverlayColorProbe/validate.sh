#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/tubeist-overlay-color.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -module-cache-path "$build_dir/module-cache" \
    "$repo_root/Tubeist/ImprintArguments.swift" \
    "$repo_root/Tools/OverlayColorProbe/main.swift" -o "$build_dir/probe"
"$build_dir/probe" "$repo_root/Tubeist/Kernels.metal" "$@"
