#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/tubeist-style-effect.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -O -module-cache-path "$build_dir/module-cache" \
    "$repo_root/Tools/StyleEffectProbe/main.swift" -o "$build_dir/probe"
"$build_dir/probe" "$repo_root"
