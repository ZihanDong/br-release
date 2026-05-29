#!/usr/bin/env python3
"""Mock vLLM backend for load-balancer testing.

Simulates OpenAI-compatible /v1/chat/completions (streaming + non-streaming).
Exposes /stats so the test runner can verify request counts per backend.
"""

import argparse
import asyncio
import json
import time
import logging
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, JSONResponse
import uvicorn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

app = FastAPI()
server_id: str = "?"
request_count: int = 0
request_log: list = []   # [(seq, model, stream)]


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    global request_count
    request_count += 1
    seq = request_count

    body = await request.json()
    model = body.get("model", "unknown")
    is_stream = bool(body.get("stream", False))

    request_log.append({"seq": seq, "model": model, "stream": is_stream})
    logging.getLogger("mock").info(
        f"[{server_id}] req#{seq} model={model} stream={is_stream}"
    )

    if is_stream:
        async def _generate():
            words = ["Hello", " from", f" backend-{server_id}", "!"]
            for i, word in enumerate(words):
                chunk = {
                    "id": f"chatcmpl-{server_id}-{seq}",
                    "object": "chat.completion.chunk",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "delta": (
                            {"role": "assistant", "content": ""} if i == 0
                            else {"content": word}
                        ),
                        "finish_reason": None,
                    }],
                }
                yield f"data: {json.dumps(chunk)}\n\n"
                await asyncio.sleep(0.03)

            final = {
                "id": f"chatcmpl-{server_id}-{seq}",
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            }
            yield f"data: {json.dumps(final)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(_generate(), media_type="text/event-stream")

    response = {
        "id": f"chatcmpl-{server_id}-{seq}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": f"Hello from backend-{server_id}! (request #{seq})",
            },
            "finish_reason": "stop",
        }],
        "usage": {"prompt_tokens": 5, "completion_tokens": 15, "total_tokens": 20},
    }
    return JSONResponse(response)


@app.get("/v1/models")
async def list_models():
    return JSONResponse({"object": "list", "data": []})


@app.get("/stats")
async def stats():
    return JSONResponse({
        "server_id": server_id,
        "request_count": request_count,
        "requests": request_log,
    })


@app.get("/health")
async def health():
    return {"status": "ok", "server_id": server_id}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--id", required=True, help="Human-readable backend identifier")
    args = parser.parse_args()

    server_id = args.id
    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="warning")
