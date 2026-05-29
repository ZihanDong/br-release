#!/usr/bin/env python3
"""OpenAI-compatible load balancer for vLLM backends.

Routes /v1/chat/completions and /v1/completions to enabled backends
in round-robin order per model. Supports both streaming (SSE) and
non-streaming responses.
"""

import asyncio
import json
import logging
import argparse
from collections import defaultdict
from typing import AsyncIterator, Dict, List

import yaml
import aiohttp
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import StreamingResponse, Response, JSONResponse
import uvicorn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger("lb_server")


class RoundRobinPool:
    """Thread-safe round-robin selector for a list of backend URLs."""

    def __init__(self, urls: List[str]):
        self._urls = urls
        self._idx = 0
        self._lock = asyncio.Lock()

    async def next(self) -> str:
        async with self._lock:
            url = self._urls[self._idx % len(self._urls)]
            self._idx += 1
            return url

    def __len__(self):
        return len(self._urls)


class LoadBalancer:
    def __init__(self):
        self.pools: Dict[str, RoundRobinPool] = {}
        self.timeout_secs: int = 3600

    def load_config(self, path: str):
        with open(path) as f:
            config = yaml.safe_load(f)

        groups: Dict[str, List[str]] = defaultdict(list)
        for b in config.get("backends", []):
            if not b.get("enabled", True):
                logger.info(f"Skipping disabled backend: {b.get('model')} @ {b.get('ip')}:{b.get('port')}")
                continue
            model = b["model"]
            url = f"http://{b['ip']}:{b['port']}"
            groups[model].append(url)
            logger.info(f"Registered backend: model={model} url={url}")

        self.pools = {m: RoundRobinPool(urls) for m, urls in groups.items()}
        logger.info(
            f"Config loaded — {len(self.pools)} model(s): "
            + ", ".join(f"{m}({len(p)} backends)" for m, p in self.pools.items())
        )

    async def get_backend(self, model: str) -> str:
        pool = self.pools.get(model)
        if pool is None:
            known = list(self.pools.keys())
            raise HTTPException(
                status_code=404,
                detail=f"No backend registered for model '{model}'. Known models: {known}",
            )
        url = await pool.next()
        logger.info(f"Route: model='{model}' -> {url}")
        return url


lb = LoadBalancer()
app = FastAPI(title="vLLM Load Balancer")


@app.get("/v1/models")
async def list_models():
    data = [
        {"id": m, "object": "model", "created": 0, "owned_by": "vllm", "backends": len(p)}
        for m, p in lb.pools.items()
    ]
    return JSONResponse({"object": "list", "data": data})


@app.get("/health")
async def health():
    return {"status": "ok", "models": {m: len(p) for m, p in lb.pools.items()}}


async def _proxy(request: Request, endpoint: str) -> Response:
    body = await request.body()

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Request body must be valid JSON")

    model = payload.get("model", "")
    if not model:
        raise HTTPException(status_code=400, detail="'model' field is required")

    backend_url = await lb.get_backend(model)
    target = f"{backend_url}/{endpoint}"

    # Forward headers, strip hop-by-hop / host
    skip = {"host", "content-length", "transfer-encoding", "connection"}
    fwd_headers = {k: v for k, v in request.headers.items() if k.lower() not in skip}

    is_stream = bool(payload.get("stream", False))
    timeout = aiohttp.ClientTimeout(total=lb.timeout_secs)

    if is_stream:
        async def _stream() -> AsyncIterator[bytes]:
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(target, data=body, headers=fwd_headers) as resp:
                    if resp.status >= 400:
                        err = await resp.text()
                        yield f"data: {json.dumps({'error': err})}\n\n".encode()
                        return
                    async for chunk in resp.content.iter_any():
                        if chunk:
                            yield chunk

        return StreamingResponse(
            _stream(),
            media_type="text/event-stream",
            headers={
                "X-LB-Backend": backend_url,
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )
    else:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(target, data=body, headers=fwd_headers) as resp:
                content = await resp.read()
                return Response(
                    content=content,
                    status_code=resp.status,
                    media_type="application/json",
                    headers={"X-LB-Backend": backend_url},
                )


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    return await _proxy(request, "v1/chat/completions")


@app.post("/v1/completions")
async def completions(request: Request):
    return await _proxy(request, "v1/completions")


@app.post("/v1/embeddings")
async def embeddings(request: Request):
    return await _proxy(request, "v1/embeddings")


def main():
    parser = argparse.ArgumentParser(description="OpenAI-compatible vLLM load balancer")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, required=True, help="Bind port")
    parser.add_argument("--config", required=True, help="Path to backends config YAML")
    parser.add_argument(
        "--timeout", type=int, default=3600,
        help="Per-request timeout in seconds (default: 3600)"
    )
    args = parser.parse_args()

    lb.timeout_secs = args.timeout
    lb.load_config(args.config)

    logger.info(f"Starting load balancer on {args.host}:{args.port} (timeout={args.timeout}s)")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
