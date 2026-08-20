#!/bin/zsh

set -euo pipefail

tool_directory=${0:A:h}
artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/tubeist-media-evidence.XXXXXX")
recording="${artifact_root}/recording.mp4"

echo "Validation artifacts: ${artifact_root}"

ffmpeg \
  -hide_banner \
  -loglevel error \
  -f lavfi \
  -i testsrc2=size=320x180:rate=30 \
  -f lavfi \
  -i sine=frequency=1000:sample_rate=48000 \
  -t 3 \
  -map 0:v:0 \
  -map 1:a:0 \
  -vf format=yuv420p10le \
  -c:v libx265 \
  -preset ultrafast \
  -x265-params keyint=30:min-keyint=30:scenecut=0:bframes=3:open-gop=0:colorprim=9:transfer=18:colormatrix=9 \
  -tag:v hvc1 \
  -pix_fmt yuv420p10le \
  -c:a aac \
  -profile:a aac_low \
  -b:a 96k \
  -ac 2 \
  -ar 48000 \
  -movflags +faststart \
  "${recording}"

PYTHONDONTWRITEBYTECODE=1 python3 "${tool_directory}/compare_media.py" \
  --report "${tool_directory}/Fixtures/acceptance_schema3.jsonl" \
  --recording "${recording}" \
  --youtube-archive "${recording}" \
  --expected-width 320 \
  --expected-height 180 \
  --expected-frame-rate 30 \
  --expected-audio-channels 2 \
  --max-duration-delta 0.25 \
  --max-av-skew 0.1 \
  >"${artifact_root}/comparison.json"

echo "Generated media evidence comparison passed"
