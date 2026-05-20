################################################################################
# Copyright(c)2020-2025 Shanghai Biren Technology Co., Ltd. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

from functools import lru_cache, wraps
from typing import Callable, Optional

import torch
import torch_br
from fastcore.basics import patch_to
from torch_br.utils.tensor_methods import Sbp

from vllm.distributed import (get_tensor_model_parallel_rank,
                               get_tensor_model_parallel_world_size)
from vllm.logger import init_logger, logger
from vllm.model_executor.layers.fused_moe.config import FusedMoEParallelConfig
from vllm.model_executor.layers.fused_moe.layer import (
    FusedMoE, UnquantizedFusedMoEMethod)
from vllm.model_executor.layers.fused_moe.router.fused_moe_router import (  # noqa: F401
    FusedMoERouter)
from vllm.model_executor.utils import set_weight_attrs
from vllm.platforms import current_platform
from vllm_br import envs
from vllm_br.utils.supa_cpu_allreduce import _isHardwareSupportFusedAllreduce
from ..br_utils import (_convert_to_crossed_numa_tensor,
                        _convert_to_numa_tensor, align_n, cross_weight_32)
from .supa_moe import fused_moe_dynamic, fused_moe_static, enable_fused_comm_compute

logger = init_logger(__name__)


# NOTE: all dynamic routing functions should has the same signature, so do static ones
# NOTE: following 2 routers are dynamic routers, notice that we permute supa_moe_router_v2_infer outputs
def supa_fused_shared_router_prefill_v2_infer(
    hidden_states: torch.Tensor,
    gating_weight: torch.Tensor,
    topk: int,
    moe_parallel_config: FusedMoEParallelConfig,
    shared_expert_weights: tuple[torch.Tensor, ...],
    num_expert_group: Optional[int] = 1,
    topk_group: Optional[int] = 1,
    scoring_func: str = "softmax",
    e_score_correction_bias: Optional[torch.Tensor] = None,
    router_norm_factor: float = 1.0,
    clamp_limit: Optional[float] = None,
):
    shared_output, _, indices_supa, indice_per_expert, prob_per_expert = torch_br.supa_fused_shared_router_prefill_v2_infer(
        hidden_states,
        shared_expert_weights[0],
        shared_expert_weights[1],
        gating_weight,
        0,
        topk,
        num_expert_group,
        topk_group,
        moe_parallel_config.ep_size,
        moe_parallel_config.ep_rank,
        scoring_func=scoring_func,
        e_score_correction_bias=e_score_correction_bias,
        router_norm_factor=router_norm_factor,
        clamp_limit=clamp_limit)
    return (shared_output, indices_supa, indice_per_expert, prob_per_expert)


def supa_moe_router_v2_infer(
    hidden_states: torch.Tensor,
    gating_weight: torch.Tensor,
    topk: int,
    moe_parallel_config: FusedMoEParallelConfig,
    shared_expert_weights: tuple[torch.Tensor, ...],
    num_expert_group: Optional[int] = None,
    topk_group: Optional[int] = None,
    scoring_func: str = "softmax",
    e_score_correction_bias: Optional[torch.Tensor] = None,
    router_norm_factor: float = 1.0,
    clamp_limit: Optional[float] = None,
):
    probs_supa, indices_supa, prob_per_expert, indice_per_expert = torch_br.supa_moe_router_v2_infer(
        hidden_states,
        gating_weight.permute(1, 0).contiguous(),
        topk,
        moe_parallel_config.ep_size,
        moe_parallel_config.ep_rank,
        scoring_func=scoring_func,
        gating_bias=e_score_correction_bias)
    return (None, indices_supa, indice_per_expert, prob_per_expert)


# Note: following 2 routers are static routers
def supa_fused_shared_router_v1_v2_infer(
    hidden_states: torch.Tensor,
    gating_weight: torch.Tensor,
    topk: int,
    moe_parallel_config: FusedMoEParallelConfig,
    shared_expert_weights: tuple[torch.Tensor, ...],
    num_expert_group: Optional[int] = 1,
    topk_group: Optional[int] = 1,
    scoring_func: str = "softmax",
    e_score_correction_bias: Optional[torch.Tensor] = None,
    router_norm_factor: float = 1.0,
    clamp_limit: Optional[float] = None,
):
    if moe_parallel_config.ep_size == 1:
        assert router_norm_factor == 1.0, "Router norm factor is not supported for single expert group"
        assert clamp_limit is None, "Clamp limit is not supported for single expert group"
        shared_output, masked_probs, hitted_experts = torch_br.supa_fused_shared_router_infer(
            hidden_states,
            shared_expert_weights[0],
            shared_expert_weights[1],
            gating_weight,
            0,
            topk,
            num_expert_group,
            topk_group,
            scoring_func,
            e_score_correction_bias=e_score_correction_bias
            if e_score_correction_bias is not None else torch.empty(
                (gating_weight.shape[-1]),
                dtype=torch.float32,
                device=hidden_states.device))
    else:
        shared_output, masked_probs, hitted_experts = torch_br.supa_fused_shared_router_v2_infer(
            hidden_states,
            shared_expert_weights[0],
            shared_expert_weights[1],
            gating_weight,
            0,
            topk,
            num_expert_group,
            topk_group,
            moe_parallel_config.ep_size,
            moe_parallel_config.ep_rank,
            scoring_func=scoring_func,
            e_score_correction_bias=e_score_correction_bias
            if e_score_correction_bias is not None else torch.empty(
                (gating_weight.shape[-1]),
                dtype=torch.float32,
                device=hidden_states.device),
            router_norm_factor=router_norm_factor,
            clamp_limit=clamp_limit)
    return (shared_output, masked_probs, hitted_experts)


def supa_moe_router_decoder_infer(
    hidden_states: torch.Tensor,
    gating_weight: torch.Tensor,
    topk: int,
    moe_parallel_config: FusedMoEParallelConfig,
    shared_expert_weights: tuple[torch.Tensor, ...],
    num_expert_group: Optional[int] = 1,
    topk_group: Optional[int] = 1,
    scoring_func: str = "softmax",
    e_score_correction_bias: Optional[torch.Tensor] = None,
    router_norm_factor: float = 1.0,
    clamp_limit: Optional[float] = None,
):
    shared_output, masked_probs, hitted_experts = torch_br.supa_moe_router_decoder_infer(
        hidden_states, gating_weight, topk, moe_parallel_config.ep_size,
        moe_parallel_config.ep_rank, scoring_func=scoring_func, gating_bias=e_score_correction_bias)
    return (shared_output, masked_probs, hitted_experts)


@lru_cache(maxsize=2)
def get_custom_routing_function(use_grouped_topk: bool,
                                has_shared_expert: bool,
                                mode='dynamic',
                                act_mode='act_swiglu'):
    """
    Return a routing function callable based on routing configuration and mode.

    Selects appropriate Torch BR routing functions according to whether grouped top-k
    routing is used, whether a shared expert is present, and the mode (dynamic or static).

    Args:
        use_grouped_topk (bool): Whether grouped top-k routing is enabled.
        has_shared_expert (bool): Whether a shared expert is used.
        mode (str): The mode of routing, either 'dynamic' or 'static'. Defaults to 'dynamic'.

    Returns:
        callable: The selected routing function.

    Raises:
        AssertionError: If configuration combinations are unsupported.
    """
    assert mode in ['dynamic', 'static'], "mode should be 'dynamic', 'static'"
    if mode == 'dynamic':
        if has_shared_expert:
            dynamic_routing_function = supa_fused_shared_router_prefill_v2_infer
        else:
            assert not use_grouped_topk, "Only support no shared expert when not using grouped topk"
            dynamic_routing_function = supa_moe_router_v2_infer
        return dynamic_routing_function
    else:
        try:
            if use_grouped_topk:
                assert has_shared_expert, "Only support shared expert when using grouped topk"
                static_routing_function = supa_fused_shared_router_v1_v2_infer
            else:
                assert not has_shared_expert, "Only support no shared expert when not using grouped topk"
                static_routing_function = supa_moe_router_decoder_infer
        except AssertionError as e:
            # currently not all models need both dynamic and static routing functions
            logger.info(
                f"Unsupported routing configuration: {e}")  # noqa: G004
            static_routing_function = None
        if act_mode == "act_swiglu_oai":
            static_routing_function = None
            logger.info(
                f"Activation mode {act_mode} does not support static routing, fallback to dynamic routing"  # noqa: G004
            )
        return static_routing_function


@patch_to(UnquantizedFusedMoEMethod)
def apply_monolithic(
    self,
    layer: "FusedMoE",  # type: ignore[name-defined] # noqa: F821
    x: torch.Tensor,
    router_logits: torch.Tensor,
) -> torch.Tensor | tuple[torch.Tensor, torch.Tensor]:
    """Monolithic forward for UnquantizedFusedMoEMethod on SUPA.

    Handles routing internally. ``router_logits`` is either a plain
    tensor or a tuple ``(gate, shared_gate_up, shared_down)`` for MoE
    models with shared experts (e.g. DeepSeek, Qwen3-MoE).
    """
    top_k = layer.top_k
    renormalize = layer.renormalize
    use_grouped_topk = layer.use_grouped_topk
    # global_num_experts=layer.global_num_experts
    # expert_map=layer.expert_map
    topk_group = layer.topk_group
    num_expert_group = layer.num_expert_group
    custom_routing_function = layer.custom_routing_function
    scoring_func = layer.scoring_func
    e_score_correction_bias = layer.e_score_correction_bias
    activation = layer.activation
    if activation == "silu":
        act_mode = "act_swiglu"
    elif activation == "swigluoai":
        act_mode = "act_swiglu_oai"
    else:
        raise ValueError(f"Unsupported activation mode: {activation}")
    b_seq = x.shape[0]

    if isinstance(router_logits, torch.Tensor):
        gating_weight = router_logits
        shared_gate_up_weight = None
        shared_down_weight = None
        static_routing_function = get_custom_routing_function(
            use_grouped_topk,
            has_shared_expert=False,
            mode='static',
            act_mode=act_mode)
        dynamic_routing_function = get_custom_routing_function(
            use_grouped_topk, has_shared_expert=False, mode='dynamic')
    else:
        gating_weight, shared_gate_up_weight, shared_down_weight = router_logits
        static_routing_function = get_custom_routing_function(
            use_grouped_topk,
            has_shared_expert=True,
            mode='static',
            act_mode=act_mode)
        dynamic_routing_function = get_custom_routing_function(
            use_grouped_topk, has_shared_expert=True, mode='dynamic')

    if static_routing_function is not None and b_seq <= envs.VLLM_BR_STATIC_MOE_DECODER_MAX_LEN:
        return fused_moe_static(
            layer=layer,
            hidden_states=x,
            gating_weight=gating_weight,
            shared_expert_weights=(shared_gate_up_weight, shared_down_weight),
            custom_routing_function=static_routing_function,
            act_mode=act_mode)
    else:
        return fused_moe_dynamic(
            layer=layer,
            hidden_states=x,
            gating_weight=gating_weight,
            shared_expert_weights=(shared_gate_up_weight, shared_down_weight),
            custom_routing_function=dynamic_routing_function,
            act_mode=act_mode)


@patch_to(UnquantizedFusedMoEMethod)
def _select_monolithic(self) -> Callable:
    """Select the monolithic implementation based on platform."""
    if current_platform.is_cpu():
        return self.forward_monolithic_cpu
    else:
        return self.apply_monolithic


@patch_to(UnquantizedFusedMoEMethod)
def create_weights(self, layer: torch.nn.Module, num_experts: int,
                   hidden_size: int, intermediate_size_per_partition: int,
                   params_dtype: torch.dtype, **extra_weight_attrs):
    # Fused gate_up_proj (column parallel)
    w13_weight = torch.nn.Parameter(torch.empty(
        num_experts,
        2 * intermediate_size_per_partition,
        hidden_size,
        device="cpu",
        dtype=params_dtype),
                                    requires_grad=False)
    layer.register_parameter("w13_weight", w13_weight)
    set_weight_attrs(w13_weight, extra_weight_attrs)

    if self.moe.has_bias:
        w13_bias = torch.nn.Parameter(torch.zeros(
            num_experts,
            2 * intermediate_size_per_partition,
            device="cpu",
            dtype=params_dtype),
                                      requires_grad=False)
        layer.register_parameter("w13_bias", w13_bias)
        set_weight_attrs(w13_bias, extra_weight_attrs)

    # down_proj (row parallel)
    w2_weight = torch.nn.Parameter(torch.empty(num_experts,
                                               hidden_size,
                                               intermediate_size_per_partition,
                                               device="cpu",
                                               dtype=params_dtype),
                                   requires_grad=False)
    layer.register_parameter("w2_weight", w2_weight)
    set_weight_attrs(w2_weight, extra_weight_attrs)

    if self.moe.has_bias:
        w2_bias = torch.nn.Parameter(torch.zeros(num_experts,
                                                 hidden_size,
                                                 device="cpu",
                                                 dtype=params_dtype),
                                     requires_grad=False)
        layer.register_parameter("w2_bias", w2_bias)
        set_weight_attrs(w2_bias, extra_weight_attrs)


@patch_to(UnquantizedFusedMoEMethod)
def process_weights_after_loading(self: UnquantizedFusedMoEMethod,
                                  layer: FusedMoE) -> None:
    cur_device = torch.supa.current_device()
    die_spc_num = envs.VLLM_BR_DEVICE_SPC_NUM
    die_num = 1 if die_spc_num <= 16 else 2
    spc_num = die_spc_num // die_num
    align_size = 32 if layer.activation == "swigluoai" and spc_num != 12 else 64
    is_dual_die = (die_spc_num > 16)

    # NOTE: w13_weight
    # after _load_w13, w13_weight is a colparallel weight, shape
    # [num_experts, 2 * intermediate_size_per_partition, hidden_size]
    # for SUPA, transform it to a NUMA colmajor weight, shape
    # [spc_num * num_experts, wk, wn_block] (wn = aligned(2 * intermediate_size_per_partition, align_size=64))
    wk = layer.hidden_size
    wn_block = align_n((layer.intermediate_size_per_partition * 2) // die_num,
                       align_size=align_size,
                       spc_num=spc_num)

    supa_w13_weight = torch_br._empty_ut_only(
        size=(die_spc_num * layer.local_num_experts, wk, wn_block),
        dtype=torch.bfloat16,
        is_numa=True,
        device=cur_device,
        tensor_type="colmajor",
        axis=0,
        sbp="SS" if is_dual_die else None)

    for expert_id in range(layer.local_num_experts):
        expert_w13 = layer.w13_weight[expert_id].transpose(0, 1).contiguous()
        # swigluoai activation, no need do interweave
        if layer.activation and layer.activation == "swigluoai":
            pad_expert_w13 = _convert_to_numa_tensor(expert_w13, align_size,
                                                     'COLMAJOR',
                                                     expert_w13.dtype)
            pad_expert_w13_shape = pad_expert_w13.shape
            hw_size = pad_expert_w13_shape[-2] * pad_expert_w13_shape[-1]
            narrow_data = supa_w13_weight.view_as_usharp(
                "COLMAJOR", pad_expert_w13_shape, Sbp.ss(0),
                expert_id * hw_size)
            narrow_data.copy_(pad_expert_w13)
        else:
            expert_1, expert_3 = expert_w13.chunk(2, dim=1)
            pad_expert_w13 = _convert_to_crossed_numa_tensor(expert_1,
                                                             expert_3,
                                                             die_spc_num,
                                                             dim=1,
                                                             need_pad=True,
                                                             layout='COLMAJOR')
            hw_size = pad_expert_w13.shape[-2] * pad_expert_w13.shape[-1]
            narrow_data = supa_w13_weight.view_as_usharp(
                "COLMAJOR", pad_expert_w13.shape, Sbp.ss(0),
                expert_id * hw_size)
            narrow_data.copy_(pad_expert_w13)

    layer.w13_weight.data = supa_w13_weight

    # NOTE: w13_bias
    if hasattr(layer, "w13_bias") and layer.w13_bias is not None:
        wn = layer.intermediate_size_per_partition * 2
        supa_w13_bias = torch_br._empty_ut_only(
            size=(layer.local_num_experts, wn),
            dtype=torch.float32,
            is_numa=False,
            device=cur_device,
            tensor_type="linear_bias",
            sbp="BB" if is_dual_die else None)
        for expert_id in range(layer.local_num_experts):
            expert_w13_bias = layer.w13_bias[expert_id]
            # swigluoai activation, no need do interweave
            if layer.activation and layer.activation == "swigluoai":
                narrow_data = supa_w13_bias[expert_id]
                narrow_data.copy_(expert_w13_bias)
            else:
                expert_1_bias, expert_3_bias = expert_w13_bias.chunk(2, dim=-1)
                crossed_expert_w13_bias = cross_weight_32(
                    expert_1_bias,
                    expert_3_bias,
                    die_spc_num,
                    dim=0,
                    need_pad=False,
                )
                narrow_data = supa_w13_bias[expert_id]
                narrow_data.copy_(crossed_expert_w13_bias)
        layer.w13_bias.data = supa_w13_bias

    # NOTE: w2_weight
    # after _load_w2, w2_weight is a rowparallel weight, shape
    # [num_experts, hidden_size, intermediate_size_per_partition]
    # for SUPA, transform it to a NUMA colmajor weight, shape
    # [spc_num * num_experts, wk, wn_block]
    align_size = 32
    wk = layer.intermediate_size_per_partition
    wn_block = align_n(layer.hidden_size,
                       align_size=align_size,
                       spc_num=spc_num)

    supa_w2_weight = torch_br._empty_ut_only(
        size=(die_spc_num * layer.local_num_experts, wk // die_num, wn_block),
        dtype=torch.bfloat16,
        is_numa=True,
        device=cur_device,
        tensor_type="colmajor",
        axis=0,
        sbp="SS" if is_dual_die else None)

    for expert_id in range(layer.local_num_experts):
        expert_w2 = layer.w2_weight[expert_id].transpose(0, 1).contiguous()
        pad_expert_w2 = _convert_to_numa_tensor(expert_w2,
                                                align_size,
                                                'COLMAJOR',
                                                expert_w2.dtype,
                                                parallel_type="row_parallel")
        pad_expert_w2_shape = pad_expert_w2.shape
        hw_size = pad_expert_w2_shape[-2] * pad_expert_w2_shape[-1]
        narrow_data = supa_w2_weight.view_as_usharp("COLMAJOR",
                                                    pad_expert_w2_shape,
                                                    Sbp.ss(0),
                                                    expert_id * hw_size)
        narrow_data.copy_(pad_expert_w2)

    layer.w2_weight.data = supa_w2_weight

    # NOTE: w2_bias
    if hasattr(layer, "w2_bias") and layer.w2_bias is not None:
        wn = layer.hidden_size
        supa_w2_bias = torch.zeros((layer.local_num_experts, wn),
                                   dtype=torch.float32,
                                   device=cur_device)
        for expert_id in range(layer.local_num_experts):
            expert_w2 = layer.w2_bias[expert_id]
            narrow_data = supa_w2_bias[expert_id]
            narrow_data.copy_(expert_w2)

        layer.w2_bias.data = supa_w2_bias


@patch_to(FusedMoE)
def forward(self: FusedMoE, hidden_states: torch.Tensor,
            router_logits: torch.Tensor):
    assert self.quant_method is not None
    assert self.dp_size == 1, 'dp_size > 1 is not supported for now, please refer v0.11.0 moe codes'

    if self.quant_method.is_monolithic:
        final_hidden_states = self.quant_method.apply_monolithic(
            self, hidden_states, router_logits)
    else:
        topk_weights, topk_ids = self.router.select_experts(
            hidden_states=hidden_states,
            router_logits=router_logits,
        )
        final_hidden_states = self.quant_method.apply(
            layer=self,
            x=hidden_states,
            topk_weights=topk_weights,
            topk_ids=topk_ids,
        )

    # NOTE: if using supa-moe-ccl kernel, add property `all_reduced` to the final_hidden_states
    support_types = ((16, 4), (16, 8), (32, 2), (32, 4), (32, 8), (24, 2), (24, 4))
    parallel_size = self.ep_size if self.use_ep else self.tp_size
    if hidden_states.shape[
            0] <= envs.VLLM_BR_STATIC_MOE_DECODER_MAX_LEN and envs.VLLM_BR_QUANT_METHOD != "INT4" and _isHardwareSupportFusedAllreduce(
            ) and (envs.VLLM_BR_DEVICE_SPC_NUM, parallel_size) in support_types and envs.VLLM_BR_USE_FUSED_MOE_COMM_COMPUTE:
        final_hidden_states.all_reduced = True

    return final_hidden_states 


@patch_to(FusedMoE)
def _load_w13(self, expert_data: torch.Tensor, shard_dim: int, shard_id: str,
              loaded_weight: torch.Tensor, tp_rank: int):

    # Index the loaded weight for tp sharding.
    # gate_up_proj: "MergedColumnParallel", so tp sharding on output_dim
    shard_size = expert_data.shape[shard_dim] // 2
    # Clamp shard_dim to loaded_weight's actual ndim.
    # Per-channel scales are 1D (shape=(intermediate_size,)) but shard_dim
    # may be 1 (flipped by is_transposed=True). Use dim 0 for such tensors.
    lw_shard_dim = min(shard_dim, loaded_weight.ndim - 1)
    loaded_weight = loaded_weight.narrow(lw_shard_dim, shard_size * tp_rank,
                                         shard_size)
    # Narrow parameter and load.
    # w1, gate_proj: Load into first logical weight of w13.
    if shard_id == "w1":
        expert_data = expert_data.narrow(shard_dim, 0, shard_size)
    # w3, up_proj: Load into second logical weight of w13.
    else:
        assert shard_id == "w3"
        expert_data = expert_data.narrow(shard_dim, shard_size, shard_size)
    expert_data.copy_(loaded_weight.reshape(expert_data.shape).cpu())


@patch_to(FusedMoE)
def _load_w2(self,
             expert_data: torch.Tensor,
             shard_dim: int,
             loaded_weight: torch.Tensor,
             tp_rank: int,
             load_full: bool = False):

    # Index the loaded weight for tp sharding.
    # down_proj: "RowParallel" so tp sharding on input_dim
    # Narrow parameter and load.
    shard_size = expert_data.shape[shard_dim]
    if not load_full:
        loaded_weight = loaded_weight.narrow(shard_dim, shard_size * tp_rank,
                                             shard_size)
    # w2, down_proj: Load into only logical weight of w2.
    expert_data.copy_(loaded_weight.cpu())


def wrapper_FusedMoE_init(fn):

    @wraps(fn)
    def wrapper(self, *args, **kwargs):
        self.swiglu_limit = None
        self.swiglu_limit_shared = None
        if 'swiglu_limit' in kwargs:
            swiglu_limit = kwargs.pop('swiglu_limit')
            if isinstance(swiglu_limit, tuple):
                self.swiglu_limit, self.swiglu_limit_shared = swiglu_limit
            else:
                self.swiglu_limit = swiglu_limit

        _origin_scoring_func = kwargs.pop('scoring_func', 'softmax')

        fn(self, *args, **kwargs)

        self.scoring_func = _origin_scoring_func
        if self.e_score_correction_bias is not None:
            self.e_score_correction_bias.data = self.e_score_correction_bias.float(
            )
            
        tp_size = get_tensor_model_parallel_world_size()
        cur_device = torch.supa.current_device()
        spc_num = torch_br.supa.get_device_properties(
            cur_device).max_compute_units
            
        if _isHardwareSupportFusedAllreduce(
        ) and tp_size == 8 and (spc_num == 16 or spc_num == 32):
            # Initialize the p2p info
            torch.supa.init_p2p_remote_id(cur_device)

    return wrapper


FusedMoE.__init__ = wrapper_FusedMoE_init(FusedMoE.__init__)  # noqa: E501

UnquantizedFusedMoEMethod.is_monolithic = property(lambda self: True)

# When VLLM_BR_ENABLE_PCP_LOCAL_EP=1, EP groups are PCP-local (no
# cross-PCP communication).  Override flatten_tp_across_dp_and_pcp so
# that pcp_size is NOT folded into the effective EP size.
_orig_flatten_tp = FusedMoEParallelConfig.flatten_tp_across_dp_and_pcp


@staticmethod  # type: ignore[misc]
def _pcp_local_flatten_tp(
    tp_size: int,
    dp_size: int,
    dp_rank: int,
    pcp_size: int,
    pcp_rank: int,
) -> tuple[int, int]:
    if envs.VLLM_BR_ENABLE_PCP_LOCAL_EP and pcp_size > 1:
        tp_rank = (
            0 if tp_size == 1
            else get_tensor_model_parallel_rank()
        )
        flatten_tp_size = dp_size * tp_size
        flatten_tp_rank = dp_rank * tp_size + tp_rank
        return flatten_tp_size, flatten_tp_rank
    return _orig_flatten_tp(
        tp_size, dp_size, dp_rank, pcp_size, pcp_rank,
    )


FusedMoEParallelConfig.flatten_tp_across_dp_and_pcp = (
    _pcp_local_flatten_tp
)
