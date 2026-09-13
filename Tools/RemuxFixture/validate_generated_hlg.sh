#!/bin/zsh

set -euo pipefail

tool_directory=${0:A:h}
repository_root=${tool_directory:h:h}
artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/tubeist-remux-validation.XXXXXX")
work_directory="${artifact_root}/test-results"
mkdir -p "${work_directory}"
tool_binary="${work_directory}/tubeist-remux-fixture"

echo "Validation artifacts: ${work_directory}"

xcrun swiftc \
  -swift-version 6 \
  -parse-as-library \
  -module-cache-path "${work_directory}/module-cache" \
  "${repository_root}/Tubeist/ISOBMFFReader.swift" \
  "${repository_root}/Tubeist/MPEGTransportStreamMuxer.swift" \
  "${tool_directory}/main.swift" \
  -o "${tool_binary}"

ffmpeg \
  -hide_banner \
  -loglevel error \
  -f lavfi \
  -i testsrc2=size=128x72:rate=30 \
  -f lavfi \
  -i sine=frequency=1000:sample_rate=48000 \
  -t 3 \
  -map 0:v:0 \
  -map 1:a:0 \
  -vf format=yuv420p10le \
  -c:v libx265 \
  -preset ultrafast \
  -x265-params keyint=30:min-keyint=30:scenecut=0:bframes=3:colorprim=9:transfer=18:colormatrix=9 \
  -tag:v hvc1 \
  -pix_fmt yuv420p10le \
  -c:a aac \
  -b:a 96k \
  -ac 2 \
  -ar 48000 \
  -f hls \
  -hls_time 1 \
  -hls_list_size 0 \
  -hls_segment_type fmp4 \
  -hls_flags independent_segments \
  -hls_fmp4_init_filename initialization.mp4 \
  -hls_segment_filename "${work_directory}/fragment_%03d.m4s" \
  "${work_directory}/source.m3u8"

"${tool_binary}" \
  "${work_directory}/initialization.mp4" \
  "${work_directory}/remuxed" \
  "${work_directory}/fragment_000.m4s" \
  "${work_directory}/fragment_001.m4s" \
  "${work_directory}/fragment_002.m4s"

concat_input="concat:${work_directory}/remuxed/segment_0000.ts|${work_directory}/remuxed/segment_0001.ts|${work_directory}/remuxed/segment_0002.ts"
probe_output=$(ffprobe \
  -v error \
  -show_entries stream=codec_name,profile,pix_fmt,color_space,color_transfer,color_primaries,sample_rate,channels \
  -of default=noprint_wrappers=1 \
  "${concat_input}")

required_probe_values=(
  "codec_name=hevc"
  "profile=Main 10"
  "pix_fmt=yuv420p10le"
  "color_space=bt2020nc"
  "color_transfer=arib-std-b67"
  "color_primaries=bt2020"
  "codec_name=aac"
  "profile=LC"
  "sample_rate=48000"
  "channels=2"
)
for required_value in ${required_probe_values}; do
  if [[ ${probe_output} != *${required_value}* ]]; then
    echo "Missing ffprobe value: ${required_value}" >&2
    exit 1
  fi
done

ffmpeg \
  -hide_banner \
  -v error \
  -i "${concat_input}" \
  -map 0:v:0 \
  -map 0:a:0 \
  -f null \
  -

echo "Generated HLG remux validation passed"
