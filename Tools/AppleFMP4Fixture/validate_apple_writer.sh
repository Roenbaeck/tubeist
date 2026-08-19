#!/bin/zsh

set -euo pipefail

tool_directory=${0:A:h}
repository_root=${tool_directory:h:h}
artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/tubeist-apple-fixture-validation.XXXXXX")
writer_binary="${artifact_root}/apple-fmp4-fixture"
remux_binary="${artifact_root}/tubeist-remux-fixture"

echo "Validation artifacts: ${artifact_root}"

xcrun swiftc \
  -swift-version 6 \
  -parse-as-library \
  -module-cache-path "${artifact_root}/module-cache-writer" \
  "${tool_directory}/main.swift" \
  -o "${writer_binary}"

xcrun swiftc \
  -swift-version 6 \
  -parse-as-library \
  -module-cache-path "${artifact_root}/module-cache-remux" \
  "${repository_root}/Tubeist/ISOBMFFReader.swift" \
  "${repository_root}/Tubeist/MPEGTransportStreamMuxer.swift" \
  "${repository_root}/Tools/RemuxFixture/main.swift" \
  -o "${remux_binary}"

for variant in 30_stereo 60_mono; do
  case ${variant} in
    30_stereo)
      frame_rate=30
      channels=2
      ;;
    60_mono)
      frame_rate=60
      channels=1
      ;;
  esac

  variant_directory="${artifact_root}/${variant}"
  apple_directory="${variant_directory}/apple"
  remux_directory="${variant_directory}/remuxed"
  mkdir -p "${apple_directory}" "${remux_directory}"
  source_file="${variant_directory}/source.mp4"

  ffmpeg \
    -hide_banner \
    -loglevel error \
    -f lavfi \
    -i "testsrc2=size=320x180:rate=${frame_rate}" \
    -f lavfi \
    -i "sine=frequency=1000:sample_rate=44100" \
    -t 3.2 \
    -map 0:v:0 \
    -map 1:a:0 \
    -vf format=yuv420p10le \
    -c:v libx265 \
    -preset ultrafast \
    -x265-params "keyint=${frame_rate}:min-keyint=${frame_rate}:scenecut=0:bframes=3:colorprim=9:transfer=18:colormatrix=9" \
    -tag:v hvc1 \
    -pix_fmt yuv420p10le \
    -c:a aac \
    -b:a 96k \
    -ac "${channels}" \
    -ar 44100 \
    -movflags +faststart \
    "${source_file}"

  "${writer_binary}" \
    "${source_file}" \
    "${apple_directory}" \
    "${frame_rate}" \
    "${channels}"

  fragments=("${apple_directory}"/fragment_*.m4s(N))
  if (( ${#fragments} < 3 )); then
    echo "Apple writer emitted fewer than three media fragments for ${variant}" >&2
    exit 1
  fi

  python3 "${tool_directory}/inspect_layout.py" \
    "${apple_directory}/initialization.mp4" \
    "${fragments[1]}" \
    >"${variant_directory}/apple_box_layout.json"

  # RecordingActor writes the initialization and media fragments byte-for-byte
  # into one fragmented MP4. FFmpeg's concat protocol presents precisely that
  # byte sequence without introducing a second muxer into this validation.
  recording_input="concat:${apple_directory}/initialization.mp4"
  for fragment in ${fragments}; do
    recording_input="${recording_input}|${fragment}"
  done
  recording_probe_output=$(ffprobe \
    -v error \
    -show_entries stream=codec_name,profile,pix_fmt,color_space,color_transfer,color_primaries,sample_rate,channels \
    -of default=noprint_wrappers=1 \
    "${recording_input}")
  print -r -- "${recording_probe_output}" >"${variant_directory}/recording_ffprobe.txt"

  "${remux_binary}" \
    "${apple_directory}/initialization.mp4" \
    "${remux_directory}" \
    "${fragments[1]}" \
    "${fragments[2]}" \
    "${fragments[3]}"

  concat_input="concat:${remux_directory}/segment_0000.ts|${remux_directory}/segment_0001.ts|${remux_directory}/segment_0002.ts"
  probe_output=$(ffprobe \
    -v error \
    -show_entries stream=codec_name,profile,pix_fmt,color_space,color_transfer,color_primaries,sample_rate,channels \
    -of default=noprint_wrappers=1 \
    "${concat_input}")
  print -r -- "${probe_output}" >"${variant_directory}/remuxed_ffprobe.txt"

  required_probe_values=(
    "codec_name=hevc"
    "profile=Main 10"
    "pix_fmt=yuv420p10le"
    "color_space=bt2020nc"
    "color_transfer=arib-std-b67"
    "color_primaries=bt2020"
    "codec_name=aac"
    "profile=LC"
    "sample_rate=44100"
    "channels=${channels}"
  )
  for required_value in ${required_probe_values}; do
    if [[ ${probe_output} != *${required_value}* ]]; then
      echo "Missing ${variant} ffprobe value: ${required_value}" >&2
      exit 1
    fi
    if [[ ${recording_probe_output} != *${required_value}* ]]; then
      echo "Missing ${variant} recording value: ${required_value}" >&2
      exit 1
    fi
  done

  ffmpeg \
    -hide_banner \
    -v error \
    -i "${recording_input}" \
    -map 0:v:0 \
    -map 0:a:0 \
    -f null \
    -

  ffmpeg \
    -hide_banner \
    -v error \
    -i "${concat_input}" \
    -map 0:v:0 \
    -map 0:a:0 \
    -f null \
    -
done

echo "Apple AVAssetWriter fMP4 recording/remux validation passed"
