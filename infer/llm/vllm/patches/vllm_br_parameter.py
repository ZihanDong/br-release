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

import torch
from fastcore.basics import patch_to

from vllm.model_executor.parameter import (PackedColumnParameter,
                                           PackedvLLMParameter,
                                           _ColumnvLLMParameter)
from vllm_br import envs


@patch_to(_ColumnvLLMParameter)
def _assert_and_load(self, loaded_weight: torch.Tensor):
    # Scale tensors are stored 1D ([N]) in checkpoints but allocated as 2D
    # ([N, 1]) by vllm's WNA16 scheme. Reshape to match before copy so that
    # load_row_parallel_weight / load_column_parallel_weight don't assert-fail.
    if loaded_weight.shape != self.data.shape and \
            loaded_weight.numel() == self.data.numel():
        loaded_weight = loaded_weight.reshape(self.data.shape)
    assert self.data.shape == loaded_weight.shape or \
        self._is_1d_and_scalar(loaded_weight)
    self.data.copy_(loaded_weight)


@patch_to(_ColumnvLLMParameter)
def load_qkv_weight(self, loaded_weight: torch.Tensor, **kwargs):

    shard_offset = kwargs.get("shard_offset")
    shard_size = kwargs.get("shard_size")
    shard_id = kwargs.get("shard_id")
    num_heads = kwargs.get("num_heads")

    # TODO: move these to PackedColumnParameter and PackedvLLMParameter
    if isinstance(
            self,
        (PackedColumnParameter,
         PackedvLLMParameter)) and self.output_dim == self.packed_dim:
        shard_size, shard_offset = self.adjust_shard_indexes_for_packing(
            shard_offset=shard_offset, shard_size=shard_size)

    param_data = self.data
    shard_id = (self.tp_rank if shard_id == "q" else self.tp_rank // num_heads)
    loaded_weight = loaded_weight.narrow(self.output_dim,
                                         shard_id * shard_size, shard_size)

    if envs.VLLM_BR_DEVICE_SPC_NUM > 16:
        assert isinstance(shard_size,
                          int), "failed to check shard_size type is int"
        assert isinstance(shard_offset,
                          int), "failed to check shard_offset type is int"
        half_w = param_data.shape[self.output_dim] // 2
        half_shard_size = shard_size // 2
        half_shard_offset = shard_offset // 2
        param_data_0 = param_data.narrow(self.output_dim, half_shard_offset,
                                         half_shard_size)
        param_data_1 = param_data.narrow(self.output_dim,
                                         half_shard_offset + half_w,
                                         half_shard_size)
        # Per-channel scales are 1D in the checkpoint ([N]) but the parameter
        # buffer is 2D ([N, 1]).  Reshape before copy so .copy_() does not
        # mis-broadcast and raise a shape error.
        lw_half0 = loaded_weight.narrow(self.output_dim, 0, half_shard_size)
        lw_half1 = loaded_weight.narrow(self.output_dim, half_shard_size,
                                        half_shard_size)
        param_data_0.copy_(lw_half0.reshape(param_data_0.shape))
        param_data_1.copy_(lw_half1.reshape(param_data_1.shape))
    else:
        param_data = param_data.narrow(self.output_dim, shard_offset,
                                       shard_size)
        param_data.copy_(loaded_weight.reshape(param_data.shape))
