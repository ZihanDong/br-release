import os
import gc
import json
import shutil
import argparse
from collections import defaultdict
from typing import Optional, Any

from tqdm import tqdm
import torch
import torch.distributed as dist
from safetensors.torch import save_file, load_file
from accelerate import init_empty_weights
from transformers import AutoConfig, AutoTokenizer, AutoModelForCausalLM
from compressed_tensors.compressors import pack_to_int32
from utils import quantize_tensor

def parse_args():
    parser = argparse.ArgumentParser()
    # Model params
    parser.add_argument(
        "--model-name-or-path",
        type=str,
        required=True,
        help="The name or path to the DeepSeek model",
    )
    parser.add_argument(
        "--packed-model-path",
        type=str,
        required=True,
        help="Whether to save packed model."
    )
     # Misc params
    parser.add_argument(
        "--dtype",
        default="bfloat16",
        type=str,
        choices=["float16", "bfloat16"],
        help="Torch dtype used."
    )
    args = parser.parse_args()
    return args


def is_subset(set1: set, set2: set):
    return set1 <= set2


def pack_weight(
    qweight: torch.Tensor,
    scale: torch.Tensor,
    zero: torch.Tensor,
    bits: int,
    sym: bool,
    group_size: Optional[int] = None,
) -> dict[torch.Tensor]:
    compressed_data = {}
    #group_size = group_size or qweight.shape[-1]
    qweight_shifted = qweight.to(torch.int8)
    if not sym:
        qweight_shifted = qweight_shifted - zero.repeat_interleave(group_size, dim=-1).to(torch.int8)
    qweight_packed = pack_to_int32(qweight_shifted, bits)
    compressed_data = {
        "weight_packed": qweight_packed,
        "weight_shape": torch.tensor(qweight.shape),
        "weight_scale": scale
    }
    if not sym:
        compressed_data["weight_zero_point"] = zero
    return compressed_data


def prepare_quantization_config(args: argparse.Namespace) -> dict[str, Any]:
    ignored_modules = ["lm_head"]
    if args.quantize_only_experts:
        ignored_modules += [
            *[f"model.layers.{i}.self_attn.q_a_proj" for i in range(0, 61)],
            *[f"model.layers.{i}.self_attn.q_b_proj" for i in range(0, 61)],
            *[f"model.layers.{i}.self_attn.kv_a_proj_with_mqa" for i in range(0, 61)],
            *[f"model.layers.{i}.self_attn.kv_b_proj" for i in range(0, 61)],
            *[f"model.layers.{i}.self_attn.o_proj" for i in range(0, 61)],
            #*[f"model.layers.{i}.mlp.shared_experts.gate_proj" for i in range(3, 61)],
            *[f"model.layers.{i}.mlp.shared_experts.up_proj" for i in range(3, 61)],
            *[f"model.layers.{i}.mlp.shared_experts.down_proj" for i in range(3, 61)],
            *[f"model.layers.{i}.mlp.gate" for i in range(3, 61)],
        ]
    return {
        "config_groups": {
            "group_0": {
                "format": "pack-quantized",
                "input_activations": None,
                "output_activations": None,
                "targets": [
                    "Linear"
                ],
                "weights": {
                    "actorder": None,
                    "block_structure": None,
                    "dynamic": False,
                    "group_size": None,
                    #"group_size": None,
                    "num_bits": args.bits,
                    "observer": "minmax",
                    "observer_kwargs": {},
                    "strategy": "channel",
                    "symmetric": True,
                    "type": "int"
                }
            }
        },
        "format": "pack-quantized",
        "ignore": ignored_modules,
        "kv_cache_scheme": None,
        "quant_method": "compressed-tensors",
        "quantization_status": "compressed"
    }


def setup_distributed():
    """Initialize distributed training environment."""
    if not dist.is_initialized():
        dist.init_process_group(backend="nccl")
    local_rank = int(os.environ.get("LOCAL_RANK", 0))
    world_size = int(os.environ.get("WORLD_SIZE", 1))
    rank = int(os.environ.get("RANK", 0))

    torch.cuda.set_device(local_rank)
    return local_rank, rank, world_size


def cleanup_distributed():
    """Clean up distributed training environment."""
    if dist.is_initialized():
        dist.destroy_process_group()


def distribute_layers(total_layers: int, world_size: int, rank: int):
    """Distribute layers across processes."""
    layers_per_rank = total_layers // world_size
    remainder = total_layers % world_size

    start_layer = rank * layers_per_rank + min(rank, remainder)
    end_layer = start_layer + layers_per_rank + (1 if rank < remainder else 0)

    return start_layer, end_layer


def process_layer_range(args, model, start_layer, end_layer, total_layers, rank, world_size):
    """Process a range of layers for the current rank."""
    index_map = {}

    pbar = tqdm(
        desc=f"Rank {rank} processing transformer blocks",
        total=end_layer - start_layer,
        position=rank
    )
    for layer_id in range(start_layer, end_layer):
        file_name = f"model-{layer_id:05}-of-{total_layers:05}.safetensors"
        weight_dict = load_file(os.path.join(args.model_name_or_path, file_name), device=f"cuda:{rank}")

        new_state_dict = {}
        for weight_name, w in weight_dict.items():
            if 'weight_scale_inv' in weight_name:
                continue
            if 'block_sparse_moe.experts.' in weight_name or \
                'self_attn.q_proj' in weight_name or \
                'self_attn.k_proj' in weight_name or \
                'self_attn.v_proj' in weight_name or \
                'self_attn.o_proj' in weight_name or \
                'mlp.down_proj' in weight_name: # need to quantize
                qweight, scales, zeros = quantize_tensor(w, args.sym, args.bits, args.group_size)
                packed_weight_state_dict = pack_weight(qweight, scales, zeros, args.bits, args.sym, args.group_size)
                weight_prefix = weight_name.rsplit('.', 1)[0]
                new_state_dict.update({f"{weight_prefix}.{k}": v for k, v in packed_weight_state_dict.items()})
                index_map.update({f"{weight_prefix}.{k}": file_name for k in packed_weight_state_dict.keys()})
            else:
                new_state_dict[weight_name] = w
                index_map[weight_name] = file_name

        save_file(new_state_dict, os.path.join(args.packed_model_path, file_name))

        del weight_dict
        del new_state_dict
        gc.collect()
        pbar.update(1)
    pbar.close()

    return index_map


def main():
    args = parse_args()

    # Initialize distributed training
    local_rank, rank, world_size = setup_distributed()

    if rank == 0:
        os.makedirs(args.packed_model_path, exist_ok=True)

    # Wait for rank 0 to create directory
    dist.barrier()

    # Load DeepSeek model config (all ranks)
    config = AutoConfig.from_pretrained(args.model_name_or_path, trust_remote_code=True)
    if hasattr(config, "quantization_config"):
        delattr(config, "quantization_config")

    with init_empty_weights():
        model = AutoModelForCausalLM.from_config(
            config=config,
            trust_remote_code=True,
            torch_dtype=torch.bfloat16
        ).eval()
        model.config.use_cache = False

    # Only rank 0 handles tokenizer and config saving
    if rank == 0:
        tokenizer = AutoTokenizer.from_pretrained(args.model_name_or_path, trust_remote_code=True)

    args.bits = 8
    args.group_size = -1
    args.quantize_only_experts = False
    args.sym = True

    # Process blocks in distributed manner
    total_layers_num = 130

    # Distribute layers across processes
    start_layer, end_layer = distribute_layers(total_layers_num, world_size, rank)

    print(f"Rank {rank} processing layers {start_layer} to {end_layer-1}")

    # Process assigned layers
    index_map_partial = process_layer_range(
        args, model, start_layer, end_layer, total_layers_num, rank, world_size
    )

    # Gather all index maps to rank 0
    all_index_maps = [None] * world_size if rank == 0 else None
    dist.gather_object(index_map_partial, all_index_maps, dst=0)

    # Rank 0 handles final file operations
    if rank == 0:
        # Merge all index maps
        index_map = {}
        for im in all_index_maps:
            index_map.update(im)

        # Handle the final file (embedding and lm_head)
        file_name = f"model-{total_layers_num-1:05}-of-{total_layers_num:05}.safetensors"
        names = load_file(
            os.path.join(args.model_name_or_path, file_name),
            device="cuda:0"
        ).keys()
        for name in names:
            index_map[name] = file_name
        shutil.copy(
            os.path.join(args.model_name_or_path, file_name),
            os.path.join(args.packed_model_path, file_name)
        )

        # Save index file
        new_model_index_file = os.path.join(args.packed_model_path, "model.safetensors.index.json")
        with open(new_model_index_file, "w") as f:
            json.dump({"metadata": {}, "weight_map": index_map}, f, indent=2)

        # Save configs
        config.quantization_config = prepare_quantization_config(args)
        config.save_pretrained(args.packed_model_path)
        model.generation_config.save_pretrained(args.packed_model_path)

        # Save tokenizer
        tokenizer.save_pretrained(args.packed_model_path)

        # Copy modeling script
        shutil.copy(
            os.path.join(args.model_name_or_path, "modeling_minimax_m2.py"),
            args.packed_model_path
        )

    # Wait for all processes to finish
    dist.barrier()
    cleanup_distributed()


if __name__ == "__main__":
    main()
