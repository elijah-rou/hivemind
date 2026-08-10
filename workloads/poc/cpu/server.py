#!/usr/bin/env python3
import hashlib
import json
import math
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIMENSIONS = 16
LABELS = ("inference", "routing", "gpu", "cpu", "serverless", "model")


def embed(text: str) -> list[float]:
    vector = [0.0] * DIMENSIONS
    tokens = text.lower().split()
    if not tokens:
        tokens = [text.lower()]
    for token in tokens:
        digest = hashlib.sha256(token.encode()).digest()
        for index in range(DIMENSIONS):
            vector[index] += (digest[index] - 127.5) / 127.5
    norm = math.sqrt(sum(value * value for value in vector)) or 1.0
    return [round(value / norm, 6) for value in vector]


def classify(vector: list[float]) -> dict[str, float | str]:
    scores: dict[str, float] = {}
    for label in LABELS:
        label_vec = embed(label)
        scores[label] = round(sum(a * b for a, b in zip(vector, label_vec)), 6)
    best = max(scores, key=scores.get)
    return {"label": best, "score": scores[best], "scores": scores}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"ok": True})
            return
        self.send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path != "/inference":
            self.send_json(404, {"error": "not_found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            request = json.loads(body.decode() or "{}")
        except json.JSONDecodeError as err:
            self.send_json(400, {"error": f"invalid_json: {err}"})
            return
        text = str(request.get("text", request.get("prompt", "hivemind poc")))
        vector = embed(text)
        result = classify(vector)
        self.send_json(200, {
            "model": "poc-cpu-hash-embedder-v1",
            "device": "cpu",
            "input_chars": len(text),
            "embedding": vector,
            "classification": result,
        })

    def log_message(self, fmt: str, *args: object) -> None:
        return

    def send_json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
