#!/usr/bin/env python3
"""Minimal worker-side Autonomic EffectSocket client. Standard library only."""
from __future__ import annotations
import argparse, base64, hashlib, json, socket, struct, sys, uuid
from dataclasses import dataclass
from typing import Any

PROTOCOL = 1
MAX_FRAME = 1_048_576

@dataclass
class BrokerClient:
    socket_path: str
    epoch: int

    def _roundtrip(self, request: dict[str, Any]) -> Any:
        request = {"protocol": PROTOCOL, "request_id": uuid.uuid4().hex, "epoch": self.epoch, **request}
        payload = json.dumps(request, separators=(",", ":")).encode()
        if not 0 < len(payload) <= MAX_FRAME:
            raise ValueError("request frame out of bounds")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(self.socket_path)
            sock.sendall(struct.pack(">I", len(payload)) + payload)
            size = struct.unpack(">I", _recv_exact(sock, 4))[0]
            if not 0 < size <= MAX_FRAME:
                raise RuntimeError("response frame out of bounds")
            response = json.loads(_recv_exact(sock, size))
        if not response.get("ok"):
            raise RuntimeError(response.get("error", "broker error"))
        return response.get("result")

    def prepare(self, lease_id: str, kind: str, target_id: str, payload: bytes, target: dict[str, Any] | None = None) -> dict[str, Any]:
        return self._roundtrip({"action": "prepare", "lease_id": lease_id, "kind": kind, "target_id": target_id, "target": target or {}, "payload_b64": base64.b64encode(payload).decode()})

    def evaluate(self, effect_id: str) -> dict[str, Any]: return self._roundtrip({"action": "evaluate", "effect_id": effect_id})
    def commit(self, effect_id: str) -> dict[str, Any]: return self._roundtrip({"action": "commit", "effect_id": effect_id})
    def abort(self, effect_id: str) -> dict[str, Any]: return self._roundtrip({"action": "abort", "effect_id": effect_id})
    def status(self, effect_id: str) -> dict[str, Any]: return self._roundtrip({"action": "status", "effect_id": effect_id})

    def fetch_response(self, effect_id: str, chunk_size: int = 262_144) -> bytes:
        offset, chunks, expected_digest, total = 0, [], None, None
        while True:
            result = self._roundtrip({"action": "fetch_response", "effect_id": effect_id, "offset": offset, "limit": chunk_size})
            chunk = base64.b64decode(result["chunk_b64"], validate=True)
            if len(chunk) != result["bytes"] or result["offset"] != offset:
                raise RuntimeError("response chunk contract violated")
            expected_digest = expected_digest or result["body_digest"]
            total = total if total is not None else result["total_bytes"]
            if result["body_digest"] != expected_digest or result["total_bytes"] != total:
                raise RuntimeError("response metadata changed between chunks")
            chunks.append(chunk); offset += len(chunk)
            if result["eof"]: break
            if not chunk: raise RuntimeError("non-EOF empty chunk")
        body = b"".join(chunks)
        if len(body) != total or hashlib.sha256(body).hexdigest() != expected_digest:
            raise RuntimeError("response digest/length verification failed")
        return body

def _recv_exact(sock: socket.socket, size: int) -> bytes:
    out = bytearray()
    while len(out) < size:
        data = sock.recv(size - len(out))
        if not data: raise RuntimeError("socket closed mid-frame")
        out.extend(data)
    return bytes(out)

def self_test() -> None:
    sample = {"protocol": PROTOCOL, "request_id": "a" * 32, "epoch": 7, "action": "status", "effect_id": "b" * 32}
    payload = json.dumps(sample, separators=(",", ":")).encode()
    frame = struct.pack(">I", len(payload)) + payload
    assert struct.unpack(">I", frame[:4])[0] == len(payload)
    assert json.loads(frame[4:]) == sample
    body = b"chunked response"
    assert hashlib.sha256(body).hexdigest() == hashlib.sha256(b"chunked response").hexdigest()
    print("worker_sdk.py self-test: PASS")

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--socket")
    parser.add_argument("--epoch", type=int)
    parser.add_argument("--effect-id")
    args = parser.parse_args()
    if args.self_test: self_test(); return
    if not (args.socket and args.epoch and args.effect_id): parser.error("live status requires --socket --epoch --effect-id")
    print(json.dumps(BrokerClient(args.socket, args.epoch).status(args.effect_id), indent=2))

if __name__ == "__main__": main()
