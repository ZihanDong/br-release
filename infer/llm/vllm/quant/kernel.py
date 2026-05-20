"""
Pure-PyTorch implementation of weight_dequant for block-wise FP8 (float8_e4m3fn).

Replaces the compiled CUDA extension from DeepSeek-V3 for offline quantization use.
Slower than the CUDA kernel but correct for the offline weight conversion pipeline.

Block layout (from MiniMax M2.5 config):
  weight_block_size = [128, 128]
  scale_inv shape   = (M // 128, N // 128)   for weight of shape (M, N)
"""

import torch


def weight_dequant(x: torch.Tensor, s: torch.Tensor, block_size: int = 128) -> torch.Tensor:
    """
    Block-wise FP8 weight dequantization.

    Args:
        x: FP8 weight tensor (float8_e4m3fn), shape (M, N)
        s: Per-block inverse scale tensor (float32),
           shape (ceil(M/block_size), ceil(N/block_size))
        block_size: Block size used during FP8 quantization (default 128)

    Returns:
        BF16 dequantized tensor of shape (M, N)
    """
    assert x.dim() == 2, f"weight_dequant expects 2-D tensor, got shape {x.shape}"
    M, N = x.shape

    # Expand per-block scales to full weight shape via repeat_interleave,
    # then trim to exact (M, N) in case of non-divisible dimensions.
    s_full = (
        s.to(torch.float32)
         .repeat_interleave(block_size, dim=0)[:M]
         .repeat_interleave(block_size, dim=1)[:, :N]
    )

    return (x.to(torch.float32) * s_full).to(torch.bfloat16)
