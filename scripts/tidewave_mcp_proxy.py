#!/usr/bin/env python3
"""Proxy a stable Codex Tidewave MCP URL to a worktree app instance."""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import urllib.response


DEFAULT_LISTEN_HOST = "127.0.0.1"
DEFAULT_LISTEN_PORT = 4499
DEFAULT_MCP_PATH = "/tidewave/mcp"

HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def normalize_path(path: str) -> str:
    if not path.startswith("/"):
        path = f"/{path}"
    return path.rstrip("/") or "/"


def normalize_target(raw_target: str, default_mcp_path: str) -> urllib.parse.SplitResult:
    parsed = urllib.parse.urlsplit(raw_target)

    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise argparse.ArgumentTypeError(
            "target must be an http(s) URL, for example http://localhost:4101"
        )

    path = normalize_path(parsed.path or "/")
    if path == "/":
        path = default_mcp_path

    return parsed._replace(path=path, query="", fragment="")


def forwardable_headers(headers: http.client.HTTPMessage) -> dict[str, str]:
    forwarded = {}

    for key, value in headers.items():
        lowered = key.lower()
        if lowered in HOP_BY_HOP_HEADERS or lowered in {"host", "content-length"}:
            continue
        forwarded[key] = value

    return forwarded


class TidewaveProxyServer(http.server.ThreadingHTTPServer):
    target: urllib.parse.SplitResult
    listen_path: str


class TidewaveProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TidewaveMcpProxy/0.1"

    def do_GET(self) -> None:
        self.proxy_request()

    def do_POST(self) -> None:
        self.proxy_request()

    def do_DELETE(self) -> None:
        self.proxy_request()

    def do_OPTIONS(self) -> None:
        self.proxy_request()

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stderr.write(f"[tidewave-mcp-proxy] {self.address_string()} - {fmt % args}\n")

    def proxy_request(self) -> None:
        incoming = urllib.parse.urlsplit(self.path)

        if incoming.path == "/health":
            self.respond_json(
                200,
                {
                    "ok": True,
                    "listen_path": self.server.listen_path,
                    "target": urllib.parse.urlunsplit(self.server.target),
                },
            )
            return

        if not self.is_proxy_path(incoming.path):
            self.respond_text(404, f"expected requests under {self.server.listen_path}\n")
            return

        target_url = self.target_url(incoming)
        body = self.read_body()
        request = urllib.request.Request(
            target_url,
            data=body,
            headers=forwardable_headers(self.headers),
            method=self.command,
        )

        try:
            with urllib.request.urlopen(request, timeout=None) as response:
                self.forward_response(response)
        except urllib.error.HTTPError as error:
            self.forward_response(error)
        except urllib.error.URLError as error:
            self.respond_text(502, f"could not reach Tidewave target {target_url}: {error}\n")

    def is_proxy_path(self, incoming_path: str) -> bool:
        listen_path = self.server.listen_path
        return incoming_path == listen_path or incoming_path.startswith(f"{listen_path}/")

    def target_url(self, incoming: urllib.parse.SplitResult) -> str:
        listen_path = self.server.listen_path
        suffix = incoming.path[len(listen_path) :]
        target_path = f"{self.server.target.path}{suffix}"

        return urllib.parse.urlunsplit(
            self.server.target._replace(path=target_path, query=incoming.query)
        )

    def read_body(self) -> bytes | None:
        content_length = self.headers.get("Content-Length")
        if content_length is None:
            return None

        length = int(content_length)
        if length == 0:
            return None

        return self.rfile.read(length)

    def forward_response(self, response: urllib.response.addinfourl) -> None:
        self.send_response(response.status)

        for key, value in response.headers.items():
            if key.lower() in HOP_BY_HOP_HEADERS:
                continue
            self.send_header(key, value)

        self.send_header("Connection", "close")
        self.end_headers()

        reader = getattr(response, "read1", response.read)
        while True:
            chunk = reader(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()

        self.close_connection = True

    def respond_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def respond_text(self, status: int, body: str) -> None:
        encoded = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(encoded)
        self.close_connection = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Expose a stable Tidewave MCP endpoint and forward it to a Phoenix "
            "dev server running from the active worktree."
        )
    )
    parser.add_argument(
        "target",
        type=lambda value: normalize_target(value, DEFAULT_MCP_PATH),
        help=(
            "Worktree app URL or full Tidewave MCP URL, for example "
            "http://localhost:4101 or http://localhost:4101/tidewave/mcp"
        ),
    )
    parser.add_argument("--host", default=DEFAULT_LISTEN_HOST, help="listen host")
    parser.add_argument(
        "--port", type=int, default=DEFAULT_LISTEN_PORT, help="listen port"
    )
    parser.add_argument(
        "--path",
        default=DEFAULT_MCP_PATH,
        type=normalize_path,
        help="stable local MCP path",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    server = TidewaveProxyServer((args.host, args.port), TidewaveProxyHandler)
    server.target = args.target
    server.listen_path = args.path

    stable_url = f"http://{args.host}:{args.port}{args.path}"
    target_url = urllib.parse.urlunsplit(args.target)
    print(f"Forwarding {stable_url} -> {target_url}", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Tidewave MCP proxy", file=sys.stderr)
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
