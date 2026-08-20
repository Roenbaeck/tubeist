#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

if rg -n \
    'FragmentPusher|Twitch|HLSServer|StreamDestination|EncodedStreamDelivery' \
    Tubeist \
    --glob '*.swift' \
    --glob '!CredentialStore.swift'
then
    echo "Forbidden legacy streaming reference found in production sources." >&2
    exit 1
fi

if rg -n \
    'https?://(?!([a-z0-9-]+\.)*(youtube\.com|googleapis\.com|google\.com))' \
    Tubeist/EncodedOutputRouter.swift \
    Tubeist/Streamer.swift \
    Tubeist/YouTubeHLSUploader.swift \
    Tubeist/YouTubeService.swift \
    --pcre2
then
    echo "Hard-coded non-YouTube production upload host found." >&2
    exit 1
fi

echo "YouTube-only production-source check passed."
