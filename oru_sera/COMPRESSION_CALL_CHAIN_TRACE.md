# Compression Call Chain Trace

This document traces the call chain for IQ compression in the downlink path, from the upper PHY resource grid generation to the final Ethernet packet transmission.

## Overview

The compression call chain flows from:
1. **Upper PHY** → Generates resource grid with IQ samples
2. **Lower PHY** → Processes resource grid and notifies downlink handler
3. **OFH Downlink Handler** → Receives resource grid and initiates data flow
4. **Data Flow** → Extracts IQ samples and builds OFH messages
5. **Message Builder** → Serializes headers and compresses IQ data
6. **Compressor** → Performs BFP compression using AVX512/AVX2/NEON
7. **Ethernet Builder** → Wraps compressed data in eCPRI and Ethernet frames

---

## Call Chain Details

### 1. Upper PHY → Lower PHY

**Location**: `lib/phy/upper/downlink_processor_multi_executor_impl.cpp`

The upper PHY generates resource grids containing IQ samples for PDSCH, SSB, CSI-RS, etc. These grids are passed to the lower PHY through the `pdxch_processor_request_handler` interface.

**Key Function**:
```cpp
void downlink_processor_multi_executor_impl::process_pdsch(const pdsch_processor::pdu_t& pdu)
{
  // ... processing ...
  pdsch_proc->process(current_grid->get_writer(), pdu);
}
```

The resource grid contains IQ samples in `cbf16_t` format (Complex Brain Float 16).

---

### 2. Lower PHY → OFH Downlink Handler

**Location**: `lib/phy/lower/processors/downlink/pdxch/pdxch_processor_impl.cpp`

The lower PHY processes the resource grid and notifies the downlink handler when modulation is complete.

**Key Function**:
```49:79:lib/phy/lower/processors/downlink/pdxch/pdxch_processor_impl.cpp
void pdxch_processor_impl::handle_request(const shared_resource_grid& grid, const resource_grid_context& context)
{
  // Ignore request if the processor has stopped.
  if (stopped.load(std::memory_order_relaxed)) {
    return;
  }

  srsran_assert(notifier != nullptr, "Notifier has not been connected.");

  // Ignore grid if it is empty.
  if (grid.get_reader().is_empty()) {
    return;
  }

  // Obtain baseband buffer.
  baseband_gateway_buffer_ptr buffer = bb_buffers.get();
  if (!buffer) {
    logger.error(context.slot.sfn(), context.slot.slot_index(), "Insufficient number of buffers.");
    return;
  }

  // Try modulating the request. It can be the modulator is busy with a previous transmission.
  bool success = get_modulator(context.slot).handle_request(std::move(buffer), grid.copy(), context);

  // If there was a request with a resource grid, then notify a late event with the context of the discarded request.
  if (!success) {
    logger.error(context.slot.sfn(), context.slot.slot_index(), "The modulator is busy.");
    general_critical_tracer << instant_trace_event{
        "modulator_busy", instant_trace_event::cpu_scope::thread, instant_trace_event::event_criticality::severe};
  }
}
```

**Connection Point**: The `pdxch_processor_notifier` is connected to the OFH downlink handler through the RU implementation.

**Location**: `lib/ru/ofh/ru_ofh_impl.cpp`

The RU OFH implementation connects the downlink handler:

```74:80:lib/ru/ofh/ru_ofh_impl.cpp
  downlink_handler = ru_downlink_plane_handler_proxy([](span<std::unique_ptr<ofh::sector>> sectors_) {
    std::vector<ofh::downlink_handler*> out;
    for (const auto& sector : sectors_) {
      out.emplace_back(&sector.get()->get_transmitter().get_downlink_handler());
    }
    return out;
  }(sectors));
```

---

### 3. OFH Downlink Handler → Data Flow

**Location**: `lib/ofh/transmitter/ofh_downlink_handler_impl.cpp`

The downlink handler receives the resource grid and initiates the data flow for both control-plane and user-plane messages.

**Key Function**:
```80:141:lib/ofh/transmitter/ofh_downlink_handler_impl.cpp
void downlink_handler_impl::handle_dl_data(const resource_grid_context& context, const shared_resource_grid& grid)
{
  // Do nothing if handler is not running.
  if (!is_running.load(std::memory_order_relaxed)) {
    return;
  }

  const resource_grid_reader& reader = grid.get_reader();
  srsran_assert(reader.get_nof_ports() <= dl_eaxc.size(),
                "Number of RU ports is '{}' and must be equal or greater than the number of cell ports which is '{}'",
                dl_eaxc.size(),
                reader.get_nof_ports());

  trace_point tp = ofh_tracer.now();

  // Clear any stale buffers associated with the context slot.
  metrics_collector.update_cp_dl_lates(frame_pool_dl_cp->clear_slot(context.slot, context.sector));
  metrics_collector.update_up_dl_lates(frame_pool_dl_up->clear_slot(context.slot, context.sector));

  // Nothing to do on empty resource grids.
  if (grid.get_reader().is_empty()) {
    return;
  }

  if (window_checker.is_late(context.slot)) {
    log_conditional_warning(
        logger,
        enable_log_warnings_for_lates,
        "Sector#{}: dropped late downlink resource grid in slot '{}'. No OFH data will be transmitted for this slot",
        sector_id,
        context.slot);
    ofh_tracer << trace_event("ofh_handle_dl_late", tp);

    err_notifier.on_late_downlink_message({context.slot, sector_id});
    return;
  }

  data_flow_cplane_type_1_context cplane_context;
  cplane_context.slot         = context.slot;
  cplane_context.filter_type  = filter_index_type::standard_channel_filter;
  cplane_context.direction    = data_direction::downlink;
  cplane_context.symbol_range = tdd_config ? get_active_tdd_dl_symbols(*tdd_config, context.slot.slot_index(), cp)
                                           : ofdm_symbol_range(0, reader.get_nof_symbols());

  data_flow_uplane_resource_grid_context uplane_context;
  uplane_context.slot         = context.slot;
  uplane_context.sector       = context.sector;
  uplane_context.symbol_range = cplane_context.symbol_range;

  for (unsigned cell_port_id = 0, e = reader.get_nof_ports(); cell_port_id != e; ++cell_port_id) {
    cplane_context.eaxc = dl_eaxc[cell_port_id];
    // Control-Plane data flow.
    data_flow_cplane->enqueue_section_type_1_message(cplane_context);

    // User-Plane data flow.
    uplane_context.port = cell_port_id;
    uplane_context.eaxc = dl_eaxc[cell_port_id];
    data_flow_uplane->enqueue_section_type_1_message(uplane_context, grid);
  }

  ofh_tracer << trace_event("ofh_handle_downlink", tp);
}
```

**Key Call**: `data_flow_uplane->enqueue_section_type_1_message(uplane_context, grid);`

This initiates the user-plane data flow, which will extract IQ samples from the resource grid and compress them.

---

### 4. Data Flow → Message Builder

**Location**: `lib/ofh/transmitter/ofh_data_flow_uplane_downlink_data_impl.cpp`

The data flow extracts IQ samples from the resource grid and prepares them for compression.

**Key Function**:
```107:187:lib/ofh/transmitter/ofh_data_flow_uplane_downlink_data_impl.cpp
void data_flow_uplane_downlink_data_impl::enqueue_section_type_1_message_symbol_burst(
    const data_flow_uplane_resource_grid_context& context,
    const shared_resource_grid&                   grid)
{
  const resource_grid_reader& reader = grid.get_reader();

  // Temporary buffer used to store IQ data when the RU operating bandwidth is not the same to the cell bandwidth.
  std::array<cbf16_t, MAX_NOF_PRBS * NOF_SUBCARRIERS_PER_RB> temp_buffer;
  if (SRSRAN_UNLIKELY(ru_nof_prbs * NOF_SUBCARRIERS_PER_RB != reader.get_nof_subc())) {
    // Zero out the elements that won't be filled after reading the resource grid.
    std::fill(temp_buffer.begin() + reader.get_nof_subc(), temp_buffer.end(), 0);
  }

  units::bytes headers_size = eth_builder->get_header_size() +
                              ecpri_builder->get_header_size(ecpri::message_type::iq_data) +
                              up_builder->get_header_size(compr_params);

  // Iterate over all the symbols.
  for (unsigned symbol_id = context.symbol_range.start(), symbol_end = context.symbol_range.length();
       symbol_id != symbol_end;
       ++symbol_id) {
    slot_symbol_point symbol_point(context.slot, symbol_id, nof_symbols_per_slot);

    span<const cbf16_t> iq_data;
    if (SRSRAN_LIKELY(ru_nof_prbs * NOF_SUBCARRIERS_PER_RB == reader.get_nof_subc())) {
      iq_data = reader.get_view(context.port, symbol_id);
    } else {
      span<cbf16_t> temp_iq_data(temp_buffer.data(), ru_nof_prbs * NOF_SUBCARRIERS_PER_RB);
      reader.get(temp_iq_data.first(reader.get_nof_subc()), context.port, symbol_id, 0);
      iq_data = temp_iq_data;
    }

    // Split the data into multiple messages when it does not fit into a single one.
    ofh_uplane_fragment_size_calculator prb_fragment_calculator(0, ru_nof_prbs, compr_params);
    bool                                is_last_fragment   = false;
    unsigned                            fragment_start_prb = 0U;
    unsigned                            fragment_nof_prbs  = 0U;
    do {
      trace_point pool_access_tp = ofh_tracer.now();
      auto        scoped_buffer  = frame_pool->reserve(symbol_point);
      ofh_tracer << trace_event("ofh_uplane_pool_access", pool_access_tp);

      if (SRSRAN_UNLIKELY(!scoped_buffer)) {
        logger.warning(
            "Sector#{}: not enough space in the buffer pool to create a downlink User-Plane message for slot "
            "'{}' and eAxC '{}', symbol_id '{}'",
            sector_id,
            context.slot,
            context.eaxc,
            symbol_id);
        return;
      }
      span<uint8_t> data = scoped_buffer->get_buffer();

      is_last_fragment = prb_fragment_calculator.calculate_fragment_size(
          fragment_start_prb, fragment_nof_prbs, data.size() - headers_size.value());

      // Skip frame buffers so small that cannot carry one PRB.
      if (SRSRAN_UNLIKELY(fragment_nof_prbs == 0)) {
        logger.warning("Sector#{}: skipped frame buffer as it cannot store data for a single PRB, required buffer size "
                       "is '{}' bytes",
                       sector_id,
                       data.size());

        continue;
      }

      ofh_tracer << instant_trace_event{"ofh_uplane_symbol", instant_trace_event::cpu_scope::thread};

      uplane_message_params up_params =
          generate_dl_ofh_user_parameters(context.slot, symbol_id, fragment_start_prb, fragment_nof_prbs, compr_params);

      unsigned used_size = enqueue_section_type_1_message_symbol(
          iq_data.subspan(fragment_start_prb * NOF_SUBCARRIERS_PER_RB, fragment_nof_prbs * NOF_SUBCARRIERS_PER_RB),
          up_params,
          context.eaxc,
          data);
      scoped_buffer->set_size(used_size);
    } while (!is_last_fragment);
  }
}
```

**Key Points**:
- IQ data is extracted as `span<const cbf16_t>` from the resource grid
- Data is split into fragments if it doesn't fit in a single Ethernet frame
- Each fragment is passed to `enqueue_section_type_1_message_symbol()`

**Next Call**:
```189:226:lib/ofh/transmitter/ofh_data_flow_uplane_downlink_data_impl.cpp
unsigned data_flow_uplane_downlink_data_impl::enqueue_section_type_1_message_symbol(span<const cbf16_t> iq_symbol_data,
                                                                                    const uplane_message_params& params,
                                                                                    unsigned                     eaxc,
                                                                                    span<uint8_t>                buffer)
{
  // Build the Open Fronthaul data message. Only one port supported.
  units::bytes  ether_header_size = eth_builder->get_header_size();
  units::bytes  ecpri_hdr_size    = ecpri_builder->get_header_size(ecpri::message_type::iq_data);
  units::bytes  offset            = ether_header_size + ecpri_hdr_size;
  span<uint8_t> ofh_buffer        = span<uint8_t>(buffer).last(buffer.size() - offset.value());
  unsigned      bytes_written     = up_builder->build_message(ofh_buffer, iq_symbol_data, params);

  // Add eCPRI header. Create a subspan with the payload that skips the Ethernet header.
  span<uint8_t> ecpri_buffer =
      span<uint8_t>(buffer).subspan(ether_header_size.value(), ecpri_hdr_size.value() + bytes_written);
  ecpri_builder->build_data_packet(ecpri_buffer, generate_ecpri_data_parameters(up_seq_gen.generate(eaxc), eaxc));

  // Update the number of bytes written.
  bytes_written += ecpri_hdr_size.value();

  // Add Ethernet header.
  span<uint8_t> eth_buffer = span<uint8_t>(buffer).first(ether_header_size.value() + bytes_written);
  eth_builder->build_frame(eth_buffer);

  if (SRSRAN_UNLIKELY(logger.debug.enabled())) {
    logger.debug("Sector#{}: packing a downlink User-Plane message for slot '{}' and eAxC '{}', symbol_id '{}', PRB "
                 "range '{}:{}', size '{}' bytes",
                 sector_id,
                 params.slot,
                 eaxc,
                 params.symbol_id,
                 params.start_prb,
                 params.nof_prb,
                 eth_buffer.size());
  }

  return eth_buffer.size();
}
```

**Key Call**: `up_builder->build_message(ofh_buffer, iq_symbol_data, params);`

This calls the message builder to serialize the OFH message and compress the IQ data.

---

### 5. Message Builder → Compressor

**Location**: `lib/ofh/serdes/ofh_uplane_message_builder_impl.cpp`

The message builder serializes the OFH headers and then compresses the IQ data.

**Key Function**:
```144:161:lib/ofh/serdes/ofh_uplane_message_builder_impl.cpp
unsigned uplane_message_builder_impl::build_message(span<uint8_t>                buffer,
                                                    span<const cbf16_t>          iq_data,
                                                    const uplane_message_params& params)
{
  srsran_assert(params.sect_type == section_type::type_1, "Unsupported section type");
  srsran_assert(iq_data.size() == params.nof_prb * NOF_SUBCARRIERS_PER_RB,
                "The number of PRBs derived from the IQ samples is '{}' and requested number of PRBs to pack is '{}'",
                iq_data.size() / NOF_SUBCARRIERS_PER_RB,
                params.nof_prb);

  network_order_binary_serializer serializer(buffer.data());

  build_radio_app_header(serializer, params);
  build_section1_header(serializer, params);
  serialize_iq_data(serializer, iq_data, params.nof_prb, params.compression_params);

  return serializer.get_offset();
}
```

**Key Call**: `serialize_iq_data(serializer, iq_data, params.nof_prb, params.compression_params);`

**Compression Function**:
```111:142:lib/ofh/serdes/ofh_uplane_message_builder_impl.cpp
void uplane_message_builder_impl::serialize_iq_data(network_order_binary_serializer& serializer,
                                                    span<const cbf16_t>              iq_data,
                                                    unsigned                         nof_prbs,
                                                    const ru_compression_params&     compr_params)
{
  if (SRSRAN_UNLIKELY(logger.debug.enabled())) {
    logger.debug("Packing '{}' PRBs inside a User-Plane message using compression type '{}' and bitwidth '{}'",
                 nof_prbs,
                 to_string(compr_params.type),
                 compr_params.data_width);
  }

  // Serialize compression header.
  serialize_compression_header(serializer, compr_params);

  if (ud_comp_length_support) {
    // The udCompLen field shall only be present for the following compression methods:
    // "BFP + selective RE sending" or "Modulation compression + selective RE sending".
    if (compr_params.type == compression_type::bfp_selective || compr_params.type == compression_type::mod_selective) {
      units::bits prb_iq_data_size_bits(NOF_SUBCARRIERS_PER_RB * 2U * compr_params.data_width);
      uint16_t    udCompLen = prb_iq_data_size_bits.round_up_to_bytes().value();
      serializer.write(udCompLen);
    }
  }

  // Size in bytes of one compressed PRB using the given compression parameters.
  units::bytes prb_size           = get_compressed_prb_size(compr_params);
  units::bytes bytes_to_serialize = prb_size * nof_prbs;

  span<uint8_t> compr_prb_view = serializer.get_view_and_advance(bytes_to_serialize.value());
  compressor.compress(compr_prb_view, iq_data, compr_params);
}
```

**Key Call**: `compressor.compress(compr_prb_view, iq_data, compr_params);`

This is where compression is invoked! The `compressor` is an `iq_compressor_selector` that routes to the appropriate compressor based on compression type.

---

### 6. Compressor Selector → AVX512 BFP Compressor

**Location**: `lib/ofh/compression/iq_compressor_selector.cpp`

The compressor selector routes the compression request to the appropriate compressor based on the compression type.

**Key Function**:
```41:47:lib/ofh/compression/iq_compressor_selector.cpp
void iq_compressor_selector::compress(span<uint8_t>                buffer,
                                      span<const cbf16_t>          iq_data,
                                      const ru_compression_params& params)
{
  auto& compressor = compressors[static_cast<unsigned>(params.type)];
  compressor->compress(buffer, iq_data, params);
}
```

**Compressor Selection**: The compressor is selected at runtime based on:
1. **Compression Type**: `params.type` (e.g., `compression_type::BFP`)
2. **CPU Features**: AVX512, AVX2, or NEON support
3. **Implementation Type**: "avx512", "avx2", "neon", or "auto"

**Location**: `lib/ofh/compression/compression_factory.cpp`

The factory creates the appropriate compressor:

```cpp
std::unique_ptr<iq_compressor>
srsran::ofh::create_iq_compressor(compression_type type, srslog::basic_logger& logger, const std::string& impl_type)
{
  switch (type) {
    case compression_type::BFP:
#ifdef __x86_64__
      {
        bool supports_avx2 = cpu_supports_feature(cpu_feature::avx2);
        bool supports_avx512 =
            cpu_supports_feature(cpu_feature::avx512f) && cpu_supports_feature(cpu_feature::avx512vl) &&
            cpu_supports_feature(cpu_feature::avx512bw) && cpu_supports_feature(cpu_feature::avx512vbmi);
        if (((impl_type == "avx512") || (impl_type == "auto")) && supports_avx512) {
          return std::make_unique<iq_compression_bfp_avx512>(logger);
        }
        if (((impl_type == "avx2") || (impl_type == "auto")) && supports_avx2) {
          return std::make_unique<iq_compression_bfp_avx2>(logger);
        }
      }
#endif
#ifdef __ARM_NEON
      if ((impl_type == "neon") || (impl_type == "auto")) {
        return std::make_unique<iq_compression_bfp_neon>(logger);
      }
#endif // __ARM_NEON
      return std::make_unique<iq_compression_bfp_impl>(logger);
    // ... other compression types ...
  }
}
```

---

### 7. AVX512 BFP Compressor → Compression Implementation

#### 7.1. Compression Implementation

**Location**: `lib/ofh/compression/iq_compression_bfp_avx512.cpp`

The AVX512-optimized compressor performs the actual compression using SIMD instructions.

**Key Function**:
```68:95:lib/ofh/compression/iq_compression_bfp_avx512.cpp
void iq_compression_bfp_avx512::compress(span<uint8_t>                buffer,
                                         span<const cbf16_t>          iq_data,
                                         const ru_compression_params& params)
{
  // Number of input PRBs.
  unsigned nof_prbs = (iq_data.size() / NOF_SUBCARRIERS_PER_RB);

  // If the number of PRBs is less than 4, fall back to generic implementation.
  if (nof_prbs < 4) {
    iq_compression_bfp_impl::compress(buffer, iq_data, params);
    return;
  }

  // Use AVX512-optimized compression for 4 or more PRBs.
  compress_4prbs_avx512(buffer, iq_data, params);
}
```

**AVX512-Optimized Compression**:
```97:144:lib/ofh/compression/iq_compression_bfp_avx512.cpp
void iq_compression_bfp_avx512::compress_4prbs_avx512(span<uint8_t>                buffer,
                                                       span<const cbf16_t>          iq_data,
                                                       const ru_compression_params& params)
{
  // Number of input PRBs.
  unsigned nof_prbs = (iq_data.size() / NOF_SUBCARRIERS_PER_RB);

  // Size in bytes of one compressed PRB using the given compression parameters.
  unsigned prb_size = get_compressed_prb_size(params).value();

  // Auxiliary arrays used for float to fixed point conversion of the input data.
  std::array<int16_t, NOF_SAMPLES_PER_PRB * MAX_NOF_PRBS> input_quantized;

  span<const bf16_t> float_samples_span(reinterpret_cast<const bf16_t*>(iq_data.data()), iq_data.size() * 2U);
  span<int16_t>      input_quantized_span(input_quantized.data(), float_samples_span.size());
  // Performs conversion of input brain float values to signed 16-bit integers.
  quantize_input(input_quantized_span, float_samples_span);

  // Process 4 PRBs at a time using AVX512.
  unsigned prb_idx = 0;
  for (; prb_idx + 4 <= nof_prbs; prb_idx += 4) {
    const auto* in_start_it = input_quantized.begin() + NOF_SAMPLES_PER_PRB * prb_idx;
    auto*       out_it      = &buffer[prb_idx * prb_size];

    // Compress 4 PRBs in parallel using AVX512 intrinsics.
    compress_4prbs_avx512_impl({out_it, prb_size * 4}, {in_start_it, NOF_SAMPLES_PER_PRB * 4}, params.data_width);
  }

  // Process remaining PRBs using generic implementation.
  if (prb_idx < nof_prbs) {
    for (unsigned i = prb_idx; i != nof_prbs; ++i) {
      const auto* in_start_it = input_quantized.begin() + NOF_SAMPLES_PER_PRB * i;
      auto*       out_it      = &buffer[i * prb_size];
      compress_prb_generic({out_it, prb_size}, {in_start_it, NOF_SAMPLES_PER_PRB}, params.data_width);
    }
  }
}
```

**Key Steps**:
1. **Quantize Input**: Convert `cbf16_t` → `bf16_t` → `int16_t`
2. **AVX512 Compression**: Process 4 PRBs in parallel using AVX512 intrinsics
3. **Remaining PRBs**: Use generic implementation for any remaining PRBs

#### 7.2. Phase Compensation Implementation

**Location**: `lib/phy/lower/modulation/ofdm_modulator_impl.cpp` and `lib/phy/lower/modulation/phase_compensation_lut.h`

Phase compensation is applied during OFDM modulation in the lower PHY layer, before the IQ samples reach the compression stage. This compensates for phase rotation introduced by the center frequency offset, as specified in TS38.211 Section 5.4.

**Standard Reference**: TS38.211 Section 5.4 - Modulation and Upconversion

**Phase Compensation Look-Up Table**:

The phase compensation is implemented as a look-up table (`phase_compensation_lut`) that is pre-computed at construction time:

```32:85:lib/phy/lower/modulation/phase_compensation_lut.h
/// \brief Phase compensation as per TS38.211 Section 5.4.
///
/// Implements the phase compensation for OFDM modulation and demodulation as described in TS38.211 Section 5.4. The
/// phase compensation is implemented as a look-up table populated at construction time.
class phase_compensation_lut
{
private:
  /// Stores the coefficients for every symbol in a subframe.
  static_vector<cf_t, MAX_NSYMB_PER_SLOT * get_nof_slots_per_subframe(subcarrier_spacing::kHz240)> coefficients;

public:
  /// \brief Constructs the phase compensation look-up table.
  /// \param[in] scs                 Subcarrier spacing.
  /// \param[in] cp                  Cyclic Prefix.
  /// \param[in] dft_size            DFT size.
  /// \param[in] center_frequency_Hz Center frequency in Hz.
  /// \param[in] is_tx               Set to true if the phase correction table is for transmission.
  phase_compensation_lut(subcarrier_spacing scs,
                         cyclic_prefix      cp,
                         unsigned           dft_size,
                         double             center_frequency_Hz,
                         bool               is_tx)
  {
    double sampling_rate_Hz = to_sampling_rate_Hz(scs, dft_size);
    srsran_assert(std::isnormal(sampling_rate_Hz),
                  "Invalid sampling rate from SCS {} kHz and DFT size {}.",
                  scs_to_khz(scs),
                  dft_size);

    unsigned nslot_per_subframe = get_nof_slots_per_subframe(scs);
    unsigned nsymb_per_slot     = get_nsymb_per_slot(cp);
    double   sign_two_pi        = ((is_tx) ? -1 : 1) * 2.0 * M_PI;

    // Clear coefficient list.
    coefficients.clear();

    // For each symbol in a subframe.
    for (unsigned symbol = 0, symbol_offset = 0; symbol != nslot_per_subframe * nsymb_per_slot; ++symbol) {
      // Add cyclic prefix length to the symbol offset.
      symbol_offset += cp.get_length(symbol, scs).to_samples(sampling_rate_Hz);

      // Calculate the time between the start of the subframe and the start of the symbol.
      double start_time_s = static_cast<double>(symbol_offset) / sampling_rate_Hz;

      // Calculate the phase in radians.
      double symbol_phase = sign_two_pi * center_frequency_Hz * start_time_s;

      // Calculate phase compensation.
      coefficients.emplace_back(static_cast<cf_t>(std::polar(1.0, symbol_phase)));

      // Advance the symbol size.
      symbol_offset += dft_size;
    }
  }

  /// \brief Get the phase compensation for a symbol.
  /// \param[in] symbol_index Symbol index within a subframe.
  /// \return The phase compensation coefficient for a given symbol within a subframe.
  /// \remark An assertion is triggered if the symbol index exceeds the number of symbols in a subframe.
  cf_t get_coefficient(unsigned symbol_index) const
  {
    srsran_assert(symbol_index < coefficients.size(),
                  "The symbol index within a subframe {} exceeds the number of symbols in the subframe {}.",
                  symbol_index,
                  coefficients.size());
    return coefficients[symbol_index];
  }
};
```

**Phase Compensation Formula**:

The phase compensation coefficient for each symbol is calculated as:

```
phase_compensation = e^(j × 2π × f_c × t_symbol)
```

Where:
- `f_c` = Center frequency in Hz
- `t_symbol` = Time offset from subframe start to symbol start (including cyclic prefix)
- Sign: Negative for transmission (`is_tx = true`), positive for reception

**Application in OFDM Modulator**:

Phase compensation is applied after the DFT operation in the OFDM modulator:

```58:105:lib/phy/lower/modulation/ofdm_modulator_impl.cpp
void ofdm_symbol_modulator_impl::modulate(span<cf_t>                  output,
                                          const resource_grid_reader& grid,
                                          unsigned                    port_index,
                                          unsigned                    symbol_index)
{
  // Recalculate phase compensation if the center frequency has changed.
  double center_freq_Hz = next_center_freq_Hz.load(std::memory_order::memory_order_relaxed);
  if (center_freq_Hz != current_center_freq_Hz) {
    phase_compensation_table = phase_compensation_lut(scs, cp, dft_size, center_freq_Hz, false);
    current_center_freq_Hz   = center_freq_Hz;
  }

  // Calculate number of symbols per slot.
  unsigned nsymb = get_nsymb_per_slot(cp);

  // Calculate cyclic prefix length.
  unsigned cp_len = cp.get_length(symbol_index, scs).to_samples(sampling_rate_Hz);

  // Make sure output buffer matches the symbol size.
  srsran_assert(output.size() == (cp_len + dft_size),
                "The output buffer size ({}) does not match the symbol index {} size ({}+{}={}). SCS={}kHz.",
                output.size(),
                symbol_index,
                cp_len,
                dft_size,
                cp_len + dft_size,
                scs_to_khz(scs));

  // Skip modulator if the grid is empty for the given port.
  if (grid.is_empty(port_index)) {
    srsvec::zero(output);
    return;
  }

  // Prepare lower bound frequency domain data.
  grid.get(dft->get_input().last(rg_size / 2), port_index, symbol_index % nsymb, 0);

  // Prepare upper bound frequency domain data.
  grid.get(dft->get_input().first(rg_size / 2), port_index, symbol_index % nsymb, rg_size / 2);

  // Execute DFT.
  span<const cf_t> dft_output = dft->run();

  // Get phase correction (TS138.211, Section 5.4)
  cf_t phase_compensation = phase_compensation_table.get_coefficient(symbol_index);

  // Apply scaling and phase compensation.
  srsvec::sc_prod(output.last(dft_size), dft_output, phase_compensation * scale);
```

**Key Points**:

1. **Look-Up Table**: Pre-computed for all symbols in a subframe to avoid runtime calculation overhead
2. **Dynamic Recalculation**: The LUT is recalculated if the center frequency changes
3. **Symbol-Specific**: Each symbol has a unique phase compensation coefficient based on its time offset
4. **Complex Multiplication**: Applied via `srsvec::sc_prod()` which multiplies the DFT output by the phase compensation coefficient
5. **Timing**: Applied after DFT but before adding the cyclic prefix

**Impact on Compression**:

- Phase compensation is applied **before** compression in the signal chain
- The IQ samples in the resource grid (which are later compressed) already have phase compensation applied
- The compression algorithm operates on the phase-compensated samples
- No additional phase compensation is needed in the compression path

**Configuration**:

Phase compensation is automatically handled by the lower PHY layer per TS38.211 Section 5.4. The O-RU configuration should match the phase compensation behavior as noted in the configuration file:

```yaml
# Phase compensation is automatically handled by the lower PHY layer per TS38.211 Section 5.4
# Ensure the O-RU configuration matches the phase compensation behavior.
```

---

## Summary Call Chain

```
Upper PHY (Resource Grid Generation)
  ↓
Lower PHY (pdxch_processor_impl::handle_request)
  ↓
OFH Downlink Handler (downlink_handler_impl::handle_dl_data)
  ↓
Data Flow (data_flow_uplane_downlink_data_impl::enqueue_section_type_1_message)
  ↓
Message Builder (uplane_message_builder_impl::build_message)
  ↓
IQ Compressor Selector (iq_compressor_selector::compress)
  ↓
AVX512 BFP Compressor (iq_compression_bfp_avx512::compress)
  ↓
AVX512 Implementation (compress_4prbs_avx512_impl)
  ↓
Compressed Data → Ethernet Frame → Network
```

---

## Key Data Structures

### Input Data Format
- **Type**: `span<const cbf16_t>`
- **Format**: Complex Brain Float 16 (4 bytes per sample)
- **Organization**: Sequential by subcarrier (12 subcarriers per PRB)
- **Source**: Resource grid from upper PHY

### Compression Parameters
- **Type**: `compression_type::BFP` (Block Floating Point)
- **Data Width**: Bitwidth for compressed samples (e.g., 9, 16)
- **Source**: Configuration file (`compr_method_dl`, `compr_bitwidth_dl`)

### Output Format
- **Type**: `span<uint8_t>` (compressed bytes)
- **Format**: BFP-compressed IQ samples
- **Size**: Variable based on compression parameters and number of PRBs

---

## Configuration Points

1. **Compression Type**: Set in `gnb_ru_sera_tdd_n78_50mhz_2x2.yml`
   ```yaml
   compr_method_dl: bfp
   compr_bitwidth_dl: 9
   ```

2. **Implementation Selection**: Based on CPU features and `impl_type` parameter
   - AVX512: Requires AVX512F, AVX512VL, AVX512BW, AVX512VBMI
   - AVX2: Requires AVX2
   - NEON: Requires ARM NEON
   - Generic: Fallback for unsupported architectures

3. **Compressor Creation**: `lib/ofh/transmitter/ofh_transmitter_factories.cpp`
   ```cpp
   compressors[i] = create_iq_compressor(static_cast<compression_type>(i), logger, tx_config.iq_scaling);
   ```

---

## Performance Considerations

1. **AVX512 Optimization**: Processes 4 PRBs in parallel (optimal for ≥4 PRBs)
2. **Fallback**: Uses generic implementation for <4 PRBs or unsupported CPUs
3. **Quantization**: Converts `cbf16_t` to `int16_t` before compression
4. **SIMD Width**: 512 bits (32 samples) per AVX512 register

---

## Related Documents

- [AVX512 BFP Compression Implementation](./AVX512_BFP_COMPRESSION_IMPLEMENTATION.md)
- [Compression Algorithm Used](./COMPRESSION_ALGORITHM_USED.md)
- [Split 7.2 Explained](./SPLIT_7_2_EXPLAINED.md)

