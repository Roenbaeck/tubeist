#!/bin/zsh
set -euo pipefail
tool_directory=${0:A:h}
repository_root=${tool_directory:h:h}
artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/tubeist-hevc-recovery.XXXXXX")
echo "Recovery artifacts: ${artifact_root}"

# Replace only the callback boundary in an isolated copy. Everything that
# handles the error, filters output, assigns timestamps, muxes and records is
# production code. An errored callback has no sample, as on VideoToolbox.
python3 - "${repository_root}/Tubeist/MediaEncoders.swift" "${artifact_root}/MediaEncoders.swift" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
original = '.receive(status: status, flags: flags, frame: Int(bitPattern: frameRefcon), sample: sample)'
replacement = '''.receive(status: RecoveryFaults.frames.contains(Int(bitPattern: frameRefcon)) ? -12911 : status,
                             flags: flags, frame: Int(bitPattern: frameRefcon),
                             sample: RecoveryFaults.frames.contains(Int(bitPattern: frameRefcon)) ? nil : sample)'''
assert source.count(original) == 1, 'Update the probe to match the encoder callback boundary'
source = source.replace(original, replacement)
source += '''
private enum RecoveryFaults {
    static let frames = Set((ProcessInfo.processInfo.environment["TUBEIST_PROBE_FAILED_FRAMES"] ?? "")
        .split(separator: ",").compactMap { Int($0) })
}
'''
pathlib.Path(sys.argv[2]).write_text(source)
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "${artifact_root}/module-cache" \
  "${repository_root}/Tubeist/ISOBMFFReader.swift" \
  "${repository_root}/Tubeist/EncodedMedia.swift" \
  "${repository_root}/Tubeist/MPEGTransportStreamMuxer.swift" \
  "${artifact_root}/MediaEncoders.swift" \
  "${repository_root}/Tubeist/HEVCReordering.swift" \
  "${repository_root}/Tubeist/CaptureContinuity.swift" \
  "${repository_root}/Tubeist/RecordingAssetWriter.swift" \
  "${tool_directory}/MediaFixtures.swift" \
  "${tool_directory}/main.swift" -o "${artifact_root}/probe"

# Initial keyframe, reordered reference picture, regular GOP boundary,
# repeated errors during recovery, and a failure at the end of the stream.
for failed_frames in 1 25 61 25,29 372; do
  media_directory="${artifact_root}/failed-${failed_frames}"
  TUBEIST_PROBE_FAILED_FRAMES="$failed_frames" "${artifact_root}/probe" "$media_directory" 30 2 44100
  python3 "${tool_directory}/verify_recovery.py" "$media_directory"
done
