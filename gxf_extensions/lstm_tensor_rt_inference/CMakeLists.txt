# SPDX-FileCopyrightText: Copyright (c) 2022-2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
cmake_minimum_required(VERSION 3.20)
project(gxf_lstm_tensor_rt_inference)

find_package(holoscan REQUIRED CONFIG
             PATHS "/opt/nvidia/holoscan" "/workspace/holoscan-sdk/install")

             # Create library
add_library(gxf_lstm_tensor_rt_inference_lib SHARED
  tensor_rt_inference.cpp
  tensor_rt_inference.hpp
)

set_target_properties(gxf_lstm_tensor_rt_inference_lib PROPERTIES CXX_STANDARD 17)

target_link_libraries(gxf_lstm_tensor_rt_inference_lib
  PUBLIC
    CUDA::cudart
    GXF::cuda
    GXF::std
    nvonnxparser
    yaml-cpp
)

# Create extension
add_library(gxf_lstm_tensor_rt_inference SHARED
  lstm_tensor_rt_extension.cpp
)
target_link_libraries(gxf_lstm_tensor_rt_inference
  PUBLIC gxf_lstm_tensor_rt_inference_lib
)
