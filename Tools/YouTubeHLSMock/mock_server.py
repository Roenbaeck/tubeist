#!/usr/bin/env python3

"""Development-only HTTPS server for Tubeist's uploader socket tests."""

from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import socket
import socketserver
import ssl
import sys
import threading
import time
from dataclasses import dataclass


PATH_PREFIX = "/http_upload_hls?cid=redacted&copy=0&file="
USER_AGENT = "Apple / SocketTest / Tubeist-1"


@dataclass(frozen=True)
class RequestRecord:
    method: str
    path: str
    filename: str
    content_type: str
    user_agent: str
    body: bytes
    client_port: int


class ValidationServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self) -> None:
        # HTTPServer.server_bind performs socket.getfqdn() after binding. A
        # loopback-only validation server does not need reverse DNS, and hosted
        # CI runners can block in that lookup long enough to fail readiness.
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port

    def __init__(self, address: tuple[str, int], scenario: str):
        super().__init__(address, ValidationHandler)
        self.scenario = scenario
        self.records: list[RequestRecord] = []
        self.records_lock = threading.Lock()
        self.expected_requests = {
            "contract": 4,
            "reconnect": 3,
            "timeout": 3,
            "stop": 1,
            "cancel": 1,
        }[scenario]

    def add_record(self, record: RequestRecord) -> int:
        with self.records_lock:
            index = len(self.records)
            self.records.append(record)
            return index

    def finish_if_complete(self) -> None:
        with self.records_lock:
            complete = len(self.records) >= self.expected_requests
        if complete:
            threading.Thread(target=self.shutdown, daemon=True).start()

    def handle_error(self, request: object, client_address: tuple[str, int]) -> None:
        if self.scenario in {"timeout", "stop", "cancel"}:
            # These cases deliberately tear down TLS while the handler is
            # sleeping or waiting for another keep-alive request.
            return
        super().handle_error(request, client_address)


class ValidationHandler(http.server.BaseHTTPRequestHandler):
    server: ValidationServer
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:
        try:
            content_length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            content_length = -1
        body = self.rfile.read(content_length) if content_length >= 0 else b""
        filename = self.path[len(PATH_PREFIX) :] if self.path.startswith(PATH_PREFIX) else ""
        record = RequestRecord(
            method=self.command,
            path=self.path,
            filename=filename,
            content_type=self.headers.get("Content-Type", ""),
            user_agent=self.headers.get("User-Agent", ""),
            body=body,
            client_port=self.client_address[1],
        )
        index = self.server.add_record(record)

        if self.server.scenario == "reconnect" and index == 0:
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
            self.server.finish_if_complete()
            return

        if self.server.scenario in {"timeout", "stop", "cancel"} and index == 0:
            time.sleep(0.5)

        status = 202 if index % 2 else 200
        try:
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        finally:
            self.server.finish_if_complete()

    def log_message(self, format: str, *args: object) -> None:
        return


def expected_playlist(second: bool) -> bytes:
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:3",
        f"#EXT-X-TARGETDURATION:{3 if second else 2}",
        "#EXT-X-MEDIA-SEQUENCE:0",
        "#EXT-X-INDEPENDENT-SEGMENTS",
        "#EXTINF:2.000000,",
        "tubeist_socket_session_0.ts",
    ]
    if second:
        lines.extend(["#EXTINF:2.500000,", "tubeist_socket_session_1.ts"])
    return ("\n".join(lines) + "\n").encode()


def validate_common(records: list[RequestRecord]) -> None:
    for record in records:
        if record.method != "POST":
            raise AssertionError(f"unexpected method: {record.method}")
        if not record.path.startswith(PATH_PREFIX) or "%" in record.path:
            raise AssertionError(f"filename suffix was encoded or malformed: {record.path}")
        if record.user_agent != USER_AGENT:
            raise AssertionError(f"unexpected User-Agent: {record.user_agent}")
        expected_type = (
            "application/vnd.apple.mpegurl"
            if record.filename.endswith(".m3u8")
            else "video/mp2t"
        )
        if record.content_type != expected_type:
            raise AssertionError(f"unexpected Content-Type: {record.content_type}")


def validate(scenario: str, records: list[RequestRecord]) -> None:
    validate_common(records)
    if scenario == "contract":
        expected_files = [
            "tubeist_socket_session.m3u8",
            "tubeist_socket_session_0.ts",
            "tubeist_socket_session.m3u8",
            "tubeist_socket_session_1.ts",
        ]
        if [record.filename for record in records] != expected_files:
            raise AssertionError("playlist/segment request order or filenames differ")
        expected_bodies = [expected_playlist(False), b"\x01\x02\x03", expected_playlist(True), b"\x04\x05"]
        if [record.body for record in records] != expected_bodies:
            raise AssertionError("playlist or segment request bytes differ")
        if len({record.client_port for record in records}) != 1:
            raise AssertionError("the sequential session did not reuse its HTTP connection")
    elif scenario in {"reconnect", "timeout"}:
        if len(records) != 3:
            raise AssertionError(f"expected three requests, received {len(records)}")
        if records[0].filename != records[1].filename or records[0].body != records[1].body:
            raise AssertionError("the retried playlist changed filename or body")
        if records[2].filename != "tubeist_socket_session_0.ts":
            raise AssertionError("segment did not follow the recovered playlist upload")
        if len({records[0].client_port, records[1].client_port}) < 2:
            raise AssertionError("the failed socket was not replaced for the retry")
    elif scenario in {"stop", "cancel"}:
        if len(records) != 1 or records[0].filename != "tubeist_socket_session.m3u8":
            raise AssertionError("shutdown allowed unexpected follow-up requests")


def write_log(path: str, scenario: str, records: list[RequestRecord]) -> None:
    serializable = [
        {
            "scenario": scenario,
            "method": record.method,
            "path": record.path,
            "filename": record.filename,
            "content_type": record.content_type,
            "user_agent": record.user_agent,
            "body_bytes": len(record.body),
            "body_sha256": hashlib.sha256(record.body).hexdigest(),
            "client_port": record.client_port,
        }
        for record in records
    ]
    with open(path, "w", encoding="utf-8") as output:
        json.dump(serializable, output, indent=2, sort_keys=True)
        output.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", choices=["contract", "reconnect", "timeout", "stop", "cancel"], required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log-file", required=True)
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--key", required=True)
    arguments = parser.parse_args()

    server = ValidationServer(("127.0.0.1", 0), arguments.scenario)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(arguments.certificate, arguments.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    with open(arguments.port_file, "w", encoding="utf-8") as port_file:
        port_file.write(str(server.server_port))

    try:
        server.serve_forever(poll_interval=0.01)
        validate(arguments.scenario, server.records)
        write_log(arguments.log_file, arguments.scenario, server.records)
        print(f"HTTPS mock scenario passed: {arguments.scenario}")
        return 0
    except Exception as error:
        write_log(arguments.log_file, arguments.scenario, server.records)
        print(f"HTTPS mock scenario failed: {arguments.scenario}: {error}", file=sys.stderr)
        return 1
    finally:
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
