#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch

INPUT_DIM = 8
HIDDEN_DIM = 16
OUTPUT_DIM = 4


def device() -> torch.device:
    if not torch.cuda.is_available():
        raise RuntimeError("cuda_unavailable")
    return torch.device("cuda")


def run_model(values: list[float]) -> dict:
    dev = device()
    if len(values) < INPUT_DIM:
        values = values + [0.0] * (INPUT_DIM - len(values))
    values = values[:INPUT_DIM]

    torch.manual_seed(7)
    x = torch.tensor(values, dtype=torch.float32, device=dev).reshape(1, INPUT_DIM)
    w1 = torch.arange(INPUT_DIM * HIDDEN_DIM, dtype=torch.float32, device=dev).reshape(INPUT_DIM, HIDDEN_DIM)
    w1 = torch.sin(w1 / 11.0)
    b1 = torch.linspace(-0.5, 0.5, HIDDEN_DIM, device=dev)
    w2 = torch.arange(HIDDEN_DIM * OUTPUT_DIM, dtype=torch.float32, device=dev).reshape(HIDDEN_DIM, OUTPUT_DIM)
    w2 = torch.cos(w2 / 7.0)
    y = torch.softmax(torch.relu(x @ w1 + b1) @ w2, dim=1)
    probs = [round(float(v), 6) for v in y.detach().cpu().flatten()]
    return {
        "model": "poc-gpu-torch-mlp-v1",
        "device": torch.cuda.get_device_name(0),
        "cuda": torch.version.cuda,
        "input": values,
        "probabilities": probs,
        "class_id": max(range(len(probs)), key=probs.__getitem__),
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            try:
                dev = device()
                self.send_json(200, {"ok": True, "device": torch.cuda.get_device_name(dev)})
            except Exception as err:  # noqa: BLE001
                self.send_json(503, {"ok": False, "error": str(err)})
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
            values = request.get("values", [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
            if not isinstance(values, list):
                raise ValueError("values must be a list")
            result = run_model([float(v) for v in values])
        except Exception as err:  # noqa: BLE001
            self.send_json(500, {"error": str(err)})
            return
        self.send_json(200, result)

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
