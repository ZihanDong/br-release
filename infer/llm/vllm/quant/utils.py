import torch
from typing import Tuple


def quantize_tensor(
    weight: torch.Tensor,
    sym: bool,
    bits: int,
    group_size: int,
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """
    Per-channel or per-group integer quantization.

    Returns (qweight, scale, zero_point):
      - qweight  : quantized weight (int8), same shape as input
      - scale    : per-channel/group scale  (float32), shape (out_features,) or (groups,)
      - zero     : zero-point (float32); all-zero for symmetric quantization
    """
    qmax = 2 ** (bits - 1) - 1   # 127  for int8
    qmin = -(2 ** (bits - 1))     # -128 for int8

    w = weight.float()
    out_features = w.shape[0]

    # Flatten to (out_features, in_features) for per-channel,
    # or to (num_groups, group_size) for per-group.
    if group_size is None or group_size <= 0:
        w_flat = w.reshape(out_features, -1)        # per output-channel
    else:
        in_features = w.numel() // out_features
        w_flat = w.reshape(-1, group_size)           # per group

    if sym:
        max_abs = w_flat.abs().max(dim=-1, keepdim=True).values
        scale = (max_abs / qmax).clamp(min=1e-8)
        qweight = (w_flat / scale).round().clamp(qmin, qmax).to(torch.int8)
        zeros = torch.zeros(w_flat.shape[0], dtype=torch.float32, device=w.device)
    else:
        min_val = w_flat.min(dim=-1, keepdim=True).values
        max_val = w_flat.max(dim=-1, keepdim=True).values
        scale = ((max_val - min_val) / (qmax - qmin)).clamp(min=1e-8)
        zeros = (-min_val / scale).round()
        qweight = ((w_flat / scale) + zeros).round().clamp(qmin, qmax).to(torch.int8)
        zeros = zeros.squeeze(-1)

    scale = scale.squeeze(-1)
    qweight = qweight.reshape(w.shape)
    return qweight, scale, zeros
