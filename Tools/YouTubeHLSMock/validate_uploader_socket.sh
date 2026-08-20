#!/bin/zsh

set -euo pipefail

tool_directory=${0:A:h}
repository_root=${tool_directory:h:h}
artifact_root=$(mktemp -d "${TMPDIR:-/tmp}/tubeist-hls-socket-validation.XXXXXX")
tool_binary="${artifact_root}/uploader-socket-test"
certificate="${artifact_root}/localhost.crt"
private_key="${artifact_root}/localhost.key"
server_pid=""

cleanup() {
  if [[ -n ${server_pid} ]] && kill -0 ${server_pid} 2>/dev/null; then
    kill ${server_pid} 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Validation artifacts: ${artifact_root}"

xcrun swiftc \
  -swift-version 6 \
  -D DEBUG \
  -parse-as-library \
  -module-cache-path "${artifact_root}/module-cache" \
  "${repository_root}/Tubeist/HLSMediaPlaylist.swift" \
  "${repository_root}/Tubeist/YouTubeHLSUploader.swift" \
  "${tool_directory}/main.swift" \
  -o "${tool_binary}"

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 1 \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout "${private_key}" \
  -out "${certificate}" \
  >/dev/null 2>&1

for scenario in contract reconnect timeout stop cancel; do
  scenario_directory="${artifact_root}/${scenario}"
  mkdir -p "${scenario_directory}"
  port_file="${scenario_directory}/port"
  log_file="${scenario_directory}/requests.json"
  server_output="${scenario_directory}/server.log"

  python3 -u "${tool_directory}/mock_server.py" \
    --scenario "${scenario}" \
    --port-file "${port_file}" \
    --log-file "${log_file}" \
    --certificate "${certificate}" \
    --key "${private_key}" \
    >"${server_output}" 2>&1 &
  server_pid=$!

  readiness_started=${SECONDS}
  while [[ ! -s ${port_file} ]] && (( SECONDS - readiness_started < 30 )); do
    if ! kill -0 ${server_pid} 2>/dev/null; then
      echo "HTTPS mock server exited before becoming ready for ${scenario}" >&2
      sed -n '1,200p' "${server_output}" >&2
      wait ${server_pid} 2>/dev/null || true
      exit 1
    fi
    sleep 0.05
  done
  if [[ ! -s ${port_file} ]]; then
    echo "HTTPS mock server did not start for ${scenario}" >&2
    sed -n '1,200p' "${server_output}" >&2
    exit 1
  fi

  port=$(<"${port_file}")
  endpoint="https://127.0.0.1:${port}/http_upload_hls?cid=redacted&copy=0&file="
  "${tool_binary}" "${endpoint}" "${scenario}"
  wait ${server_pid}
  server_pid=""
done

trap - EXIT
echo "YouTube HLS uploader socket validation passed"
