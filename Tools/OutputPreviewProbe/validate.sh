#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/tubeist-output-preview.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -O -module-cache-path "$build_dir/module-cache" \
    "$repo_root/Tubeist/MetalOutputPipeline.swift" \
    "$repo_root/Tools/OutputPreviewProbe/main.swift" -o "$build_dir/probe"
"$build_dir/probe" "$repo_root/Tubeist/Kernels.metal"
