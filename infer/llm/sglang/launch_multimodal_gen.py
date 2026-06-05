#!/usr/bin/env python3
"""Entry point for SGLang multimodal_gen (image generation) servers.

Mirrors the LLM path (`python3 -m sglang.launch_server <args>`), but sglang's
multimodal_gen has no `-m` entry, so this thin module provides one. It MUST be a
real importable file: multimodal_gen forces multiprocessing 'spawn'
(diffusion_generator.py: mp.set_start_method("spawn", force=True)), so every
worker re-imports the main module — re-running the `import sglang_br` below to
re-register the SUPA platform in that worker. A `python3 -c` string cannot be
re-imported and the workers would crash (platform NotImplementedError).

All server args come from the command line (built by sglang_launch.sh from the
model config) — there are NO hardcoded defaults here. The BRTB/SUDNN env is
exported by the caller (sglang_server.sh) before launch and inherited by workers.

Usage (normally invoked by sglang_launch.sh / sglang_server.sh):
    python3 launch_multimodal_gen.py --model-path <path> --num-gpus 1 --port 38000 ...
"""
import sys

import sglang_br  # noqa: F401  — patches torch -> SUPA backend; registers the SUPA platform

from sglang.multimodal_gen.runtime.launch_server import launch_server
from sglang.multimodal_gen.runtime.server_args import prepare_server_args


def _apply_wan_vae_workaround(server_args) -> None:
    """Disable Wan VAE parallel encode/decode (matches the offline test path).

    On the BirenTech builds the Wan VAE parallel-decode path raises
    NameError 'split_for_parallel_decode' (the import is missing), so multi-GPU
    VAE decode fails at the DecodingStage. The offline DiffGenerator passes
    vae_config.use_parallel_{encode,decode}=False for the same reason. No CLI flag
    exposes these, and they must be set on server_args BEFORE the workers spawn
    (server_args is pickled to them — the offline kwargs path proves this works).
    Guarded to Wan pipelines so image models (e.g. Qwen-Image) are untouched.
    """
    pc = getattr(server_args, "pipeline_config", None)
    if pc is None or "wan" not in type(pc).__name__.lower():
        return
    vae = getattr(pc, "vae_config", None)
    if vae is None:
        return
    for _f in ("use_parallel_encode", "use_parallel_decode"):
        if hasattr(vae, _f):
            setattr(vae, _f, False)


if __name__ == "__main__":
    _server_args = prepare_server_args(sys.argv[1:])
    _apply_wan_vae_workaround(_server_args)
    launch_server(_server_args)
