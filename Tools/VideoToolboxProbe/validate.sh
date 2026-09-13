#!/bin/zsh
set -euo pipefail
tool_directory=${0:A:h}
repository_root=${tool_directory:h:h}
artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/tubeist-vt-validation.XXXXXX")
echo "Validation artifacts: ${artifact_root}"
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "${artifact_root}/module-cache" \
  "${repository_root}/Tubeist/ISOBMFFReader.swift" \
  "${repository_root}/Tubeist/EncodedMedia.swift" \
  "${repository_root}/Tubeist/MPEGTransportStreamMuxer.swift" \
  "${repository_root}/Tubeist/MediaEncoders.swift" \
  "${repository_root}/Tubeist/CaptureContinuity.swift" \
  "${repository_root}/Tubeist/RecordingAssetWriter.swift" \
  "${tool_directory}/MediaFixtures.swift" \
  "${tool_directory}/main.swift" -o "${artifact_root}/probe"
for scenario in 30:2:44100 60:1:44100 30:2:48000; do
  parts=("${(@s/:/)scenario}")
  fps=${parts[1]}
  channels=${parts[2]}
  input_rate=${parts[3]}
  media_directory="${artifact_root}/media-${fps}fps-${channels}ch-${input_rate}hz"
  "${artifact_root}/probe" "${media_directory}" "${fps}" "${channels}" "${input_rate}"
  cat "${media_directory}"/segment_*.ts > "${media_directory}/stream.ts"
  for name in stream.ts recording.mp4; do
    ffmpeg -v error -i "${media_directory}/${name}" -f null -
    ffprobe -v error -count_frames \
      -show_entries stream=codec_name,profile,pix_fmt,color_space,color_transfer,color_primaries,nb_read_frames,sample_rate,channels,duration,start_time \
      -of json "${media_directory}/${name}" > "${media_directory}/${name}.json"
  done
  python3 "${tool_directory}/verify.py" "${media_directory}"
done
