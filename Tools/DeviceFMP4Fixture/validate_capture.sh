#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: Tools/DeviceFMP4Fixture/validate_capture.sh <exported-fixture-directory>" >&2
  exit 64
fi

tool_directory=${0:A:h}
repository_root=${tool_directory:h:h}
capture_directory=${1:A}
initialization="${capture_directory}/initialization.mp4"
fragments=("${capture_directory}"/fragment_*.m4s(N))

if [[ ! -f ${initialization} ]]; then
  echo "Missing ${initialization}" >&2
  exit 1
fi
if (( ${#fragments} < 3 )); then
  echo "A device capture must contain at least three ordered media fragments" >&2
  exit 1
fi

artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/tubeist-device-fixture-validation.XXXXXX")
remux_directory="${artifact_root}/remuxed"
remux_binary="${artifact_root}/tubeist-remux-fixture"
mkdir -p "${remux_directory}"

echo "Validation artifacts: ${artifact_root}"

xcrun swiftc \
  -swift-version 6 \
  -parse-as-library \
  -module-cache-path "${artifact_root}/module-cache" \
  "${repository_root}/Tubeist/ISOBMFFReader.swift" \
  "${repository_root}/Tubeist/MPEGTransportStreamMuxer.swift" \
  "${repository_root}/Tools/RemuxFixture/main.swift" \
  -o "${remux_binary}"

python3 "${repository_root}/Tools/AppleFMP4Fixture/inspect_layout.py" \
  "${initialization}" \
  "${fragments[1]}" \
  >"${artifact_root}/device_box_layout.json"

"${remux_binary}" \
  "${initialization}" \
  "${remux_directory}" \
  "${fragments[@]}"

segments=("${remux_directory}"/segment_*.ts(N))
if (( ${#segments} != ${#fragments} )); then
  echo "Remuxed segment count does not match captured fragment count" >&2
  exit 1
fi

recording_input="concat:${initialization}"
for (( index = 1; index <= ${#fragments}; index++ )); do
  fragment=${fragments[$index]}
  recording_input="${recording_input}|${fragment}"
done

transport_input="concat:${segments[1]}"
for (( index = 2; index <= ${#segments}; index++ )); do
  segment=${segments[$index]}
  transport_input="${transport_input}|${segment}"
done

probe_entries="stream=codec_name,profile,pix_fmt,color_space,color_transfer,color_primaries,sample_rate,channels,r_frame_rate"
recording_probe=$(ffprobe \
  -v error \
  -show_entries "${probe_entries}" \
  -of default=noprint_wrappers=1 \
  "${recording_input}")
transport_probe=$(ffprobe \
  -v error \
  -show_entries "${probe_entries}" \
  -of default=noprint_wrappers=1 \
  "${transport_input}")
print -r -- "${recording_probe}" >"${artifact_root}/recording_ffprobe.txt"
print -r -- "${transport_probe}" >"${artifact_root}/transport_ffprobe.txt"

required_values=(
  "codec_name=hevc"
  "profile=Main 10"
  "pix_fmt=yuv420p10le"
  "color_space=bt2020nc"
  "color_transfer=arib-std-b67"
  "color_primaries=bt2020"
  "codec_name=aac"
  "profile=LC"
)
for required_value in ${required_values}; do
  if [[ ${recording_probe} != *${required_value}* ]]; then
    echo "Local recording is missing ${required_value}" >&2
    exit 1
  fi
  if [[ ${transport_probe} != *${required_value}* ]]; then
    echo "Transport stream is missing ${required_value}" >&2
    exit 1
  fi
done

for field in sample_rate channels r_frame_rate; do
  if [[ ${field} == r_frame_rate ]]; then
    stream_selector="v:0"
  else
    stream_selector="a:0"
  fi
  recording_value=$(ffprobe \
    -v error \
    -select_streams "${stream_selector}" \
    -show_entries "stream=${field}" \
    -of default=noprint_wrappers=1:nokey=1 \
    "${recording_input}" | head -n 1)
  transport_value=$(ffprobe \
    -v error \
    -select_streams "${stream_selector}" \
    -show_entries "stream=${field}" \
    -of default=noprint_wrappers=1:nokey=1 \
    "${transport_input}" | head -n 1)
  if [[ -z ${recording_value} || ${recording_value} != ${transport_value} ]]; then
    echo "Recording/transport ${field} mismatch: ${recording_value:-missing} vs ${transport_value:-missing}" >&2
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
  -i "${transport_input}" \
  -map 0:v:0 \
  -map 0:a:0 \
  -f null \
  -

if [[ -f "${capture_directory}/manifest.json" ]]; then
  cp "${capture_directory}/manifest.json" "${artifact_root}/capture_manifest.json"
fi

echo "Physical-device fMP4 recording/remux validation passed"
