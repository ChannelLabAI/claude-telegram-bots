#!/usr/bin/env python3
"""
gbrain-daemon.py — persistent gbrain MCP HTTP wrapper (AC6 fix).

Starts a single long-lived `gbrain serve` process (MCP/stdio).
Serves HTTP on localhost:PORT so callers skip per-query bun startup (~400ms).
Caches query embeddings: repeated queries return immediately (~1ms) vs ~2-3s.

Usage:
  python3 gbrain-daemon.py [--port 5099]

Environment:
  GBRAIN_BIN          — path to gbrain binary (default: ~/.bun/bin/gbrain)
  GBRAIN_DAEMON_PORT  — HTTP port (default: 5099)
  OPENAI_API_KEY      — required for vector search
"""

import os
import sys
import json
import threading
import queue
import signal
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import subprocess
import argparse

GBRAIN = os.environ.get("GBRAIN_BIN", str(Path.home() / ".bun/bin/gbrain"))
PORT = int(os.environ.get("GBRAIN_DAEMON_PORT", "5099"))


class MCPClient:
    """Long-lived gbrain serve subprocess with JSON-RPC 2.0 over stdio."""

    def __init__(self):
        env = os.environ.copy()
        self.proc = subprocess.Popen(
            [GBRAIN, "serve"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        self._id = 0
        self._pending: dict[int, queue.Queue] = {}
        self._lock = threading.Lock()
        self._cache: dict[str, object] = {}

        self._reader_thread = threading.Thread(target=self._reader, daemon=True)
        self._reader_thread.start()

        # MCP handshake
        resp = self._rpc("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "gbrain-daemon", "version": "1.0"},
        })
        if not resp.get("result"):
            raise RuntimeError(f"gbrain serve initialize failed: {resp}")

        # Send initialized notification (no id = fire and forget)
        self._notify("notifications/initialized", {})

    def _next_id(self) -> int:
        with self._lock:
            self._id += 1
            return self._id

    def _write(self, msg: dict) -> None:
        self.proc.stdin.write(json.dumps(msg).encode() + b"\n")
        self.proc.stdin.flush()

    def _notify(self, method: str, params: dict) -> None:
        self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def _rpc(self, method: str, params: dict, timeout: float = 10.0) -> dict:
        rid = self._next_id()
        result_q: queue.Queue = queue.Queue()
        with self._lock:
            self._pending[rid] = result_q
        self._write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        try:
            return result_q.get(timeout=timeout)
        except queue.Empty:
            return {"error": "timeout"}
        finally:
            with self._lock:
                self._pending.pop(rid, None)

    def _reader(self) -> None:
        for line in self.proc.stdout:
            try:
                msg = json.loads(line)
                rid = msg.get("id")
                if rid is not None:
                    with self._lock:
                        q = self._pending.get(rid)
                    if q:
                        q.put(msg)
            except Exception:
                pass

    def query(self, text: str, limit: int = 5) -> list[dict]:
        cache_key = f"{text}:{limit}"
        if cache_key in self._cache:
            return self._cache[cache_key]

        resp = self._rpc("tools/call", {
            "name": "query",
            "arguments": {"query": text, "limit": limit},
        }, timeout=15.0)

        results = []
        content = resp.get("result", {}).get("content", [])
        for item in content:
            if item.get("type") == "text":
                try:
                    results = json.loads(item["text"])
                except Exception:
                    pass
                break

        self._cache[cache_key] = results
        return results

    def shutdown(self) -> None:
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            pass


_client: MCPClient | None = None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args) -> None:
        pass  # suppress access logs

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self) -> None:
        if self.path != "/query":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))

        t0 = time.perf_counter()
        results = _client.query(body.get("query", ""), body.get("limit", 5))
        elapsed_ms = int((time.perf_counter() - t0) * 1000)

        # Convert to the same flat format as gbrain CLI output
        flat = []
        for r in results:
            flat.append({
                "slug": r.get("slug", ""),
                "content": r.get("chunk_text") or r.get("content") or "",
                "score": r.get("score", 0.0),
                "source": "gbrain",
                "path": r.get("slug", ""),
            })

        resp_body = json.dumps({"results": flat, "elapsed_ms": elapsed_ms}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(resp_body))
        self.end_headers()
        self.wfile.write(resp_body)


def main() -> None:
    global _client

    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()

    print(f"Starting gbrain MCP client ({GBRAIN})...", flush=True)
    _client = MCPClient()
    print(f"GBrain daemon ready → http://127.0.0.1:{args.port}", flush=True)

    def _shutdown(sig, frame):
        print("Shutting down...", flush=True)
        _client.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
