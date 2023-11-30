#include <iostream>
#include <cassert>
#include <vector>
#include <utility>
#include <stdlib.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <mma.h>
#include <cuda/barrier>
#include <cooperative_groups.h>
#include <cooperative_groups/memcpy_async.h>

#include <ATen/ATen.h>
#include <ATen/Context.h>
#include <ATen/Dispatch.h>
#include <ATen/cuda/Atomic.cuh>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAStream.h>

#include <torch/types.h>
#include <torch/extension.h>

using namespace torch::indexing;
using namespace nvcuda;
namespace cg = cooperative_groups;

#define FULL_MASK 0xffffffff
#define HALF_MASK 0x0000ffff

#define CHECK_CUDA(x)           TORCH_CHECK(x.is_cuda(), #x " must be a CUDA tensor")
#define CHECK_CONTIGUOUS(x)     TORCH_CHECK(x.is_contiguous(), #x " must be contiguous")
#define CHECK_INPUT(x) 	        do { CHECK_CUDA(x); CHECK_CONTIGUOUS(x); } while(false)
#define gpuErrchk(ans)          do { gpuAssert((ans), __FILE__, __LINE__); } while (false)


__host__ static inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
    if (code != cudaSuccess)
    {
        fprintf(stderr, "GPUassert[%s:%d]: %s\n", file, line, cudaGetErrorString(code));
        if (abort) exit(code);
    }
}

#define BLOCK_SIZE 512
#define WARP_SIZE 32


__device__ static inline uint64_t decode8weights(
    uint16_t weight_compressed,
    const int64_t *__restrict__ codebook_abs
) {

    bool bit_shift = !(weight_compressed & 1);
    uint8_t bits_sign = (weight_compressed >> 1) & ((1 << 7) - 1);
    uint8_t bits_abs = (weight_compressed >> 8) & ((1 << 9) - 1);

    int64_t packed = codebook_abs[bits_abs];

    // TODO: optimize this by redefining the bit pattern
    bool parity = __popcll(packed & 0x0404040404040404) % 2 == 0;
    uint64_t decoded_sign = __brev(bits_sign | (((__popc(bits_sign) & 1) == parity) << 7)) >> 24;
    decoded_sign |= (decoded_sign << (32-4));
    decoded_sign |= (decoded_sign << (16-2));
    decoded_sign |= (decoded_sign << (8-1));
    decoded_sign &= 0x0101010101010101;
    decoded_sign *= 255 - 3;
    packed ^= decoded_sign;

    packed -= bit_shift * 0x0202020202020202;
    packed |= 0x0101010101010101;

    return packed;
}


/*
llama 2 70B:
M N K
1 8192 8192
1 57344 8192
1 8192 28672
1 10240 8192
*/
template <typename scalar_t>
__global__ static void
__launch_bounds__(BLOCK_SIZE)
decode_matmul_e8p_kernel(
    scalar_t *__restrict__ output,
    const scalar_t *__restrict__ x,
    const int16_t *__restrict__ weights_compressed,
    const int64_t *__restrict__ codebook_abs,
    int64_t M,
    int64_t N,
    int64_t K
) {
    auto block = cooperative_groups::this_thread_block();
    cg::thread_block_tile<32> tile32 = cooperative_groups::tiled_partition<32>(block);
    __shared__ int64_t codebook_local[256];
    if (threadIdx.x < 256) {
    codebook_local[threadIdx.x] = codebook_abs[threadIdx.x];
    }
    __syncthreads();

    int64_t warpId = threadIdx.x / WARP_SIZE;
    int64_t laneId = threadIdx.x % WARP_SIZE;

    // each thread adds 8 activation-weight products
    const int64_t unroll_k = 2;
    const int64_t pack = 8;
    const int64_t elem_per_thread = pack * unroll_k;
    int64_t warps_per_elem = K / WARP_SIZE / elem_per_thread;
    const int64_t unroll_n = 16;
    const int64_t local_k = 1; // in terms of warp size. 32 threads of elem_per_thread fma each, dont set below 1 because of __shfl_down_sync
    int64_t local_n = BLOCK_SIZE / WARP_SIZE / local_k;
    int64_t grid_N = N / unroll_n;

    __shared__ scalar_t accum_scratch[BLOCK_SIZE / WARP_SIZE];
    bool SHARED_REDUCE = false;

    for (int64_t warpPos = blockIdx.x * BLOCK_SIZE/WARP_SIZE + warpId;
            warpPos < M * grid_N * warps_per_elem;
            warpPos += gridDim.x * BLOCK_SIZE/WARP_SIZE) {

        int64_t local_n_i = (warpPos% (BLOCK_SIZE / WARP_SIZE)) / local_k;
        int64_t local_k_i = (warpPos% (BLOCK_SIZE / WARP_SIZE)) % local_k;
        int64_t m = (warpPos / warps_per_elem) / (grid_N);
        int64_t k_ = warpPos % (warps_per_elem * local_n);
        int64_t k = k_ / (local_k * local_n) * local_k + k_ % local_k;

        scalar_t this_activations[elem_per_thread];
#pragma unroll
        for (int64_t unroll_k_i = 0; unroll_k_i < unroll_k; unroll_k_i++) {
            const scalar_t *activations = x + m * K + (k * WARP_SIZE + laneId) * elem_per_thread + unroll_k_i * pack;
            if constexpr (std::is_same<scalar_t, float>::value) {
                const float4 *first_half = reinterpret_cast<const float4 *>(activations);
                __builtin_assume_aligned(first_half, 16);
                this_activations[unroll_k_i * pack + 0] = first_half->x;
                this_activations[unroll_k_i * pack + 1] = first_half->y;
                this_activations[unroll_k_i * pack + 2] = first_half->z;
                this_activations[unroll_k_i * pack + 3] = first_half->w;
                const float4 *second_half = reinterpret_cast<const float4 *>(activations + 4);
                __builtin_assume_aligned(second_half, 16);
                this_activations[unroll_k_i * pack + 4] = second_half->x;
                this_activations[unroll_k_i * pack + 5] = second_half->y;
                this_activations[unroll_k_i * pack + 6] = second_half->z;
                this_activations[unroll_k_i * pack + 7] = second_half->w;
            } else {
                for (int64_t activation_i = 0; activation_i < pack; activation_i++) {
                    this_activations[unroll_k_i * pack + activation_i] = activations[activation_i];
                }
            }
        }
        __shared__ int16_t loaded_weights[unroll_k * BLOCK_SIZE];
        for (int64_t unroll_n_i = 0; unroll_n_i < unroll_n; unroll_n_i++) {
            scalar_t accumulator = 0;
            int64_t n = ((warpPos/local_k) % local_n) + ((warpPos / warps_per_elem) % grid_N) / local_n * local_n;
            __syncwarp();
            uint16_t this_weights[unroll_k];
            if (false) {
                cg::memcpy_async(tile32, loaded_weights + unroll_k * warpId * WARP_SIZE, &weights_compressed[(n*unroll_n + unroll_n_i) * K/pack + (k * WARP_SIZE) * unroll_k], unroll_k * WARP_SIZE * sizeof(uint16_t));
                cg::wait(tile32);
#pragma unroll
                for (int64_t unroll_k_i = 0; unroll_k_i < unroll_k; unroll_k_i++) {
                    this_weights[unroll_k_i] = loaded_weights[unroll_k * warpId * WARP_SIZE + laneId * unroll_k + unroll_k_i];
                }
            } else if (unroll_k % 2 == 0) {
                for (int64_t unroll_k_i = 0; unroll_k_i < unroll_k; unroll_k_i+=2) {
                    const ushort2 *loaded = (const ushort2 *) &weights_compressed[(n*unroll_n + unroll_n_i) * K/pack + (k * WARP_SIZE + laneId) * unroll_k + unroll_k_i];
                    __builtin_assume_aligned(loaded, 4);
                    this_weights[unroll_k_i] = loaded->x;
                    this_weights[unroll_k_i + 1] = loaded->y;
                }
            } else {
                for (int64_t unroll_k_i = 0; unroll_k_i < unroll_k; unroll_k_i++) {
                    this_weights[unroll_k_i] = weights_compressed[(n*unroll_n + unroll_n_i) * K/pack + (k * WARP_SIZE + laneId) * unroll_k + unroll_k_i];
                }
            }

#pragma unroll
            for (int64_t unroll_k_i = 0; unroll_k_i < unroll_k; unroll_k_i++) {
                // TODO: optimize access pattern by reordering weights
                uint16_t encoded = this_weights[unroll_k_i];
                uint64_t decoded = decode8weights(encoded, codebook_local);

#pragma unroll
                for (int64_t i = 0; i < 8; i += 1) {
                    int8_t weight = decoded >> (i * 8);
                    accumulator += this_activations[unroll_k_i * pack + i] * (int8_t) weight;
                }
            }
            accumulator *= 0.25;

            for (int offset = WARP_SIZE/2; offset > 0; offset /= 2) {
                // apparently c10::Half does arithmetic operations in float32?
                // https://github.com/pytorch/pytorch/blob/0bd4d1f4ab38d3088de8aa5fbba35427b42d118e/c10/util/Half.h#L4C58-L6C80
                if constexpr (std::is_same<scalar_t, c10::Half>::value) {
                    accumulator += __shfl_down_sync(0xFFFFFFFF, __float2half(accumulator), offset);
                } else {
                    accumulator += __shfl_down_sync(0xFFFFFFFF, accumulator, offset);
                }
            }

            if (SHARED_REDUCE) {
                if (laneId == 0) {
                    accum_scratch[warpId] = accumulator;
                    __syncthreads();
                    if (warpId % local_k == 0) {
                        scalar_t local_accum = 0;
                        for (int64_t accum_i = 0; accum_i < local_k; accum_i++) {
                            local_accum += accum_scratch[warpId / local_k * local_k + accum_i];
                        }
                        atomicAdd(output + m * N + n * unroll_n + unroll_n_i, local_accum);
                    }
                } else {
                    __syncthreads();
                }
            } else {
                if (laneId == 0) {
                    atomicAdd(output + m * N + n * unroll_n + unroll_n_i, accumulator);
                }
            }
        }
    }
}


__host__ extern torch::Tensor decode_matmul_e8p(
    torch::Tensor x,
    torch::Tensor weights_compressed,
    torch::Tensor codebook_abs
) {

    CHECK_INPUT(x);
    CHECK_INPUT(weights_compressed);
    CHECK_INPUT(codebook_abs);

    TORCH_CHECK(weights_compressed.scalar_type() == torch::kInt16);
    TORCH_CHECK(codebook_abs.scalar_type() == torch::kInt64);
    TORCH_CHECK(x.size(-1) == weights_compressed.size(-1) << 3);
    TORCH_CHECK(codebook_abs.size(-1) == 256);

    int64_t M = x.size(-2);
    int64_t N = weights_compressed.size(-2);
    int64_t K = x.size(-1);
    //printf("%lld %lld %lld\n", M, N, K);

    TORCH_CHECK(K % WARP_SIZE == 0, "K is not divisible by WARP_SIZE");

    at::DeviceGuard guard(x.device());
    torch::TensorOptions options = torch::TensorOptions()
        .dtype(x.scalar_type())
        .layout(torch::kStrided)
        .device(torch::kCUDA)
        .requires_grad(false);
    torch::Tensor output = torch::zeros(std::vector<int64_t>{M, N}, options);

    cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, x.get_device());
    int64_t grid_size = static_cast<int64_t>(6 * deviceProp.multiProcessorCount);
    at::cuda::CUDAStream stream = at::cuda::getCurrentCUDAStream();

    AT_DISPATCH_FLOATING_TYPES_AND2(
            at::ScalarType::Half,
            at::ScalarType::BFloat16,
            x.scalar_type(),
            "decode_matmul_e8p",
            [&] {
        decode_matmul_e8p_kernel<<<grid_size, BLOCK_SIZE, 0, stream>>>(
                output.data_ptr<scalar_t>(),
                x.data_ptr<scalar_t>(),
                weights_compressed.data_ptr<int16_t>(),
                codebook_abs.data_ptr<int64_t>(),
                M,
                N,
                K);
        gpuErrchk(cudaPeekAtLastError());
    });

    return output;
}
