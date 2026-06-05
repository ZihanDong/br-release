"""
Qwen-Image-2512 在线服务客户端示例。
调用 POST /v1/images/generations，将文生图结果保存到本地。
 
前提：先运行 qwen_image_2512_testcase.py 拉起服务。
 
用法：
    python client.py
    python client.py \
        --host 127.0.0.1 --port 38000 \
        --prompt "a cup of coffee" \
        --width 1024 --height 1024 \
        --output outputs/
"""
 
import argparse
import base64
import os
import sys
import time
from urllib.parse import urljoin
 
import requests
 
 
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 38000
DEFAULT_PROMPT = "a cup of coffee"
DEFAULT_OUTPUT = "outputs/"
 
 
def wait_for_server(base_url: str, timeout: int = 300) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = requests.get(f"{base_url}/health", timeout=5)
            if r.status_code == 200:
                print(f"[client] 服务已就绪：{base_url}")
                return
        except requests.exceptions.ConnectionError:
            pass
        time.sleep(5)
    print(f"[client] 等待服务超时（{timeout}s），请检查服务是否正常启动。", file=sys.stderr)
    sys.exit(1)
 
 
def generate_image(
    base_url: str,
    prompt: str,
    negative_prompt: str | None = None,
    num_inference_steps: int | None = None,
    guidance_scale: float | None = None,
    true_cfg_scale: float | None = None,
    seed: int = 1024,
    width: int | None = None,
    height: int | None = None,
    output_dir: str = "outputs/",
) -> str:
    url = f"{base_url}/v1/images/generations"
    payload: dict = {
        "prompt": prompt,
        "n": 1,
        "response_format": "b64_json",
        "seed": seed,
    }
 
    if negative_prompt is not None:
        payload["negative_prompt"] = negative_prompt
    if num_inference_steps is not None:
        payload["num_inference_steps"] = num_inference_steps
    if guidance_scale is not None:
        payload["guidance_scale"] = guidance_scale
    if true_cfg_scale is not None:
        payload["true_cfg_scale"] = true_cfg_scale
    if width is not None and height is not None:
        payload["size"] = f"{width}x{height}"
 
    print(f"[client] 发送请求 → {url}")
    print(f"[client]   prompt: {prompt}")
    if "size" in payload:
        print(f"[client]   size: {payload['size']}")
 
    t0 = time.time()
    response = requests.post(url, json=payload, timeout=None)
    elapsed = time.time() - t0
 
    response.raise_for_status()
    result = response.json()
 
    print(f"[client] 请求完成，耗时 {elapsed:.2f} 秒")
 
    os.makedirs(output_dir, exist_ok=True)
 
    saved_paths = []
    for i, item in enumerate(result.get("data", [])):
        b64 = item.get("b64_json")
        if b64:
            out_path = os.path.join(output_dir, f"qwen_image_2512_{int(time.time())}_{i}.png")
            with open(out_path, "wb") as f:
                f.write(base64.b64decode(b64))
            print(f"[client] 输出已保存：{out_path}")
            saved_paths.append(out_path)
            continue
 
        image_url = item.get("url")
        if image_url:
            if image_url.startswith("/"):
                image_url = urljoin(base_url, image_url)
            print(f"[client] 输出 URL：{image_url}")
            saved_paths.append(image_url)
 
    return saved_paths[0] if saved_paths else ""
 
 
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Qwen-Image-2512 在线服务客户端")
    parser.add_argument("--host", default=DEFAULT_HOST, help="服务 host")
    parser.add_argument("--port", default=DEFAULT_PORT, type=int, help="服务端口")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT, help="文生图提示词")
    parser.add_argument("--negative-prompt", default=None, help="负向提示词")
    parser.add_argument("--steps", default=30, type=int, help="推理步数（默认 30）")
    parser.add_argument("--cfg", default=None, type=float, help="guidance_scale")
    parser.add_argument("--true-cfg", default=None, type=float, help="true_cfg_scale")
    parser.add_argument("--seed", default=1024, type=int, help="随机种子")
    parser.add_argument("--width", default=None, type=int, help="输出图片宽度")
    parser.add_argument("--height", default=None, type=int, help="输出图片高度")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="输出目录")
    parser.add_argument(
        "--wait",
        action="store_true",
        help="发请求前先轮询 /health 等待服务就绪",
    )
    return parser.parse_args()
 
 
def main() -> None:
    args = parse_args()
    base_url = f"http://{args.host}:{args.port}"
 
    if args.wait:
        wait_for_server(base_url)
 
    generate_image(
        base_url=base_url,
        prompt=args.prompt,
        negative_prompt=args.negative_prompt,
        num_inference_steps=args.steps,
        guidance_scale=args.cfg,
        true_cfg_scale=args.true_cfg,
        seed=args.seed,
        width=args.width,
        height=args.height,
        output_dir=args.output,
    )
 
 
if __name__ == "__main__":
    main()
