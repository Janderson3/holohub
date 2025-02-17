/*
 * SPDX-FileCopyrightText: Copyright (c) 2022 DELTACAST.TV. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "videomaster_source.hpp"

#include "holoscan/core/gxf/entity.hpp"
#include "holoscan/core/operator_spec.hpp"

#include "holoscan/core/resources/gxf/allocator.hpp"
#include "holoscan/core/resources/gxf/cuda_stream_pool.hpp"

namespace holoscan::ops {

void VideoMasterSourceOp::setup(OperatorSpec& spec) {
  auto& signal = spec.output<gxf::Entity>("signal");

  spec.param(_signal, "signal", "Output", "Output signal.", &signal);
  spec.param(_use_rdma, "use_rdma", "Use RDMA", "Specifies whether RDMA should be used.", false);
  spec.param(_board_index, "board", "Board", "Index of the Deltacast.TV board to use.", 0u);
  spec.param(_channel_index, "input", "Input", "Index of the input channel to use.", 0u);
  spec.param(_pool, "pool", "Pool", "Pool to allocate the buffers.");
}

}  // namespace holoscan::ops
