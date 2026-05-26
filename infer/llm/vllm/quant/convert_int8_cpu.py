#!/usr/bin/env python3
"""
CPU-only, single-process INT8 quantization for MiniMax M2.5.

Replaces convert-to-compressed.py for environments without CUDA / NCCL.
Uses model.safetensors.index.json for shard navigation — works with any
safetensor file count (does not rely on hardcoded "model-XXXXX-of-00130" names).

Quantization scheme: INT8 symmetric channel-wise (bits=8, group_size=-1, sym=True).
Targets: MoE expert weights, attention projections, MLP down_proj.
"""

import os
import gc
import json
import shutil
import argparse
from collections import defaultdict

import torch
from tqdm import tqdm
from safetensors.torch import save_file, load_file
from compressed_tensors.compressors import pack_to_int32
from transformers import AutoConfig, AutoTokenizer

from utils import quantize_tensor


# Layers that get INT8 quantization (same policy as original convert-to-compressed.py)
_QUANTIZE_PATTERNS = [
    "block_sparse_moe.experts.",
    "self_attn.q_proj",
    "self_attn.k_proj",
    "self_attn.v_proj",
    "self_attn.o_proj",
    "mlp.down_proj",
]


def should_quantize(weight_name: str) -> bool:
    return any(p in weight_name for p in _QUANTIZE_PATTERNS)


def pack_weight_int8(qweight: torch.Tensor, scale: torch.Tensor) -> dict:
    # pack_to_int32 packs the last dim: [out, in] -> [out, in//4].
    # The framework's weight_loader applies .t() to the loaded weight when
    # is_transposed=True, so the on-disk format [out, in//4] is correct —
    # do NOT pre-transpose here.
    #
    # Scales are also loaded with is_transposed=True, so .t() turns [N, 1]
    # into [1, N], matching the [E, 1, 2*intermediate] buffer in create_weights.
    return {
        "weight_packed": pack_to_int32(qweight.to(torch.int8), 8),
        "weight_shape": torch.tensor(qweight.shape),
        "weight_scale": scale.unsqueeze(-1),
    }


def quantization_config() -> dict:
    return {
        "config_groups": {
            "group_0": {
                "format": "pack-quantized",
                "input_activations": None,
                "output_activations": None,
                "targets": ["Linear"],
                "weights": {
                    "actorder": None,
                    "block_structure": None,
                    "dynamic": False,
                    "group_size": None,
                    "num_bits": 8,
                    "observer": "minmax",
                    "observer_kwargs": {},
                    "strategy": "channel",
                    "symmetric": True,
                    "type": "int",
                },
            }
        },
        "format": "pack-quantized",
        "ignore": ["lm_head"],
        "kv_cache_scheme": None,
        "quant_method": "compressed-tensors",
        "quantization_status": "compressed",
    }


def main():
    parser = argparse.ArgumentParser(
        description="Convert BF16 MiniMax M2.5 weights to INT8 pack-quantized format (CPU)."
    )
    parser.add_argument("--model-name-or-path", required=True,
                        help="Path to BF16 intermediate weights")
    parser.add_argument("--packed-model-path", required=True,
                        help="Output path for INT8 packed weights")
    parser.add_argument("--dtype", default="bfloat16", choices=["float16", "bfloat16"])
    args = parser.parse_args()

    src = args.model_name_or_path
    dst = args.packed_model_path
    os.makedirs(dst, exist_ok=True)

    # ── Load shard index ────────────────────────────────────────────────────────
    index_path = os.path.join(src, "model.safetensors.index.json")
    with open(index_path) as f:
        orig_index = json.load(f)
    weight_map = orig_index["weight_map"]  # weight_name → shard filename

    # Group weights by shard so we load each shard once
    file_to_weights = defaultdict(list)
    for wname, fname in weight_map.items():
        file_to_weights[fname].append(wname)

    new_index_map = {}  # new weight_name → shard filename

    # ── Process each shard ──────────────────────────────────────────────────────
    shard_files = sorted(file_to_weights.keys())
    for fname in tqdm(shard_files, desc="Quantizing shards"):
        state_dict = load_file(os.path.join(src, fname), device="cpu")
        new_state_dict = {}

        for weight_name, w in state_dict.items():
            if should_quantize(weight_name) and w.dim() == 2:
                w_bf16 = w.to(torch.bfloat16)
                qweight, scales, _zeros = quantize_tensor(
                    w_bf16, sym=True, bits=8, group_size=-1
                )
                packed = pack_weight_int8(qweight, scales)
                prefix = weight_name.rsplit(".", 1)[0]  # strip ".weight"
                for k, v in packed.items():
                    new_key = f"{prefix}.{k}"
                    new_state_dict[new_key] = v
                    new_index_map[new_key] = fname
            else:
                new_state_dict[weight_name] = w
                new_index_map[weight_name] = fname

        save_file(new_state_dict, os.path.join(dst, fname))

        del state_dict, new_state_dict
        gc.collect()

    # ── Save updated index ──────────────────────────────────────────────────────
    with open(os.path.join(dst, "model.safetensors.index.json"), "w") as f:
        json.dump({"metadata": {}, "weight_map": new_index_map}, f, indent=2)

    # ── Copy non-safetensor files (config, tokenizer, modeling scripts) ─────────
    for entry in os.listdir(src):
        src_path = os.path.join(src, entry)
        dst_path = os.path.join(dst, entry)
        if os.path.isfile(src_path) and not entry.endswith(".safetensors") \
                and entry != "model.safetensors.index.json":
            shutil.copy2(src_path, dst_path)

    # ── Save updated config with quantization metadata ──────────────────────────
    config = AutoConfig.from_pretrained(src, trust_remote_code=True)
    if hasattr(config, "quantization_config"):
        delattr(config, "quantization_config")
    config.quantization_config = quantization_config()
    config.save_pretrained(dst)

    try:
        tokenizer = AutoTokenizer.from_pretrained(src, trust_remote_code=True)
        tokenizer.save_pretrained(dst)
    except Exception as e:
        print(f"[WARN] Could not save tokenizer: {e}")

    print(f"\n[ OK ]  INT8 weights saved to: {dst}")
    print(f"[ OK ]  Total shards: {len(shard_files)}")
    print(f"[ OK ]  Total weight entries: {len(new_index_map)}")


if __name__ == "__main__":
    main()
