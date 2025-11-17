# AVX512 BFP Compression Implementation

## Overview

**File**: `lib/ofh/compression/iq_compression_bfp_avx512.cpp`

This document explains the implementation of Block Floating Point (BFP) IQ sample compression using AVX512 SIMD instructions. This is the **fastest available implementation** for x86_64 CPUs with AVX512 support, processing **4 PRBs (Resource Blocks) in parallel**.

**Standard**: O-RAN.WG4.CUS Annex A.1.2

---

## Architecture

### Class Hierarchy

```
iq_compressor (interface)
    ↑
iq_compression_bfp_impl (base class - generic implementation)
    ↑
iq_compression_bfp_avx512 (AVX512-optimized implementation)
```

The AVX512 implementation inherits from the generic BFP implementation and overrides the `compress()` and `decompress()` methods with SIMD-optimized versions.

### Key Design Principles

1. **Fallback to Generic**: If AVX512 doesn't support the requested bitwidth, falls back to generic implementation
2. **Batch Processing**: Processes 4 PRBs simultaneously when possible
3. **Masked Operations**: Uses AVX512 mask registers for partial loads/stores
4. **Big-Endian Packing**: Maintains network byte order for OFH protocol

---

## AVX512 Fundamentals

### Register Size

- **AVX512 Register**: 512 bits = 64 bytes
- **16-bit samples per register**: 32 samples
- **One PRB**: 12 subcarriers × 2 (I+Q) = 24 samples
- **Three registers**: 96 samples = 4 PRBs (24 × 4)

### Key AVX512 Intrinsics Used

| Intrinsic | Purpose | Description |
|-----------|---------|-------------|
| `_mm512_maskz_loadu_epi16` | Load | Masked load of 16-bit integers |
| `_mm512_srai_epi16` | Shift | Arithmetic right shift (exponent application) |
| `_mm512_set1_epi16` | Initialize | Broadcast single value to all lanes |
| `_mm512_mask_storeu_epi16` | Store | Masked store of 16-bit integers |
| `_mm512_sllv_epi16` | Shift | Variable left shift |
| `_mm512_shuffle_epi8` | Shuffle | Byte-level permutation |

---

## Compression Algorithm

### High-Level Flow

```
Input: IQ samples (cbf16_t) → Quantize → Find Exponents → Shift → Pack → Output
```

### Detailed Compression Process

## Input Buffer Data Format

### Function Signature

```68:70:lib/ofh/compression/iq_compression_bfp_avx512.cpp
void iq_compression_bfp_avx512::compress(span<uint8_t>                buffer,
                                         span<const cbf16_t>          iq_data,
                                         const ru_compression_params& params)
```

### Input Type: `cbf16_t`

The input buffer contains **complex brain floating-point 16-bit** samples:

```50:63:include/srsran/adt/complex.h
struct cbf16_t {
  bf16_t real;
  bf16_t imag;

  cbf16_t(float real_ = 0.0F, float imag_ = 0.0F) : real(to_bf16(real_)), imag(to_bf16(imag_)) {}

  cbf16_t(cf_t value) : cbf16_t(value.real(), value.imag()) {}

  cbf16_t(std::complex<double> value) : real(to_bf16(value.real())), imag(to_bf16(value.imag())) {}

  bool operator==(cbf16_t other) const { return (real == other.real) && (imag == other.imag); }

  bool operator!=(cbf16_t other) const { return !(*this == other); }
};
```

**Structure**:
- **Size**: 4 bytes per sample (2 × 16-bit = 32 bits)
- **Layout**: `[real (16-bit), imag (16-bit)]`
- **Format**: Brain Float 16 (bfloat16) for each component

### Brain Float 16 (bf16_t) Format

```32:36:include/srsran/adt/bf16.h
/// \brief Brain floating point (\c bfloat16).
///
/// Custom 16-bit floating point. It consits of 1-bit sign, 8-bit exponent and 7-bit fraction.
/// \note This type is meant for storage purposes only, no operations other than equality comparison are allowed.
using bf16_t = strong_type<uint16_t, struct strong_bf16_tag, strong_equality>;
```

**Bit Layout**:
```
┌─────────────────────────────────────┐
│ bf16_t (16 bits)                    │
├─────────────────────────────────────┤
│ Sign (1 bit) | Exponent (8 bits) | │
│ Fraction (7 bits)                   │
└─────────────────────────────────────┘
```

**Format Details**:
- **Sign bit**: 1 bit (bit 15)
- **Exponent**: 8 bits (bits 14-7) - Same as IEEE 754 float32
- **Fraction**: 7 bits (bits 6-0) - Truncated from float32
- **Range**: Similar to float32 but with reduced precision

### Input Buffer Memory Layout

```
Input Buffer (span<const cbf16_t> iq_data):
┌─────────────────────────────────────────────────────────┐
│ Sample 0: [real_bf16, imag_bf16]  (4 bytes)            │
│ Sample 1: [real_bf16, imag_bf16]  (4 bytes)            │
│ Sample 2: [real_bf16, imag_bf16]  (4 bytes)            │
│ ...                                                      │
│ Sample N-1: [real_bf16, imag_bf16]  (4 bytes)           │
└─────────────────────────────────────────────────────────┘

Where:
- Each sample represents one Resource Element (RE)
- One PRB = 12 subcarriers = 12 samples
- Samples are stored sequentially (subcarrier 0, 1, 2, ..., 11)
```

### Data Organization

**Per PRB Structure**:
```
PRB 0:
┌─────────────────────────────────────────┐
│ RE[0]:  [I₀, Q₀]  (cbf16_t)            │
│ RE[1]:  [I₁, Q₁]  (cbf16_t)            │
│ RE[2]:  [I₂, Q₂]  (cbf16_t)            │
│ ...                                     │
│ RE[11]: [I₁₁, Q₁₁]  (cbf16_t)          │
└─────────────────────────────────────────┘
Total: 12 samples × 4 bytes = 48 bytes per PRB
```

**Multiple PRBs**:
```
Input Buffer:
┌─────────────────────────────────────────┐
│ PRB 0: 12 samples (48 bytes)           │
│ PRB 1: 12 samples (48 bytes)           │
│ PRB 2: 12 samples (48 bytes)           │
│ ...                                     │
│ PRB N-1: 12 samples (48 bytes)         │
└─────────────────────────────────────────┘
```

### Conversion to Quantized Format

```89:95:lib/ofh/compression/iq_compression_bfp_avx512.cpp
  // Auxiliary arrays used for float to fixed point conversion of the input data.
  std::array<int16_t, NOF_SAMPLES_PER_PRB * MAX_NOF_PRBS> input_quantized;

  span<const bf16_t> float_samples_span(reinterpret_cast<const bf16_t*>(iq_data.data()), iq_data.size() * 2U);
  span<int16_t>      input_quantized_span(input_quantized.data(), float_samples_span.size());
  // Performs conversion of input brain float values to signed 16-bit integers.
  quantize_input(input_quantized_span, float_samples_span);
```

**Conversion Process**:

1. **Reinterpretation**: 
   - `cbf16_t` array is reinterpreted as `bf16_t` array
   - Each `cbf16_t` (4 bytes) becomes 2 × `bf16_t` (2 bytes each)
   - Size doubles: `iq_data.size() * 2U`

2. **Quantization**:
   - Converts `bf16_t` → `float` → `int16_t`
   - Uses `quantize_input()` function
   - Result: Interleaved I/Q samples as `int16_t`

**Quantized Buffer Layout**:
```
input_quantized (int16_t array):
┌─────────────────────────────────────────┐
│ PRB 0:                                   │
│   I₀, Q₀, I₁, Q₁, ..., I₁₁, Q₁₁        │
│   (24 × int16_t = 48 bytes)             │
│ PRB 1:                                   │
│   I₀, Q₀, I₁, Q₁, ..., I₁₁, Q₁₁        │
│   (24 × int16_t = 48 bytes)             │
│ ...                                     │
└─────────────────────────────────────────┘
```

**Key Constants**:
- `NOF_SUBCARRIERS_PER_RB = 12` (subcarriers per PRB)
- `NOF_SAMPLES_PER_PRB = 24` (12 subcarriers × 2 for I+Q)
- Each sample: `int16_t` (2 bytes)

### Memory Access Pattern

The code accesses the input as:

```92:93:lib/ofh/compression/iq_compression_bfp_avx512.cpp
  span<const bf16_t> float_samples_span(reinterpret_cast<const bf16_t*>(iq_data.data()), iq_data.size() * 2U);
  span<int16_t>      input_quantized_span(input_quantized.data(), float_samples_span.size());
```

**Reinterpretation**:
- `cbf16_t*` → `bf16_t*`: Treats complex samples as flat array of floats
- **Memory view**: `[real₀, imag₀, real₁, imag₁, real₂, imag₂, ...]`
- **Size**: `iq_data.size() * 2` (each complex sample = 2 floats)

### Example Input Buffer

For **1 PRB** (12 subcarriers):

```
Input (cbf16_t array, 48 bytes):
┌─────────────────────────────────────────┐
│ Offset | Content                        │
├─────────────────────────────────────────┤
│ 0x00   | real₀ (bf16_t, 2 bytes)       │
│ 0x02   | imag₀ (bf16_t, 2 bytes)       │
│ 0x04   | real₁ (bf16_t, 2 bytes)       │
│ 0x06   | imag₁ (bf16_t, 2 bytes)        │
│ ...                                     │
│ 0x2C   | real₁₁ (bf16_t, 2 bytes)       │
│ 0x2E   | imag₁₁ (bf16_t, 2 bytes)       │
└─────────────────────────────────────────┘
```

After reinterpretation (bf16_t array, 48 bytes):
```
┌─────────────────────────────────────────┐
│ [real₀, imag₀, real₁, imag₁, ...,     │
│  real₁₁, imag₁₁]                       │
└─────────────────────────────────────────┘
```

After quantization (int16_t array, 48 bytes):
```
┌─────────────────────────────────────────┐
│ [I₀, Q₀, I₁, Q₁, ..., I₁₁, Q₁₁]        │
│ (24 × int16_t)                          │
└─────────────────────────────────────────┘
```

### Input Buffer Format Summary

| **Aspect** | **Details** |
|------------|-------------|
| **Input Type** | `span<const cbf16_t>` |
| **Sample Size** | 4 bytes per sample (2 × 16-bit) |
| **Sample Structure** | `struct { bf16_t real; bf16_t imag; }` |
| **Format** | Complex Brain Float 16 (bfloat16) |
| **PRB Size** | 12 samples (subcarriers) |
| **PRB Bytes** | 48 bytes (12 × 4 bytes) |
| **Interleaving** | I and Q interleaved per sample |
| **Order** | Sequential by subcarrier (0, 1, 2, ..., 11) |
| **Memory Layout** | `[real₀, imag₀, real₁, imag₁, ..., real₁₁, imag₁₁]` |

### Brain Float 16 (bf16_t) Details

| **Component** | **Bits** | **Position** | **Description** |
|---------------|----------|--------------|-----------------|
| **Sign** | 1 | Bit 15 | Sign bit (0=positive, 1=negative) |
| **Exponent** | 8 | Bits 14-7 | Exponent (same as IEEE 754 float32) |
| **Fraction** | 7 | Bits 6-0 | Mantissa (truncated from float32) |
| **Total** | 16 | Bits 15-0 | 16-bit floating point |

**Conversion Chain**:
```
cbf16_t → bf16_t → float → int16_t
(4 bytes) (2 bytes) (4 bytes) (2 bytes)
```

### Quantization Process

The `quantize_input()` function performs:

```32:40:lib/ofh/compression/iq_compression_bfp_impl.cpp
void iq_compression_bfp_impl::quantize_input(span<int16_t> out, span<const bf16_t> in)
{
  srsran_assert(in.size() == out.size(), "Input and output spans must have the same size");

  // Quantizer object.
  quantizer q(Q_BIT_WIDTH);

  // Convert input to int16_t representation.
  q.to_fixed_point(out, in, iq_scaling);
```

**Steps**:
1. Convert `bf16_t` → `float` using `to_float()`
2. Scale by `iq_scaling` factor
3. Round to nearest integer
4. Clamp to `int16_t` range [-32768, 32767]

**Result**: Interleaved I/Q samples as signed 16-bit integers ready for SIMD processing.

---

#### Step 1: Input Quantization

```68:95:lib/ofh/compression/iq_compression_bfp_avx512.cpp
void iq_compression_bfp_avx512::compress(span<uint8_t>                buffer,
                                         span<const cbf16_t>          iq_data,
                                         const ru_compression_params& params)
{
  // Use generic implementation if AVX512 utils don't support requested bit width.
  if (!mm512::iq_width_packing_supported(params.data_width)) {
    iq_compression_bfp_impl::compress(buffer, iq_data, params);
    return;
  }

  // AVX512 register size in a number of 16-bit words.
  static constexpr size_t AVX512_REG_SIZE = 32;

  // Number of input PRBs.
  unsigned nof_prbs = (iq_data.size() / NOF_SUBCARRIERS_PER_RB);

  // Size in bytes of one compressed PRB using the given compression parameters.
  unsigned prb_size = get_compressed_prb_size(params).value();

  srsran_assert(buffer.size() >= prb_size * nof_prbs, "Output buffer doesn't have enough space to decompress PRBs");

  // Auxiliary arrays used for float to fixed point conversion of the input data.
  std::array<int16_t, NOF_SAMPLES_PER_PRB * MAX_NOF_PRBS> input_quantized;

  span<const bf16_t> float_samples_span(reinterpret_cast<const bf16_t*>(iq_data.data()), iq_data.size() * 2U);
  span<int16_t>      input_quantized_span(input_quantized.data(), float_samples_span.size());
  // Performs conversion of input brain float values to signed 16-bit integers.
  quantize_input(input_quantized_span, float_samples_span);
```

**Process**:
1. **Input**: `span<const cbf16_t>` - Complex brain float samples
2. **Reinterpret**: Cast to `bf16_t*` to access real/imag components separately
3. **Quantize**: Convert `bf16_t` → `float` → `int16_t` via `quantize_input()`
4. **Output**: `input_quantized` array with interleaved I/Q as `int16_t`
5. **Layout**: One PRB = 24 samples (12 subcarriers × 2 for I+Q)

#### Step 2: Batch Processing (4 PRBs at a time)

```97:140:lib/ofh/compression/iq_compression_bfp_avx512.cpp
  // Compression algorithm implemented according to Annex A.1.2 in O-RAN.WG4.CUS.
  unsigned sample_idx = 0;
  unsigned rb         = 0;

  // With 3 AVX512 registers we can process 4 PRBs at a time (48 16-bit IQ pairs).
  for (size_t rb_index_end = (nof_prbs / 4) * 4; rb != rb_index_end; rb += 4) {
    // Load input.
    __m512i r0_epi16 = loadu_epi16_avx512(&input_quantized[sample_idx]);
    __m512i r1_epi16 = loadu_epi16_avx512(&input_quantized[sample_idx + AVX512_REG_SIZE]);
    __m512i r2_epi16 = loadu_epi16_avx512(&input_quantized[sample_idx + 2 * AVX512_REG_SIZE]);

    // Determine exponents for each of the four PRBs.
    __m512i exp_epu32 = mm512::determine_bfp_exponent(r0_epi16, r1_epi16, r2_epi16, params.data_width);

    // Exponents are stored in the first bytes of each 128bit lane of the result.
    const auto* exp_byte_ptr = reinterpret_cast<const uint8_t*>(&exp_epu32);

    // Compress the first PRB.
    // Save the exponent.
    span<uint8_t> output_span(&buffer[rb * prb_size], prb_size);
    std::memcpy(output_span.data(), &exp_byte_ptr[0], sizeof(uint8_t));
    // Apply exponent (compress).
    __m512i rb0_shifted_epi16 = _mm512_srai_epi16(r0_epi16, exp_byte_ptr[0]);
    // Pack compressed samples.
    mm512::pack_prb_big_endian(
        output_span.last(output_span.size() - sizeof(uint8_t)), rb0_shifted_epi16, params.data_width);

    // Compress second PRB.
    output_span = span<uint8_t>(&buffer[(rb + 1) * prb_size], prb_size);
    compress_prb_avx512(
        output_span, &input_quantized[sample_idx + NOF_SAMPLES_PER_PRB], exp_byte_ptr[16], params.data_width);

    // Compress third PRB.
    output_span = span<uint8_t>(&buffer[(rb + 2) * prb_size], prb_size);
    compress_prb_avx512(
        output_span, &input_quantized[sample_idx + 2 * NOF_SAMPLES_PER_PRB], exp_byte_ptr[32], params.data_width);

    // Compress fourth PRB.
    output_span = span<uint8_t>(&buffer[(rb + 3) * prb_size], prb_size);
    compress_prb_avx512(
        output_span, &input_quantized[sample_idx + 3 * NOF_SAMPLES_PER_PRB], exp_byte_ptr[48], params.data_width);

    sample_idx += 4 * NOF_SAMPLES_PER_PRB;
  }
```

**Key Operations**:

1. **Load 3 AVX512 Registers**:
   - `r0_epi16`: First 32 samples (PRB 0 + 8 samples of PRB 1)
   - `r1_epi16`: Next 32 samples (remaining PRB 1 + PRB 2 + 8 samples of PRB 3)
   - `r2_epi16`: Next 32 samples (remaining PRB 3 + PRB 4 + 8 samples of PRB 5)
   - Total: 96 samples = 4 complete PRBs

2. **Determine Exponents**:
   - `mm512::determine_bfp_exponent()` calculates exponents for all 4 PRBs in parallel
   - Finds maximum magnitude in each PRB
   - Calculates shared exponent based on bitwidth
   - Returns 4 exponents (one per 128-bit lane)

3. **Compress Each PRB**:
   - Apply exponent (arithmetic right shift)
   - Pack compressed samples
   - Store exponent as first byte

#### Step 3: Single PRB Compression Helper

```43:66:lib/ofh/compression/iq_compression_bfp_avx512.cpp
/// \brief Compresses samples of a single resource block using AVX512 intrinsics.
///
/// \param[out] compressed_prb Compressed PRB (stores compressed packed values).
/// \param[in] uncompr_samples Pointer to an array of uncompressed 16-bit samples.
/// \param[in] exponent        Exponent used in BFP compression.
/// \param[in] data_width      Bit width of resulting compressed samples.
static void
compress_prb_avx512(span<uint8_t> comp_prb_buffer, const int16_t* uncomp_samples, uint8_t exponent, unsigned data_width)
{
  const __mmask32 load_mask = 0x00ffffff;

  // Load from memory.
  __m512i rb_epi16 = _mm512_maskz_loadu_epi16(load_mask, uncomp_samples);

  // Apply exponent (compress).
  __m512i rb_shifted_epi16 = _mm512_srai_epi16(rb_epi16, exponent);

  // Save exponent.
  std::memcpy(comp_prb_buffer.data(), &exponent, sizeof(uint8_t));

  // Pack compressed samples.
  mm512::pack_prb_big_endian(
      comp_prb_buffer.last(comp_prb_buffer.size() - sizeof(exponent)), rb_shifted_epi16, data_width);
}
```

**Process**:
1. **Masked Load**: Loads 24 samples (mask `0x00ffffff` = first 24 lanes)
2. **Apply Exponent**: Arithmetic right shift by exponent value
3. **Store Exponent**: First byte of output buffer
4. **Pack Samples**: Packs shifted samples to compressed bitwidth (9 bits in your config)

#### Step 4: Remaining PRBs (Single Processing)

```142:163:lib/ofh/compression/iq_compression_bfp_avx512.cpp
  // Process the remaining PRBs (one PRB at a time),
  for (; rb != nof_prbs; ++rb) {
    const __m512i   AVX512_ZERO = _mm512_set1_epi16(0);
    const __mmask32 load_mask   = 0x00ffffff;
    __m512i         rb_epi16    = _mm512_maskz_loadu_epi16(load_mask, &input_quantized[sample_idx]);

    // Determine BFP exponent and extract it from the first byte of the first 128bit lane.
    __m512i     exp_epu32    = mm512::determine_bfp_exponent(rb_epi16, AVX512_ZERO, AVX512_ZERO, params.data_width);
    const auto* exp_byte_ptr = reinterpret_cast<const uint8_t*>(&exp_epu32);

    span<uint8_t> output_span(&buffer[rb * prb_size], prb_size);

    // Save exponent.
    std::memcpy(output_span.data(), &exp_byte_ptr[0], sizeof(uint8_t));

    // Shift and pack a PRB using utility function.
    __m512i rb_shifted_epi16 = _mm512_srai_epi16(rb_epi16, exp_byte_ptr[0]);
    mm512::pack_prb_big_endian(
        output_span.last(output_span.size() - sizeof(uint8_t)), rb_shifted_epi16, params.data_width);

    sample_idx += NOF_SAMPLES_PER_PRB;
  }
```

**Purpose**: Handles PRBs that don't fit in groups of 4 (remainder after batch processing)

---

## Decompression Algorithm

### High-Level Flow

```
Input: Compressed bytes → Unpack → Scale by Exponent → Convert to Float → Output
```

### Detailed Decompression Process

```166:221:lib/ofh/compression/iq_compression_bfp_avx512.cpp
void iq_compression_bfp_avx512::decompress(span<cbf16_t>                iq_data,
                                           span<const uint8_t>          compressed_data,
                                           const ru_compression_params& params)
{
  // Use generic implementation if AVX512 utils don't support requested bit width.
  if (!mm512::iq_width_packing_supported(params.data_width)) {
    iq_compression_bfp_impl::decompress(iq_data, compressed_data, params);
    return;
  }

  // Number of output PRBs.
  unsigned nof_prbs = iq_data.size() / NOF_SUBCARRIERS_PER_RB;

  // Size in bytes of one compressed PRB using the given compression parameters.
  unsigned comp_prb_size = get_compressed_prb_size(params).value();

  srsran_assert(compressed_data.size() >= nof_prbs * comp_prb_size,
                "Input does not contain enough bytes to decompress {} PRBs",
                nof_prbs);

  const float fixp_gain = (1 << (Q_BIT_WIDTH - 1)) - 1.0f;

  // Determine array size so that AVX512 store operation doesn't write the data out of array bounds.
  constexpr size_t avx512_size_iqs = 32;
  constexpr size_t prb_size        = divide_ceil(NOF_SUBCARRIERS_PER_RB * 2, avx512_size_iqs) * avx512_size_iqs;

  alignas(64) std::array<int16_t, MAX_NOF_PRBS * prb_size>                 unpacked_iq_data;
  alignas(64) std::array<float, MAX_NOF_PRBS * NOF_SUBCARRIERS_PER_RB * 2> unpacked_iq_scaling;

  unsigned idx = 0;
  for (unsigned c_prb_idx = 0; c_prb_idx != nof_prbs; ++c_prb_idx) {
    // Get view over compressed PRB bytes.
    span<const uint8_t> comp_prb_buffer(&compressed_data[c_prb_idx * comp_prb_size], comp_prb_size);

    // Compute scaling factor, first byte contains the exponent.
    uint8_t exponent = comp_prb_buffer[0];
    float   scaler   = 1 << exponent;

    // Get view over the bytes following the compression parameter.
    comp_prb_buffer = comp_prb_buffer.last(comp_prb_buffer.size() - sizeof(exponent));

    // Unpack resource block.
    span<int16_t> unpacked_prb_span(&unpacked_iq_data[idx], prb_size);
    mm512::unpack_prb_big_endian(unpacked_prb_span, comp_prb_buffer, params.data_width);

    // Save scaling factor.
    std::fill(&unpacked_iq_scaling[idx], &unpacked_iq_scaling[idx] + (NOF_SUBCARRIERS_PER_RB * 2), scaler / fixp_gain);

    idx += (NOF_SUBCARRIERS_PER_RB * 2);
  }
  span<int16_t> unpacked_iq_int16_span(unpacked_iq_data.data(), iq_data.size() * 2);
  span<float>   unpacked_iq_scaling_span(unpacked_iq_scaling.data(), iq_data.size() * 2);

  // Scale unpacked IQ samples using saved exponents and convert to complex samples.
  srsvec::convert(iq_data, unpacked_iq_int16_span, unpacked_iq_scaling_span);
}
```

**Process**:

1. **Read Exponent**: First byte of compressed PRB contains the exponent
2. **Calculate Scaling Factor**: `scaler = 1 << exponent`
3. **Unpack Samples**: Uses AVX512 to unpack compressed samples back to 16-bit integers
4. **Apply Scaling**: Multiplies unpacked samples by scaling factor
5. **Convert to Float**: Converts scaled integers to complex floating-point samples

**Key Features**:
- **64-byte alignment**: Arrays aligned for optimal AVX512 performance
- **Batch scaling**: Pre-calculates scaling factors for all samples
- **Vectorized conversion**: Uses `srsvec::convert()` for efficient float conversion

---

## AVX512 Helper Functions

### Load Function

```35:41:lib/ofh/compression/iq_compression_bfp_avx512.cpp
/// Loads packed 16-bit integers from non-aligned memory.
static inline __m512i loadu_epi16_avx512(const void* mem_address)
{
  const __mmask32 mask       = 0xffffffff;
  const __m512i   zero_epi16 = _mm512_set1_epi64(0);
  return _mm512_mask_loadu_epi16(zero_epi16, mask, mem_address);
}
```

**Purpose**: Loads 32 × 16-bit samples from unaligned memory using masked load

### Exponent Determination

The `mm512::determine_bfp_exponent()` function (in `avx512_helpers.h`):
- Finds maximum absolute value in each PRB
- Calculates leading zero count
- Determines optimal exponent for given bitwidth
- Returns 4 exponents (one per PRB) in a single AVX512 register

### Packing Functions

The `mm512::pack_prb_big_endian()` function (in `packing_utils_avx512.h`):
- Packs 24 × 16-bit samples into compressed format
- Supports 9-bit, 14-bit, and 16-bit widths
- Maintains big-endian byte order for network transmission
- Uses AVX512 shuffle and shift operations

**For 9-bit width** (your configuration):
- 24 samples × 9 bits = 216 bits = 27 bytes
- Plus 1 byte for exponent = 28 bytes per PRB

---

## Performance Optimizations

### 1. Batch Processing

**4 PRBs in Parallel**:
- Processes 96 samples simultaneously (3 AVX512 registers)
- Reduces loop overhead
- Better instruction-level parallelism

### 2. Masked Operations

**Partial Loads/Stores**:
- Uses mask registers for PRB boundaries
- Avoids unnecessary memory operations
- Prevents out-of-bounds access

### 3. Aligned Memory

**64-byte Alignment**:
- Decompression arrays aligned to cache line boundaries
- Enables faster memory access
- Better cache utilization

### 4. Vectorized Operations

**SIMD Throughout**:
- Exponent calculation: Vectorized
- Shifting: Vectorized (`_mm512_srai_epi16`)
- Packing/Unpacking: Vectorized
- Conversion: Vectorized (`srsvec::convert`)

### 5. Fallback Strategy

**Generic Implementation**:
- Falls back to generic if bitwidth not supported
- Ensures correctness for all configurations
- No performance penalty for unsupported cases

---

## Memory Layout

### Compression Input

```
Input Array (input_quantized):
┌─────────────────────────────────────────┐
│ PRB 0: 24 samples (I+Q)                │
│ PRB 1: 24 samples (I+Q)                │
│ PRB 2: 24 samples (I+Q)                │
│ PRB 3: 24 samples (I+Q)                │
│ ...                                     │
└─────────────────────────────────────────┘
```

### Compression Output (9-bit, your config)

```
Compressed PRB:
┌─────────────────────────────────────────┐
│ Byte 0: Exponent (8 bits)              │
│ Bytes 1-27: Compressed samples         │
│   (24 samples × 9 bits = 216 bits)     │
└─────────────────────────────────────────┘
Total: 28 bytes per PRB
```

### AVX512 Register Layout

```
__m512i register (512 bits = 64 bytes):
┌─────────────────────────────────────────┐
│ Lane 0 (128 bits): 8 × 16-bit samples  │
│ Lane 1 (128 bits): 8 × 16-bit samples  │
│ Lane 2 (128 bits): 8 × 16-bit samples  │
│ Lane 3 (128 bits): 8 × 16-bit samples  │
└─────────────────────────────────────────┘
Total: 32 × 16-bit samples
```

---

## BFP Algorithm Details

### Block Floating Point Concept

1. **Block**: One PRB = 24 IQ samples
2. **Exponent**: Shared across all samples in block
3. **Mantissa**: Each sample quantized to fixed bitwidth

### Exponent Calculation

For each PRB:
1. Find maximum absolute value: `max_abs = max(|sample_i|)`
2. Calculate leading zeros: `lzcnt = count_leading_zeros(max_abs)`
3. Determine exponent: `exponent = 16 - data_width - lzcnt`
4. Ensure samples fit in bitwidth after shift

### Compression Formula

```
compressed_sample = original_sample >> exponent
```

### Decompression Formula

```
reconstructed_sample = (compressed_sample << exponent) × scaling_factor
```

Where `scaling_factor = (1 << exponent) / fixp_gain` accounts for quantization.

---

## Code Flow Diagrams

### Compression Flow

```
┌─────────────────────────────────────────┐
│ Input: cbf16_t IQ samples               │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ Quantize to int16_t                     │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ Load 3 AVX512 registers (4 PRBs)        │
│ r0, r1, r2 = 96 samples                 │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ Determine 4 exponents in parallel       │
│ mm512::determine_bfp_exponent()         │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ For each PRB:                           │
│   1. Shift by exponent                  │
│   2. Pack to compressed format          │
│   3. Store exponent + packed data       │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ Output: Compressed bytes                 │
└─────────────────────────────────────────┘
```

### Decompression Flow

```
┌─────────────────────────────────────────┐
│ Input: Compressed bytes                 │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ For each PRB:                           │
│   1. Read exponent (first byte)         │
│   2. Calculate scaling factor           │
│   3. Unpack compressed samples          │
│   4. Apply scaling                      │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ Convert to cbf16_t                      │
│ srsvec::convert()                       │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ Output: cbf16_t IQ samples              │
└─────────────────────────────────────────┘
```

---

## Performance Characteristics

### Throughput

| Metric | Value |
|--------|-------|
| **PRBs per iteration** | 4 (batch) or 1 (remainder) |
| **Samples per iteration** | 96 (batch) or 24 (single) |
| **SIMD width** | 512 bits |
| **Register utilization** | 3 registers for batch processing |

### Memory Access

- **Aligned loads**: 64-byte aligned for optimal performance
- **Masked operations**: Only access required samples
- **Cache-friendly**: Sequential access patterns

### Instruction Count

- **Load operations**: 3 per 4 PRBs (batch)
- **Shift operations**: 4 per 4 PRBs (one per PRB)
- **Pack operations**: 4 per 4 PRBs (one per PRB)
- **Store operations**: 4 per 4 PRBs (one per PRB)

---

## Comparison with Other Implementations

| Implementation | Throughput | SIMD Width | Registers Used |
|----------------|------------|------------|----------------|
| **Generic** | 1 PRB | None | N/A |
| **AVX2** | 2 PRBs | 256 bits | 3 registers |
| **AVX512** ⭐ | **4 PRBs** | **512 bits** | **3 registers** |
| **NEON** (ARM) | 4 PRBs | 128 bits | Multiple |

---

## Key Constants

```cpp
// From the implementation
static constexpr size_t AVX512_REG_SIZE = 32;  // 16-bit samples per register
constexpr size_t NOF_SUBCARRIERS_PER_RB = 12;  // Subcarriers per PRB
constexpr size_t NOF_SAMPLES_PER_PRB = 24;      // IQ samples per PRB (12 × 2)
const __mmask32 load_mask = 0x00ffffff;        // Mask for 24 samples
```

---

## Error Handling

### Fallback Conditions

1. **Unsupported Bitwidth**: Falls back to generic if `mm512::iq_width_packing_supported()` returns false
2. **Buffer Size Checks**: Assertions ensure sufficient buffer space
3. **Alignment**: Arrays aligned to 64-byte boundaries for safety

### Supported Bitwidths

The AVX512 implementation supports:
- **9 bits** (your configuration) ✅
- **14 bits** ✅
- **16 bits** ✅

Other bitwidths fall back to generic implementation.

---

## Dependencies

### Header Files

- `avx512_helpers.h`: AVX512 utility functions (exponent calculation)
- `packing_utils_avx512.h`: Packing/unpacking functions
- `quantizer.h`: Float-to-int conversion
- `iq_compression_bfp_impl.h`: Base class

### External Functions

- `mm512::determine_bfp_exponent()`: Calculate exponents
- `mm512::pack_prb_big_endian()`: Pack samples
- `mm512::unpack_prb_big_endian()`: Unpack samples
- `quantize_input()`: Convert float to int16
- `srsvec::convert()`: Convert int16 to float with scaling

---

## Usage Example

```cpp
// Create compressor
auto compressor = create_iq_compressor(
    compression_type::BFP, 
    logger, 
    iq_scaling, 
    "auto"  // Will select AVX512 if available
);

// Compress
ru_compression_params params;
params.type = compression_type::BFP;
params.data_width = 9;  // 9-bit compression

span<uint8_t> output_buffer(...);
span<const cbf16_t> input_samples(...);

compressor->compress(output_buffer, input_samples, params);

// Decompress
auto decompressor = create_iq_decompressor(
    compression_type::BFP,
    logger,
    "auto"
);

span<cbf16_t> output_samples(...);
decompressor->decompress(output_samples, output_buffer, params);
```

---

## Summary

The AVX512 BFP compression implementation provides:

✅ **Maximum Performance**: 4 PRBs processed in parallel  
✅ **SIMD Optimization**: Full 512-bit register utilization  
✅ **Standards Compliant**: O-RAN.WG4.CUS Annex A.1.2  
✅ **Robust Fallback**: Automatic fallback for unsupported cases  
✅ **Memory Efficient**: Aligned arrays and masked operations  
✅ **Network Ready**: Big-endian byte order maintained  

This implementation is the **optimal choice** for Intel Xeon processors with AVX512 support, providing the fastest compression/decompression performance for Split 7.2 Open Fronthaul applications.

