#include "ntt.cuh"
#include "butterfly.cuh"

// use in key switching mod up
__global__ static void
inplace_fnwt_radix8_phase1_single_mod_mod_up_fuse(uint64_t *out,
                                                  const uint64_t *in,
                                                  const DMulUIntMod *twiddles,
                                                  const DModulus *modulus,
                                                  size_t coeff_mod_size,
                                                  size_t start_mod_idx,
                                                  size_t n,
                                                  size_t n1,
                                                  size_t pad,
                                                  size_t mod_idx) {
    extern __shared__ uint64_t buffer[];

    for (size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
         tid < n / 8 * coeff_mod_size;
         tid += blockDim.x * gridDim.x) {
        // pad address
        size_t pad_tid = threadIdx.x % pad;
        size_t pad_idx = threadIdx.x / pad;

        size_t group = n1 / 8;
        // size of a block
        uint64_t samples[8];
        size_t t = n / 2;
        // modulus idx
        size_t twr_idx = tid / (n / 8) + start_mod_idx;
        // index in n/8 range (in each tower)
        size_t n_idx = tid % (n / 8);
        const DMulUIntMod *psi = twiddles + mod_idx * n;
        uint64_t mod_value = modulus[mod_idx].value();
        uint64_t barrett_mu_hi = modulus[twr_idx].const_ratio()[1];
        size_t n_init = t / 4 / group * pad_idx + pad_tid + pad * (n_idx / (group * pad));

        // base address
        size_t indata_offset = twr_idx * n;
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            samples[j] = in[indata_offset + n_init + t / 4 * j];
//            samples[j] = barrett_reduce_uint64_uint64(samples[j], mod_value, barrett_mu_hi);
        }

        size_t tw_idx = 1;

        fntt8(samples, psi, tw_idx, mod_value);
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            buffer[pad_tid * (n1 + pad) + pad_idx + group * j] = samples[j];
        }
        size_t remain_iters = 0;
        __syncthreads();
#pragma unroll
        for (size_t j = 8, k = group / 2; j < group + 1; j *= 8, k >>= 3) {
            size_t m_idx2 = pad_idx / (k / 4);
            size_t t_idx2 = pad_idx % (k / 4);
#pragma unroll
            for (size_t l = 0; l < 8; l++) {
                samples[l] = buffer[(n1 + pad) * pad_tid + 2 * m_idx2 * k + t_idx2 + (k / 4) * l];
            }
            size_t tw_idx2 = j * tw_idx + m_idx2;
            fntt8(samples, psi, tw_idx2, mod_value);
#pragma unroll
            for (size_t l = 0; l < 8; l++) {
                buffer[(n1 + pad) * pad_tid + 2 * m_idx2 * k + t_idx2 + (k / 4) * l] = samples[l];
            }
            if (j == group / 2)
                remain_iters = 1;
            if (j == group / 4)
                remain_iters = 2;

            __syncthreads();
        }

        if (group < 8)
            remain_iters = (group == 4) ? 2 : 1;
#pragma unroll
        for (size_t l = 0; l < 8; l++) {
            samples[l] = buffer[(n1 + pad) * pad_tid + 8 * pad_idx + l];
        }
        if (remain_iters == 1) {
            size_t tw_idx2 = 4 * group * tw_idx + 4 * pad_idx;
            ct_butterfly(samples[0], samples[1], psi[tw_idx2], mod_value);
            ct_butterfly(samples[2], samples[3], psi[tw_idx2 + 1], mod_value);
            ct_butterfly(samples[4], samples[5], psi[tw_idx2 + 2], mod_value);
            ct_butterfly(samples[6], samples[7], psi[tw_idx2 + 3], mod_value);
        } else if (remain_iters == 2) {
            size_t tw_idx2 = 2 * group * tw_idx + 2 * pad_idx;
            fntt4(samples, psi, tw_idx2, mod_value);
            fntt4(samples + 4, psi, tw_idx2 + 1, mod_value);
        }
#pragma unroll
        for (size_t l = 0; l < 8; l++) {
            buffer[(n1 + pad) * pad_tid + 8 * pad_idx + l] = samples[l];
        }

        __syncthreads();
        // base address
        uint64_t *data_ptr = out + twr_idx * n;
        for (size_t j = 0; j < 8; j++) {
            *(data_ptr + n_init + t / 4 * j) = buffer[pad_tid * (n1 + pad) + pad_idx + group * j];
        }
    }
}

__global__ static void
inplace_fnwt_radix8_phase2_single_mod(uint64_t *inout,
                                      const DMulUIntMod *twiddles,
                                      const DModulus *modulus,
                                      size_t coeff_mod_size,
                                      size_t start_mod_idx,
                                      size_t n,
                                      size_t n1,
                                      size_t n2,
                                      size_t mod_idx) {
    extern __shared__ uint64_t buffer[];

    for (size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
         tid < (n / 8 * coeff_mod_size);
         tid += blockDim.x * gridDim.x) {
        size_t group = n2 / 8;
        size_t set = threadIdx.x / group;
        // size of a block
        uint64_t samples[8];
        size_t t = n2 / 2;
        // prime idx
        size_t twr_idx = coeff_mod_size - 1 - (tid / (n / 8)) + start_mod_idx;
        // index in n/2 range
        size_t n_idx = tid % (n / 8);
        // tid'th block
        size_t m_idx = n_idx / (t / 4);
        size_t t_idx = n_idx % (t / 4);
        // base address
        uint64_t *data_ptr = inout + twr_idx * n;
        const DModulus *modulus_table = modulus;
        uint64_t modulus = modulus_table[mod_idx].value();
        const DMulUIntMod *psi = twiddles + n * mod_idx;
        size_t n_init = 2 * m_idx * t + t_idx;
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            samples[j] = *(data_ptr + n_init + t / 4 * j);
        }
        size_t tw_idx = n1 + m_idx;
        fntt8(samples, psi, tw_idx, modulus);
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            buffer[set * n2 + t_idx + t / 4 * j] = samples[j];
        }
        size_t tail = 0;

        __syncthreads();

#pragma unroll
        for (size_t j = 8, k = t / 8; j < t / 4 + 1; j *= 8, k >>= 3) {
            size_t m_idx2 = t_idx / (k / 4);
            size_t t_idx2 = t_idx % (k / 4);
#pragma unroll
            for (size_t l = 0; l < 8; l++) {
                samples[l] =
                        buffer[set * n2 + 2 * m_idx2 * k + t_idx2 + (k / 4) * l];
            }
            size_t tw_idx2 = j * tw_idx + m_idx2;
            fntt8(samples, psi, tw_idx2, modulus);
#pragma unroll
            for (size_t l = 0; l < 8; l++) {
                buffer[set * n2 + 2 * m_idx2 * k + t_idx2 + (k / 4) * l] =
                        samples[l];
            }
            if (j == t / 8)
                tail = 1;
            if (j == t / 16)
                tail = 2;

            __syncthreads();
        }

#pragma unroll
        for (size_t l = 0; l < 8; l++) {
            samples[l] = buffer[set * n2 + 8 * t_idx + l];
        }
        if (tail == 1) {
            size_t tw_idx2 = t * tw_idx + 4 * t_idx;
            ct_butterfly(samples[0], samples[1], psi[tw_idx2], modulus);
            ct_butterfly(samples[2], samples[3], psi[tw_idx2 + 1], modulus);
            ct_butterfly(samples[4], samples[5], psi[tw_idx2 + 2], modulus);
            ct_butterfly(samples[6], samples[7], psi[tw_idx2 + 3], modulus);
        } else if (tail == 2) {
            size_t tw_idx2 = (t / 2) * tw_idx + 2 * t_idx;
            fntt4(samples, psi, tw_idx2, modulus);
            fntt4(samples + 4, psi, tw_idx2 + 1, modulus);
        }
#pragma unroll
        for (size_t l = 0; l < 8; l++) {
            buffer[set * n2 + 8 * t_idx + l] = samples[l];
        }
        __syncthreads();

        uint64_t modulus2 = modulus << 1;
        // final reduction
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            samples[j] = buffer[set * n2 + t_idx + t / 4 * j];
            if (samples[j] >= modulus2)
                samples[j] -= modulus2;
            if (samples[j] >= modulus)
                samples[j] -= modulus;
        }
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            *(data_ptr + n_init + t / 4 * j) = samples[j];
        }
    }
}

__global__ static void
inplace_fnwt_radix8_phase1_mod_down_fuse(uint64_t *out,
                                         const uint64_t *in,
                                         const DMulUIntMod *twiddles,
                                         const DModulus *modulus,
                                         const size_t coeff_mod_size,
                                         const size_t start_mod_idx,
                                         const size_t n,
                                         const size_t n1,
                                         const size_t pad) {
    extern __shared__ uint64_t buffer[];

    for (size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
         tid < n / 8 * coeff_mod_size;
         tid += blockDim.x * gridDim.x) {
        // pad address
        size_t pad_tid = threadIdx.x % pad;
        size_t pad_idx = threadIdx.x / pad;

        size_t group = n1 / 8;
        // size of a block
        uint64_t samples[8];
        size_t t = n / 2;
        // modulus idx
        size_t twr_idx = tid / (n / 8) + start_mod_idx;
        // index in n/8 range (in each tower)
        size_t n_idx = tid % (n / 8);
        // base address
        uint64_t *data_ptr = out + twr_idx * n;
        const DMulUIntMod *psi = twiddles + twr_idx * n;
        uint64_t mod_value = modulus[twr_idx].value();
        uint64_t barrett_mu_hi = modulus[twr_idx].const_ratio()[1];
        size_t n_init = t / 4 / group * pad_idx + pad_tid + pad * (n_idx / (group * pad));

#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            samples[j] = in[n_init + t / 4 * j];
            samples[j] = barrett_reduce_uint64_uint64(samples[j], mod_value, barrett_mu_hi);
        }
        size_t tw_idx = 1;
        fntt8(samples, psi, tw_idx, mod_value);
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            buffer[pad_tid * (n1 + pad) + pad_idx + group * j] = samples[j];
        }
        size_t remain_iters = 0;
        __syncthreads();
#pragma unroll
        for (size_t j = 8, k = group / 2; j < group + 1; j *= 8, k >>= 3) {
            size_t m_idx2 = pad_idx / (k / 4);
            size_t t_idx2 = pad_idx % (k / 4);
#pragma unroll
            for (size_t l = 0; l < 8; l++) {
                samples[l] = buffer[(n1 + pad) * pad_tid + 2 * m_idx2 * k + t_idx2 + (k / 4) * l];
            }
            size_t tw_idx2 = j * tw_idx + m_idx2;
            fntt8(samples, psi, tw_idx2, mod_value);
#pragma unroll
            for (size_t l = 0; l < 8; l++) {
                buffer[(n1 + pad) * pad_tid + 2 * m_idx2 * k + t_idx2 + (k / 4) * l] = samples[l];
            }
            if (j == group / 2)
                remain_iters = 1;
            if (j == group / 4)
                remain_iters = 2;
            __syncthreads();
        }

        if (group < 8)
            remain_iters = (group == 4) ? 2 : 1;
#pragma unroll
        for (size_t l = 0; l < 8; l++) {
            samples[l] = buffer[(n1 + pad) * pad_tid + 8 * pad_idx + l];
        }
        if (remain_iters == 1) {
            size_t tw_idx2 = 4 * group * tw_idx + 4 * pad_idx;
            ct_butterfly(samples[0], samples[1], psi[tw_idx2], mod_value);
            ct_butterfly(samples[2], samples[3], psi[tw_idx2 + 1], mod_value);
            ct_butterfly(samples[4], samples[5], psi[tw_idx2 + 2], mod_value);
            ct_butterfly(samples[6], samples[7], psi[tw_idx2 + 3], mod_value);
        } else if (remain_iters == 2) {
            size_t tw_idx2 = 2 * group * tw_idx + 2 * pad_idx;
            fntt4(samples, psi, tw_idx2, mod_value);
            fntt4(samples + 4, psi, tw_idx2 + 1, mod_value);
            // printf("threadid = %4d: %d, %d, %d, %d, %d, %d, %d, %d\n", tid,
            //        tw_idx2, tw_idx2, tw_idx2 + 1, tw_idx2 + 1,
            //        2 * tw_idx2, 2 * tw_idx2 + 1, 2 * tw_idx2 + 2, 2 * tw_idx2 + 3);
        }
#pragma unroll
        for (size_t l = 0; l < 8; l++) {
            buffer[(n1 + pad) * pad_tid + 8 * pad_idx + l] = samples[l];
        }

        __syncthreads();
        for (size_t j = 0; j < 8; j++) {
            *(data_ptr + n_init + t / 4 * j) = buffer[pad_tid * (n1 + pad) + pad_idx + group * j];
        }
    }
}

__global__ static void
inplace_fnwt_radix8_phase2_mod_down_fuse(uint64_t *out,
                                         const uint64_t *ct,
                                         const uint64_t *cx,
                                         const uint64_t *in,
                                         const DMulUIntMod *twiddles,
                                         const DModulus *modulus,
                                         const DMulUIntMod *inv_q_last_mod_q,
                                         const size_t coeff_mod_size,
                                         const size_t start_mod_idx,
                                         const size_t n,
                                         const size_t n1,
                                         const size_t n2) {
    extern __shared__ uint64_t buffer[];

    for (size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
         tid < (n / 8 * coeff_mod_size);
         tid += blockDim.x * gridDim.x) {
        size_t group = n2 / 8;
        size_t set = threadIdx.x / group;
        // size of a block
        uint64_t samples[8];
        size_t t = n2 / 2;
        // prime idx
        size_t twr_idx = coeff_mod_size - 1 - (tid / (n / 8)) + start_mod_idx;
        // index in n/2 range
        size_t n_idx = tid % (n / 8);
        // tid'th block
        size_t m_idx = n_idx / (t / 4);
        size_t t_idx = n_idx % (t / 4);
        uint64_t mod_value = modulus[twr_idx].value();
        const DMulUIntMod *psi = twiddles + n * twr_idx;
        size_t n_init = 2 * m_idx * t + t_idx;
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            samples[j] = in[twr_idx * n + n_init + t / 4 * j];
        }
        size_t tw_idx = n1 + m_idx;
        fntt8(samples, psi, tw_idx, mod_value);
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            buffer[set * n2 + t_idx + t / 4 * j] = samples[j];
        }
        size_t tail = 0;
        __syncthreads();

#pragma unroll
        for (size_t j = 8, k = t / 8; j < t / 4 + 1; j *= 8, k >>= 3) {
            size_t m_idx2 = t_idx / (k / 4);
            size_t t_idx2 = t_idx % (k / 4);
#pragma unroll
            for (size_t l = 0; l < 8; l++) {
                samples[l] =
                        buffer[set * n2 + 2 * m_idx2 * k + t_idx2 + (k / 4) * l];
            }
            size_t tw_idx2 = j * tw_idx + m_idx2;
            fntt8(samples, psi, tw_idx2, mod_value);
#pragma unroll
            for (size_t l = 0; l < 8; l++) {
                buffer[set * n2 + 2 * m_idx2 * k + t_idx2 + (k / 4) * l] =
                        samples[l];
            }
            if (j == t / 8)
                tail = 1;
            if (j == t / 16)
                tail = 2;
            __syncthreads();
        }

#pragma unroll
        for (size_t l = 0; l < 8; l++) {
            samples[l] = buffer[set * n2 + 8 * t_idx + l];
        }
        if (tail == 1) {
            size_t tw_idx2 = t * tw_idx + 4 * t_idx;
            ct_butterfly(samples[0], samples[1], psi[tw_idx2], mod_value);
            ct_butterfly(samples[2], samples[3], psi[tw_idx2 + 1], mod_value);
            ct_butterfly(samples[4], samples[5], psi[tw_idx2 + 2], mod_value);
            ct_butterfly(samples[6], samples[7], psi[tw_idx2 + 3], mod_value);
        } else if (tail == 2) {
            size_t tw_idx2 = (t / 2) * tw_idx + 2 * t_idx;
            fntt4(samples, psi, tw_idx2, mod_value);
            fntt4(samples + 4, psi, tw_idx2 + 1, mod_value);
        }
#pragma unroll
        for (size_t l = 0; l < 8; l++) {
            buffer[set * n2 + 8 * t_idx + l] = samples[l];
        }
        __syncthreads();

        uint64_t modulus2 = mod_value << 1;
        // final reduction
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            samples[j] = buffer[set * n2 + t_idx + t / 4 * j];
            if (samples[j] >= modulus2)
                samples[j] -= modulus2;
            if (samples[j] >= mod_value)
                samples[j] -= mod_value;
        }
#pragma unroll
        for (size_t j = 0; j < 8; j++) {
            uint64_t offset = twr_idx * n + n_init + t / 4 * j;
            uint64_t inv_q_last_mod_q_op = inv_q_last_mod_q[twr_idx].operand();
            _uint128_t tmp;
            add_uint64_uint64(cx[offset], mod_value, tmp.lo);
            sub_uint64_uint64(tmp.lo, samples[j], tmp.lo);
            tmp = multiply_uint64_uint64(tmp.lo, inv_q_last_mod_q_op);
            tmp = add_uint128_uint64(tmp, ct[offset]);
            out[offset] = barrett_reduce_uint128_uint64(tmp, mod_value, modulus[twr_idx].const_ratio());
        }
    }
}

// fuse in key switching mod up
void nwt_2d_radix8_forward_modup_fuse(uint64_t *out,
                                      const uint64_t *in,
                                      size_t modulus_index,
                                      const DNTTTable &ntt_tables,
                                      size_t coeff_modulus_size,
                                      size_t start_modulus_idx) {

    size_t poly_degree = ntt_tables.n();
    size_t phase1_sample_size = SAMPLE_SIZE(poly_degree);

    const size_t phase2_sample_size = poly_degree / phase1_sample_size;
    // radix-8 nwt, DO NOT change this variable !!!
    const size_t per_thread_sample_size = 8;
    // per_block_pad can be 1, 2, 4, etc., per_block_pad * phase1_sample_size / 8 <= blockDim.x
    // per_block_pad = 4 seems to be most optimized
    // for n=4096, max pad = 8
    const size_t per_block_pad = 8;
    const size_t per_block_memory = cahel::util::blockDimNTT.x * per_thread_sample_size * sizeof(uint64_t);
    //
    inplace_fnwt_radix8_phase1_single_mod_mod_up_fuse<<<
    cahel::util::gridDimNTT,
    (phase1_sample_size / 8) * per_block_pad,
    (phase1_sample_size + per_block_pad + 1) * per_block_pad * sizeof(uint64_t)>>>(
            out,
            in,
            ntt_tables.twiddle(),
            ntt_tables.modulus(),
            coeff_modulus_size,
            start_modulus_idx,
            poly_degree,
            phase1_sample_size,
            per_block_pad,
            modulus_index);
    // max 512 threads per block
    inplace_fnwt_radix8_phase2_single_mod<<<cahel::util::gridDimNTT, cahel::util::blockDimNTT, per_block_memory>>>(
            out,
            ntt_tables.twiddle(),
            ntt_tables.modulus(),
            coeff_modulus_size,
            start_modulus_idx,
            poly_degree,
            phase1_sample_size,
            phase2_sample_size,
            modulus_index);
}

// fuse in CKKS key switching mod down
void nwt_2d_radix8_forward_moddown_fuse(uint64_t *encrypted,
                                        const uint64_t *cx,
                                        const uint64_t *cx_last,
                                        uint64_t *reduced_cx_last,
                                        const DNTTTable &ntt_tables,
                                        const DMulUIntMod *inv_q_last_mod_q,
                                        size_t coeff_modulus_size,
                                        size_t q_coeff_count,
                                        size_t pq_coeff_count,
                                        size_t start_modulus_idx) {

    size_t poly_degree = ntt_tables.n();
    auto base_rns = ntt_tables.modulus();
    size_t phase1_sample_size = SAMPLE_SIZE(poly_degree);
    const size_t phase2_sample_size = poly_degree / phase1_sample_size;
    // radix-8 nwt, DO NOT change this variable !!!
    const size_t per_thread_sample_size = 8;
    // per_block_pad can be 1, 2, 4, etc., per_block_pad * phase1_sample_size / 8 <= blockDim.x
    // per_block_pad = 4 seems to be most optimized
    // for n=4096, max pad = 8
    const size_t per_block_pad = 8;
    const size_t per_block_memory = cahel::util::blockDimNTT.x * per_thread_sample_size * sizeof(uint64_t);
    //
    inplace_fnwt_radix8_phase1_mod_down_fuse<<<
    cahel::util::gridDimNTT,
    (phase1_sample_size / 8) * per_block_pad,
    (phase1_sample_size + per_block_pad + 1) * per_block_pad * sizeof(uint64_t)>>>(
            reduced_cx_last,
            cx_last,
            ntt_tables.twiddle(),
            ntt_tables.modulus(),
            coeff_modulus_size,
            start_modulus_idx,
            poly_degree,
            phase1_sample_size,
            per_block_pad);
    // max 512 threads per block
    inplace_fnwt_radix8_phase2_mod_down_fuse<<<cahel::util::gridDimNTT, cahel::util::blockDimNTT, per_block_memory>>>(
            encrypted,
            encrypted,
            cx,
            reduced_cx_last,
            ntt_tables.twiddle(),
            ntt_tables.modulus(),
            inv_q_last_mod_q,
            coeff_modulus_size,
            start_modulus_idx,
            poly_degree,
            phase1_sample_size,
            phase2_sample_size);
}
