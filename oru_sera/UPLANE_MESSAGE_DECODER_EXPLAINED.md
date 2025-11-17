# OFH User Plane Message Decoder Explained

## Overview

The **User Plane Message Decoder** (`uplane_message_decoder`) is a critical component in Split 7.2 that decodes Open Fronthaul (OFH) messages received from the O-RU. It extracts compressed IQ samples, decompresses them, and prepares them for PHY layer processing.

**File**: `lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp`

---

## Purpose

The decoder processes Ethernet/eCPRI packets containing:
- **Compressed IQ samples** from the O-RU
- **Control information** (slot, symbol, PRB ranges)
- **Compression parameters** (method, bitwidth)

It outputs:
- **Decompressed IQ samples** ready for PHY processing
- **Section information** (PRB ranges, symbol indices)

---

## Message Structure

### OFH User Plane Message Format

```
┌─────────────────────────────────────────────────────────┐
│  Message Header (4 bytes)                                │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Byte 0: Direction (1 bit) + Version (3 bits) +    │ │
│  │        Filter Index (4 bits)                       │ │
│  │ Byte 1: Frame (8 bits)                            │ │
│  │ Byte 2: Subframe (4 bits) + Slot (4 bits)         │ │
│  │ Byte 3: Slot (2 bits) + Symbol (6 bits)           │ │
│  └─────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────┤
│  Section 1                                               │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Section Header (4 bytes)                           │ │
│  │ - Section ID (12 bits)                             │ │
│  │ - Flags (4 bits)                                   │ │
│  │ - Start PRB (10 bits)                              │ │
│  │ - Number of PRBs (8 bits)                          │ │
│  └─────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Compression Header (1-2 bytes)                     │ │
│  │ - Compression Type (4 bits)                         │ │
│  │ - Data Width (4 bits)                              │ │
│  │ - Reserved (8 bits) [if dynamic]                    │ │
│  └─────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Compression Length (0-2 bytes) [if needed]         │ │
│  └─────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Compressed IQ Data                                  │ │
│  │ - Block Exponents (if BFP)                          │ │
│  │ - Quantized Mantissas                               │ │
│  └─────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────┤
│  Section 2 (optional)                                    │
│  ...                                                     │
└─────────────────────────────────────────────────────────┘
```

---

## Decoding Process

### Main Decode Function

```40:55:lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp
bool uplane_message_decoder_impl::decode(uplane_message_decoder_results& results, span<const uint8_t> message)
{
  network_order_binary_deserializer deserializer(message);

  // Decode the header.
  if (!decode_header(results.params, deserializer)) {
    return false;
  }

  // Decode the sections from the message.
  if (!decode_all_sections(results, deserializer)) {
    return false;
  }

  return true;
}
```

**Steps**:
1. Create binary deserializer for network byte order
2. Decode message header (slot, symbol, filter index)
3. Decode all sections (PRB ranges, compression, IQ data)

---

## Header Decoding

### Header Structure

The header contains timing and filtering information:

```101:151:lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp
bool uplane_message_decoder_impl::decode_header(uplane_message_params&             params,
                                                network_order_binary_deserializer& deserializer)
{
  if (SRSRAN_UNLIKELY(deserializer.remaining_bytes() < NOF_BYTES_UP_HEADER)) {
    logger.info("Sector#{}: dropped received Open Fronthaul message as its size is '{}' bytes and it is smaller than "
                "the message header size",
                sector_id,
                deserializer.remaining_bytes());

    return false;
  }

  uint8_t value       = deserializer.read<uint8_t>();
  params.direction    = static_cast<data_direction>(value >> 7);
  uint8_t version     = (value >> 4) & 7;
  params.filter_index = to_filter_index_type(value & 0xf);

  uint8_t  frame             = deserializer.read<uint8_t>();
  uint8_t  subframe_and_slot = deserializer.read<uint8_t>();
  uint8_t  subframe          = subframe_and_slot >> 4;
  unsigned slot_id           = 0;
  slot_id |= (subframe_and_slot & 0x0f) << 2;

  uint8_t slot_and_symbol = deserializer.read<uint8_t>();
  params.symbol_id        = slot_and_symbol & 0x3f;
  slot_id |= slot_and_symbol >> 6;

  // No need to check the frame property, as its range is [0,256), and the slot_point frame range is [0,1024).

  // Check the subframe property.
  if (SRSRAN_UNLIKELY(subframe >= NOF_SUBFRAMES_PER_FRAME)) {
    logger.info("Sector#{}: dropped received Open Fronthaul message as the decoded subframe property '{}' is invalid",
                sector_id,
                subframe);

    return false;
  }

  // Check the slot property.
  if (SRSRAN_UNLIKELY(slot_id >= slot_point(scs, 0).nof_slots_per_subframe())) {
    logger.info("Sector#{}: dropped received Open Fronthaul message as the decoded slot property '{}' is invalid",
                sector_id,
                slot_id);

    return false;
  }

  params.slot = slot_point(to_numerology_value(scs), frame, subframe, slot_id);

  return is_header_valid(params, logger, sector_id, nof_symbols, version);
}
```

**Header Fields**:
- **Byte 0**: 
  - Bit 7: Direction (uplink/downlink)
  - Bits 4-6: Version
  - Bits 0-3: Filter Index
- **Byte 1**: Frame number (0-255)
- **Byte 2**: 
  - Bits 4-7: Subframe (0-9)
  - Bits 0-3: Slot (partial)
- **Byte 3**: 
  - Bits 6-7: Slot (partial)
  - Bits 0-5: Symbol ID (0-63)

**Validation**:
- Checks direction is uplink
- Verifies version matches supported version
- Validates filter index is not reserved
- Ensures symbol index is within range

---

## Section Decoding

### Section Structure

Each section contains:
1. **Section Header**: PRB range information
2. **Compression Header**: Compression method and parameters
3. **Compression Length**: Optional length field
4. **IQ Data**: Compressed IQ samples

### Decode Section Process

```249:286:lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp
uplane_message_decoder_impl::decoded_section_status
uplane_message_decoder_impl::decode_section(uplane_message_decoder_results&    results,
                                            network_order_binary_deserializer& deserializer)
{
  // Add a section to the results.
  decoder_uplane_section_params decoder_ofh_up_section;

  decoded_section_status status = decode_section_header(decoder_ofh_up_section, deserializer);

  if (status != decoded_section_status::ok) {
    return status;
  }

  status = decode_compression_header(decoder_ofh_up_section, deserializer);
  if (status != decoded_section_status::ok) {
    return status;
  }

  status = decode_compression_length(decoder_ofh_up_section, deserializer, decoder_ofh_up_section.ud_comp_hdr);
  if (status != decoded_section_status::ok) {
    return status;
  }

  // Check the message contains the required IQ data.
  if (!check_iq_data_size(
          decoder_ofh_up_section.nof_prbs, deserializer, decoder_ofh_up_section.ud_comp_hdr, logger, sector_id)) {
    return decoded_section_status::incomplete;
  }

  // Add new section.
  auto& section = results.sections.emplace_back();
  fill_results_from_decoder_section(section, decoder_ofh_up_section);

  // Decode the IQ data.
  decode_iq_data(section, deserializer, section.ud_comp_hdr);

  return decoded_section_status::ok;
}
```

### Section Header Decoding

```288:322:lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp
uplane_message_decoder_impl::decoded_section_status
uplane_message_decoder_impl::decode_section_header(decoder_uplane_section_params&     results,
                                                   network_order_binary_deserializer& deserializer)
{
  if (SRSRAN_UNLIKELY(deserializer.remaining_bytes() < SECTION_ID_HEADER_NO_COMPRESSION_SIZE)) {
    logger.info(
        "Sector#{}: received Open Fronthaul message size is '{}' bytes and is smaller than the section header size",
        sector_id,
        deserializer.remaining_bytes());

    return decoded_section_status::incomplete;
  }

  results.section_id = 0;
  results.section_id |= unsigned(deserializer.read<uint8_t>()) << 4;
  uint8_t section_and_rest = deserializer.read<uint8_t>();
  results.section_id |= section_and_rest >> 4;
  results.is_every_rb_used          = ((section_and_rest >> 3) & 1U) == 0;
  results.use_current_symbol_number = ((section_and_rest >> 2) & 1U) == 0;

  unsigned& start_prb = results.start_prb;
  start_prb           = 0;
  start_prb |= unsigned(section_and_rest & 0x03) << 8;
  start_prb |= unsigned(deserializer.read<uint8_t>());

  unsigned& nof_prb = results.nof_prbs;
  nof_prb           = deserializer.read<uint8_t>();
  if (nof_prb == 0) {
    nof_prb = ru_nof_prbs;
    // Ignore received value and treat as 0 according to O-RAN.WG4.CUS.0-R003-v11.00 document section 8.3.3.12.
    start_prb = 0;
  }

  return decoded_section_status::ok;
}
```

**Section Header Fields**:
- **Section ID** (12 bits): Identifies the section
- **is_every_rb_used** (1 bit): Flag indicating if all RBs are used
- **use_current_symbol_number** (1 bit): Symbol number increment flag
- **Start PRB** (10 bits): Starting PRB index
- **Number of PRBs** (8 bits): Number of PRBs (0 = all PRBs)

---

## Compression Header Decoding

### Static Compression (Default)

When using static compression headers (configured in your setup with `enable_ul_static_compr_hdr: true`), the compression parameters are known from configuration and not included in each message.

### Dynamic Compression

When using dynamic compression, the compression header is decoded from the message:

```29:62:lib/ofh/serdes/ofh_uplane_message_decoder_dynamic_compression_impl.cpp
uplane_message_decoder_impl::decoded_section_status
uplane_message_decoder_dynamic_compression_impl::decode_compression_header(
    decoder_uplane_section_params&     results,
    network_order_binary_deserializer& deserializer)
{
  if (SRSRAN_UNLIKELY(deserializer.remaining_bytes() < 2 * sizeof(uint8_t))) {
    logger.info("Sector#{}: received an Open Fronthaul packet with size of '{}' bytes that is smaller than the user "
                "data compression header length",
                sector_id,
                deserializer.remaining_bytes());

    return uplane_message_decoder_impl::decoded_section_status::incomplete;
  }

  uint8_t value            = deserializer.read<uint8_t>();
  results.ud_comp_hdr.type = to_compression_type(value & 0x0f);

  // Consider a reserved value as malformed message.
  if (SRSRAN_UNLIKELY(results.ud_comp_hdr.type == compression_type::reserved)) {
    logger.info("Sector#{}: detected malformed Open Fronthaul message as the decoded compression type '{}' is invalid",
                sector_id,
                value & 0x0f);

    return uplane_message_decoder_impl::decoded_section_status::malformed;
  }

  unsigned data_width            = value >> 4U;
  results.ud_comp_hdr.data_width = (data_width == 0) ? MAX_IQ_WIDTH : data_width;

  // Advance the reserved byte.
  deserializer.advance(1U);

  return uplane_message_decoder_impl::decoded_section_status::ok;
}
```

**Compression Header Fields**:
- **Compression Type** (4 bits): BFP, block_scaling, mu_law, etc.
- **Data Width** (4 bits): Bitwidth for compression (0 = max width)
- **Reserved** (8 bits): Reserved field

---

## IQ Data Decoding and Decompression

### Decode IQ Data

```354:370:lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp
void uplane_message_decoder_impl::decode_iq_data(uplane_section_params&             results,
                                                 network_order_binary_deserializer& deserializer,
                                                 const ru_compression_params&       compression_params)
{
  units::bits prb_iq_data_size_bits(NOF_SUBCARRIERS_PER_RB * 2 * compression_params.data_width);

  // udCompParam field is not present when compression type is none or modulation.
  if (is_compression_param_present(compression_params.type)) {
    prb_iq_data_size_bits += units::bits(8);
  }
  span<const uint8_t> compressed_data =
      deserializer.get_view_and_advance(results.nof_prbs * prb_iq_data_size_bits.round_up_to_bytes().value());

  // Decompress the samples.
  results.iq_samples.resize(results.nof_prbs * NOF_SUBCARRIERS_PER_RB);
  decompressor->decompress(results.iq_samples, compressed_data, compression_params);
}
```

**Process**:
1. Calculate expected compressed data size based on:
   - Number of PRBs
   - Number of subcarriers per PRB (12)
   - Compression bitwidth
   - Optional compression parameter byte
2. Extract compressed data from message
3. Resize output buffer for decompressed IQ samples
4. Call decompressor to convert compressed data to IQ samples

### Decompression

The decompressor (`iq_decompressor`) handles the actual decompression:

- **BFP (Block Floating Point)**: 
  - Reads block exponents
  - Reconstructs mantissas
  - Converts to floating-point IQ samples
- **Other methods**: block_scaling, mu_law, modulation

**Output**: Decompressed IQ samples in `cbf16_t` format (16-bit brain floating point)

---

## Decoding All Sections

### Multiple Sections

A single message can contain multiple sections (different PRB ranges):

```153:198:lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp
bool uplane_message_decoder_impl::decode_all_sections(uplane_message_decoder_results&    results,
                                                      network_order_binary_deserializer& deserializer)
{
  // Decode sections while the message has bytes remaining.
  while (deserializer.remaining_bytes()) {
    // Try to decode section.
    decoded_section_status status = decode_section(results, deserializer);

    // Incomplete sections force the exit of the loop.
    if (SRSRAN_UNLIKELY(status == decoded_section_status::incomplete)) {
      break;
    }

    if (SRSRAN_UNLIKELY(status == decoded_section_status::malformed)) {
      logger.info("Sector#{}: dropped received Open Fronthaul message as a malformed section was decoded for slot '{}' "
                  "and symbol '{}'",
                  sector_id,
                  results.params.slot,
                  results.params.symbol_id);

      return false;
    }

    if (SRSRAN_UNLIKELY(results.sections.full())) {
      logger.info("Sector#{}: dropped received Open Fronthaul message as this deserializer only supports '{}' section "
                  "for slot '{}' and symbol '{}'",
                  sector_id,
                  MAX_NOF_SUPPORTED_SECTIONS,
                  results.params.slot,
                  results.params.symbol_id);

      return false;
    }
  }

  bool is_result_valid = !results.sections.empty();
  if (SRSRAN_UNLIKELY(!is_result_valid)) {
    logger.info("Sector#{}: dropped received Open Fronthaul message as no section was decoded correctly for slot '{}' "
                "and symbol '{}'",
                sector_id,
                results.params.slot,
                results.params.symbol_id);
  }

  return is_result_valid;
}
```

**Process**:
- Loops while bytes remain in message
- Decodes each section sequentially
- Handles errors (incomplete, malformed)
- Limits number of sections (MAX_NOF_SUPPORTED_SECTIONS)
- Returns false if no valid sections decoded

---

## Validation and Error Handling

### Header Validation

```57:99:lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp
/// Checks the Open Fronthaul User-Plane header and returns true on success, otherwise false.
static bool is_header_valid(const uplane_message_params& params,
                            srslog::basic_logger&        logger,
                            unsigned                     sector_id,
                            unsigned                     nof_symbols,
                            unsigned                     version)
{
  if (SRSRAN_UNLIKELY(params.direction != data_direction::uplink)) {
    logger.info("Sector#{}: dropped received Open Fronthaul message as it is not an uplink message", sector_id);

    return false;
  }

  if (SRSRAN_UNLIKELY(version != OFH_PAYLOAD_VERSION)) {
    logger.info("Sector#{}: dropped received Open Fronthaul message as its payload version is '{}' but only version "
                "'{}' is supported",
                sector_id,
                version,
                OFH_PAYLOAD_VERSION);

    return false;
  }

  if (SRSRAN_UNLIKELY(params.filter_index == filter_index_type::reserved)) {
    logger.info("Sector#{}: dropped received Open Fronthaul message as its filter index value is reserved '{}'",
                sector_id,
                fmt::underlying(params.filter_index));

    return false;
  }

  if (SRSRAN_UNLIKELY(params.symbol_id >= nof_symbols)) {
    logger.info("Sector#{}: dropped received Open Fronthaul message as its symbol index is '{}' and this decoder "
                "supports a maximum of '{}' symbols",
                sector_id,
                params.symbol_id,
                nof_symbols);

    return false;
  }

  return true;
}
```

**Validation Checks**:
- Direction must be uplink
- Version must match supported version
- Filter index must not be reserved
- Symbol index must be within valid range

### IQ Data Size Validation

```222:247:lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp
static bool check_iq_data_size(unsigned                           nof_prb,
                               network_order_binary_deserializer& deserializer,
                               const ru_compression_params&       compression_params,
                               srslog::basic_logger&              logger,
                               unsigned                           sector_id)
{
  units::bits prb_iq_data_size(
      units::bits(NOF_SUBCARRIERS_PER_RB * 2 * compression_params.data_width).round_up_to_bytes().value());

  // Add one byte when the udCompParam is present.
  if (is_compression_param_present(compression_params.type)) {
    prb_iq_data_size = prb_iq_data_size + units::bytes(1);
  }

  if (SRSRAN_UNLIKELY(deserializer.remaining_bytes() < prb_iq_data_size.value() * nof_prb)) {
    logger.info("Sector#{}: received Open Fronthaul message size is '{}' bytes and it is smaller than the expected IQ "
                "samples size of '{}'",
                sector_id,
                deserializer.remaining_bytes(),
                prb_iq_data_size.value() * nof_prb);

    return false;
  }

  return true;
}
```

**Validation**:
- Calculates expected compressed data size
- Checks message has enough bytes
- Accounts for compression parameter byte if present

---

## Output Structure

### Decoder Results

The decoder populates `uplane_message_decoder_results`:

```cpp
struct uplane_message_decoder_results {
  uplane_message_params params;           // Header info (slot, symbol, filter)
  static_vector<uplane_section_params, MAX_NOF_SUPPORTED_SECTIONS> sections;  // Decoded sections
};
```

**Section Parameters**:
- `section_id`: Section identifier
- `start_prb`: Starting PRB index
- `nof_prbs`: Number of PRBs
- `iq_samples`: Decompressed IQ samples (span<cbf16_t>)
- `ud_comp_hdr`: Compression header parameters
- Flags: `is_every_rb_used`, `use_current_symbol_number`

---

## Integration with Uplink Processing

### Usage Flow

```
Ethernet Packet Received
    ↓
eCPRI Decoder
    ↓
OFH Message Decoder
    ↓ (decode())
uplane_message_decoder_results
    ↓
Resource Grid Writer
    ↓ (write_to_resource_grid())
OFDM Symbol Buffer
    ↓
Lower PHY Uplink Processor
```

**Key Integration Points**:
- **Receiver**: `lib/ofh/receiver/ofh_data_flow_uplane_uplink_data_impl.cpp`
  - Calls `uplane_decoder->decode()`
  - Validates filter index
  - Writes to resource grid
- **Resource Grid Writer**: `lib/ofh/receiver/ofh_uplane_rx_symbol_data_flow_writer.cpp`
  - Takes decoded sections
  - Writes IQ samples to resource grid
  - Notifies symbol availability

---

## Configuration Impact

### Your Configuration

From `gnb_ru_sera_tdd_n78_50mhz_2x2.yml`:

```yaml
ru_ofh:
  compr_method_ul: bfp
  compr_bitwidth_ul: 9
  enable_ul_static_compr_hdr: true
```

**Impact on Decoder**:
- **Static Compression**: Compression header not in message (from config)
- **BFP Method**: Uses Block Floating Point decompression
- **9-bit Width**: Each IQ sample compressed to 9 bits
- **Compression Ratio**: ~50% reduction vs uncompressed

---

## Performance Considerations

1. **Network Byte Order**: All decoding uses network byte order (big-endian)
2. **Zero-Copy**: Uses span views where possible
3. **Validation**: Early validation to avoid unnecessary processing
4. **Error Logging**: Comprehensive logging for debugging
5. **Section Limits**: Maximum sections per message enforced

---

## Error Scenarios

### Common Errors

1. **Incomplete Message**: Not enough bytes for header/section
2. **Malformed Section**: Invalid compression type or parameters
3. **Version Mismatch**: Unsupported OFH version
4. **Invalid Symbol**: Symbol index out of range
5. **Filter Mismatch**: Filter index doesn't match expected value
6. **Too Many Sections**: Exceeds MAX_NOF_SUPPORTED_SECTIONS

### Error Handling

- All errors are logged with sector ID and context
- Messages are dropped on error
- Processing continues with next message
- Metrics track dropped messages

---

## Related Components

- **IQ Decompressor**: `lib/ofh/compression/iq_decompression_bfp_impl.cpp`
- **Resource Grid Writer**: `lib/ofh/receiver/ofh_uplane_rx_symbol_data_flow_writer.cpp`
- **Message Receiver**: `lib/ofh/receiver/ofh_message_receiver_impl.cpp`
- **Binary Deserializer**: `lib/ofh/support/network_order_binary_deserializer.h`

---

## Summary

The `uplane_message_decoder` is responsible for:
1. ✅ Parsing OFH message headers (slot, symbol, filter)
2. ✅ Decoding section headers (PRB ranges)
3. ✅ Extracting compression parameters
4. ✅ Decompressing IQ samples
5. ✅ Validating message integrity
6. ✅ Providing decompressed IQ data for PHY processing

It's a critical component in the Split 7.2 uplink path, converting compressed network packets into IQ samples ready for OFDM demodulation and channel processing.

