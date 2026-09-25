# Transport stream service metadata

Tubeist writes a DVB Service Description Table (SDT) once per HLS media segment,
after the initial PAT and PMT. Those two packets remain first, as recommended by
[YouTube's HLS ingest specification](https://developers.google.com/youtube/v3/live/guides/hls-ingestion).

The provider is `Tubeist`. The service name is the broadcast title resolved at
Start from the YouTube Settings preferences and broadcast preflight. Without
API access, the saved title is used; an empty title falls back to `Tubeist live
stream`. The title is fixed for the session and the table is constructed once.
The YouTube ingestion key (`ingestionInfo.streamName`) is never used as a service
name.

Other fields follow the inspected FFmpeg 8.0.1 HLS output: PID `0x11`, table ID
`0x42`, transport/service IDs `1`, original network ID `0xff01`, version `0`,
running status `4`, service type `1`, no conditional access or EIT flags, and one
service descriptor (`0x48`). ASCII names are stored directly; other names carry
the DVB UTF-8 selector `0x15`. Control characters are removed and long names are
truncated at character boundaries to fit the descriptor's one-byte length.
An SDT uses one 188-byte packet, or two for long titles. Its continuity counter
persists across segments; its CRC covers the complete section.

This is a Sony/YouTube live playback compatibility experiment, not a confirmed
fix. The offline references reconstructed from the old relay input and newer
recordings had identical SDTs in all 103 inspected FFmpeg segments. They used
provider `FFmpeg`, service name `Service01`, and placed SDT before PAT/PMT. These
were reconstructed references, not captures of the historical relay uploads.
Tubeist previously omitted SDT. Adding it does not alter encoded media, PTS/DTS,
PCR, segment cuts, upload scheduling, or playlist handling. Repeated live Sony
tests are still needed because the black playback was intermittent.

Reference: [FFmpeg SDT generation and text encoding](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavformat/mpegtsenc.c#L797).
