#!/bin/zsh
set -euo pipefail
tool_directory=${0:A:h}
repository_root=${tool_directory:h:h}
artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/tubeist-resilience.XXXXXX")
echo "Validation artifacts: ${artifact_root}"
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "${artifact_root}/module-cache" \
  "${repository_root}/Tubeist/ISOBMFFReader.swift" \
  "${repository_root}/Tubeist/EncodedMedia.swift" \
  "${repository_root}/Tubeist/MPEGTransportStreamMuxer.swift" \
  "${repository_root}/Tubeist/MediaEncoders.swift" \
  "${repository_root}/Tubeist/CaptureContinuity.swift" \
  "${repository_root}/Tubeist/RecordingAssetWriter.swift" \
  "${repository_root}/Tubeist/LiveEncodingPipeline.swift" \
  "${repository_root}/Tubeist/Fragment.swift" \
  "${repository_root}/Tubeist/FragmentReorderBuffer.swift" \
  "${repository_root}/Tubeist/HLSMediaPlaylist.swift" \
  "${repository_root}/Tubeist/YouTubeHLSUploader.swift" \
  "${repository_root}/Tubeist/EncodedOutputRouter.swift" \
  "${repository_root}/Tubeist/AdaptiveBitrateController.swift" \
  "${repository_root}/Tools/VideoToolboxProbe/MediaFixtures.swift" \
  "${tool_directory}/Support.swift" "${tool_directory}/main.swift" -o "${artifact_root}/probe"
scenarios=(watchdog healthy startup-audio-overlap short-gaps processing-pressure both-stall audio-stall video-stall clock-reset stabilization-changes audio-pool-startup audio-pool-recovery network-overflow)
if (( $# > 0 )); then scenarios=("$@"); fi
for scenario in "${scenarios[@]}"; do
  "${artifact_root}/probe" "${artifact_root}/${scenario}" "${scenario}"
  if [[ "$scenario" != watchdog ]]; then
    python3 "${tool_directory}/verify.py" "${artifact_root}/${scenario}"
  fi
done
