# Uplink Processing Source Code Trace

This document traces the complete uplink processing flow in srsRAN Project, from baseband reception to upper PHY processing.

## Overview

The uplink processing pipeline consists of two main layers:
1. **Lower PHY**: Baseband processing, OFDM demodulation, symbol extraction
2. **Upper PHY**: Channel processing (PUSCH, PUCCH, PRACH, SRS), decoding, and result notification

---

## 1. Entry Point: Baseband Reception

**File**: `lib/phy/lower/lower_phy_baseband_processor.cpp`

The uplink processing starts in the `ul_process()` method:

```163:197:lib/phy/lower/lower_phy_baseband_processor.cpp
void lower_phy_baseband_processor::ul_process()
{
  // Check if it is running, notify stop and return without enqueueing more tasks.
  if (!rx_state.on_process()) {
    return;
  }

  // Get receive buffer.
  std::unique_ptr<baseband_gateway_buffer_dynamic> rx_buffer = rx_buffers.pop_blocking();

  // Receive baseband.
  trace_point                         tp          = ru_tracer.now();
  baseband_gateway_receiver::metadata rx_metadata = receiver.receive(rx_buffer->get_writer());
  ru_tracer << trace_event("receive_baseband", tp);

  // Update last timestamp.
  last_rx_timestamp.store(rx_metadata.ts + rx_buffer->get_nof_samples(), std::memory_order_release);

  // Queue uplink buffer processing.
  report_fatal_error_if_not(uplink_executor.defer([this, ul_buffer = std::move(rx_buffer), rx_metadata]() mutable {
    trace_point ul_tp = ru_tracer.now();

    // Process UL.
    uplink_processor.process(ul_buffer->get_reader(), apply_timestamp_sfn0_ref(rx_metadata.ts));

    // Return buffer to receive.
    rx_buffers.push_blocking(std::move(ul_buffer));

    ru_tracer << trace_event("uplink_baseband", ul_tp);
  }),
                            "Failed to execute uplink processing task.");

  // Enqueue next iteration if it is running.
  report_fatal_error_if_not(rx_executor.defer([this]() { ul_process(); }), "Failed to execute receive task.");
}
```

**Key Points**:
- Receives baseband samples from `baseband_gateway_receiver`
- Processes samples asynchronously via `uplink_executor`
- Calls `uplink_processor.process()` with the received samples and timestamp

---

## 2. Lower PHY Uplink Processor

**File**: `lib/phy/lower/processors/uplink/uplink_processor_impl.cpp`

The lower PHY uplink processor handles symbol alignment, CFO compensation, and OFDM symbol extraction:

### 2.1 Main Processing Entry

```101:112:lib/phy/lower/processors/uplink/uplink_processor_impl.cpp
void lower_phy_uplink_processor_impl::process(const baseband_gateway_buffer_reader& samples,
                                              baseband_gateway_timestamp            timestamp)
{
  switch (state) {
    case fsm_states::alignment:
      process_alignment(samples, timestamp);
      break;
    case fsm_states::collecting:
      process_collecting(samples, timestamp);
      break;
  }
}
```

### 2.2 Symbol Collection and Processing

```184:298:lib/phy/lower/processors/uplink/uplink_processor_impl.cpp
void lower_phy_uplink_processor_impl::process_collecting(const baseband_gateway_buffer_reader& samples,
                                                         baseband_gateway_timestamp            timestamp)
{
  srsran_assert(notifier != nullptr, "Notifier has not been connected.");
  srsran_assert(nof_rx_ports == samples.get_nof_channels(), "Invalid number of channels.");

  // Check that the timestamp matches with the current sample timestamp.
  if ((current_symbol_timestamp + temp_buffer_write_index) != timestamp) {
    // If the timestamp does not match, the alignment has been lost.
    process_alignment(samples, timestamp);
    return;
  }

  // Get the number of input samples.
  unsigned nof_input_samples = samples.get_nof_samples();

  // Select the minimum among the remainder of samples to process and the number of samples to complete the buffer.
  unsigned nof_samples = std::min(nof_input_samples, current_symbol_size - temp_buffer_write_index);

  // For each port, concatenate samples.
  for (unsigned i_port = 0; i_port != nof_rx_ports; ++i_port) {
    // Select view of the temporary buffer.
    span<ci16_t> temp_buffer_dst = temp_buffer[i_port].subspan(temp_buffer_write_index, nof_samples);

    // Select view of the input samples.
    span<const ci16_t> temp_buffer_src = samples.get_channel_buffer(i_port).first(nof_samples);

    // Append input samples into the temporary buffer.
    srsvec::copy(temp_buffer_dst, temp_buffer_src);
  }

  // Increment the count of samples stored in the temporal buffer.
  temp_buffer_write_index += nof_samples;

  // If the temporal buffer is not full, keep state in-sync and return.
  if (temp_buffer_write_index < current_symbol_size) {
    state = fsm_states::collecting;
    return;
  }

  // View over the temporary float-based complex samples for CFO processor.
  span<cf_t> view;
  // Perform carrier frequency offset compensation.
  for (unsigned i_channel = 0; i_channel != temp_buffer.get_nof_channels(); ++i_channel) {
    // The CFO compensation is not currently supported for 16-bit complex integer samples. So, it must convert it to
    // single-precision complex floating-point samples.
    span<ci16_t> channel_buffer = temp_buffer.get_writer().get_channel_buffer(i_channel);
    view                        = temp_cf_buffer.get_view({i_channel}).subspan(0, channel_buffer.size());
    srsvec::convert(view, channel_buffer, scaling_factor_ci16_to_cf);
    cfo_processor.process(view);
    srsvec::convert(channel_buffer, view, scaling_factor_cf_to_ci16);
  }

  // Advance CFO processor number of samples.
  cfo_processor.advance(temp_buffer.get_nof_samples());

  // Process symbol by PRACH processor.
  prach_processor_baseband::symbol_context prach_context;
  prach_context.slot   = current_slot;
  prach_context.symbol = current_symbol_index;
  prach_context.sector = sector_id;
  prach_proc->get_baseband().process_symbol(temp_buffer.get_reader(), prach_context);

  // Process symbol by PUxCH processor.
  lower_phy_rx_symbol_context puxch_context;
  puxch_context.slot        = current_slot;
  puxch_context.sector      = sector_id;
  puxch_context.nof_symbols = current_symbol_index;
  bool processed            = puxch_proc->get_baseband().process_symbol(temp_buffer.get_reader(), puxch_context);

  if (processed) {
    sample_statistics<float>   avg_power;
    sample_statistics<float>   peak_power;
    lower_phy_baseband_metrics metrics;
    unsigned                   nof_channels = temp_buffer.get_nof_channels();

    uint64_t total_processed_samples = 0;
    uint64_t nof_clipped_samples     = 0;

    // Process received signal before demodulation.
    for (unsigned i_channel = 0; i_channel != nof_channels; ++i_channel) {
      // Perform signal measurements. Reuse the previous view of the float-based complex samples.
      avg_power.update(srsvec::average_power(view));
      peak_power.update(srsvec::max_abs_element(view).second);
      nof_clipped_samples += srsvec::count_if_part_abs_greater_than(view, 0.95);
      total_processed_samples += view.size();
    }

    metrics.avg_power  = avg_power.get_mean();
    metrics.peak_power = peak_power.get_max();
    metrics.clipping   = std::pair<uint64_t, uint64_t>{nof_clipped_samples, total_processed_samples};

    notifier->on_new_metrics(metrics);
  }

  // Detect half-slot boundary.
  if (current_symbol_index == (nof_symbols_per_slot / 2) - 1) {
    // Notify half slot boundary.
    lower_phy_timing_context context;
    context.slot = current_slot;
    notifier->on_half_slot(context);
  }

  // Detect full slot boundary.
  if (current_symbol_index == nof_symbols_per_slot - 1) {
    // Notify full slot boundary.
    lower_phy_timing_context context;
    context.slot = current_slot;
    notifier->on_full_slot(context);
  }

  // Process next symbol with the remainder samples.
  baseband_gateway_buffer_reader_view samples2(samples, nof_samples, nof_input_samples - nof_samples);
  process_symbol_boundary(samples2, timestamp + nof_samples);
}
```

**Key Processing Steps**:
1. **Sample Collection**: Collects samples into temporary buffer until a complete OFDM symbol is received
2. **CFO Compensation**: Converts to float, applies carrier frequency offset compensation, converts back
3. **PRACH Processing**: Processes PRACH symbols via `prach_proc->get_baseband().process_symbol()`
4. **PUxCH Processing**: Processes PUSCH/PUCCH/SRS symbols via `puxch_proc->get_baseband().process_symbol()`
5. **Metrics Collection**: Calculates average power, peak power, and clipping statistics
6. **Timing Notifications**: Notifies half-slot and full-slot boundaries

---

## 3. Upper PHY Symbol Handler

**File**: `lib/phy/upper/upper_phy_rx_symbol_handler_impl.cpp`

The upper PHY symbol handler receives demodulated symbols from the lower PHY:

```42:51:lib/phy/upper/upper_phy_rx_symbol_handler_impl.cpp
void upper_phy_rx_symbol_handler_impl::handle_rx_symbol(const upper_phy_rx_symbol_context& context,
                                                        const shared_resource_grid&        grid,
                                                        bool                               is_valid)
{
  // Get uplink processor.
  uplink_slot_processor& ul_proc = ul_processor_pool.get_slot_processor(context.slot);

  // Notify Rx symbol.
  ul_proc.handle_rx_symbol(context.symbol, is_valid);
}
```

**Key Points**:
- Receives demodulated symbols in a resource grid
- Routes to the appropriate uplink slot processor based on slot number
- Handles PRACH windows separately via `handle_rx_prach_window()`

---

## 4. Upper PHY Uplink Processor

**File**: `lib/phy/upper/uplink_processor_impl.cpp`

The upper PHY uplink processor handles channel-specific processing:

### 4.1 Symbol Processing Entry

```127:193:lib/phy/upper/uplink_processor_impl.cpp
void uplink_processor_impl::handle_rx_symbol(unsigned end_symbol_index, bool is_valid)
{
  // Try locking the slot processor. This prevents that the processor handle symbols and discards from different
  // threads concurrently.
  if (!state_machine.start_handle_rx_symbol()) {
    return;
  }

  // Unlock the slot processor when returning from this method.
  auto execute_on_exit = make_scope_exit([this]() { state_machine.finish_handle_rx_symbol(); });

  // Verify that the symbol index is in increasing order.
  if (end_symbol_index < nof_processed_symbols) {
    logger.warning(current_slot.sfn(),
                   current_slot.slot_index(),
                   "Unexpected symbol index {} is back in time, expected {}.",
                   end_symbol_index,
                   nof_processed_symbols);
    return;
  }

  // Run rate matching buffer pool only at the first symbol.
  if (nof_processed_symbols == 0) {
    rm_buffer_pool.run_slot(current_slot);
  }

  // If the OFDM symbol is not valid, discard all PDUs for the rest of the slot.
  if (!is_valid) {
    // Iterate all symbols that have not been processed yet. As the processor might be executing asynchronous all
    // discarded PDUs must call state_machine.on_create_pdu_task and state_machine.on_finish_processing_pdu for managing
    // the state machine correctly.
    for (unsigned i_symbol = nof_processed_symbols; i_symbol != MAX_NSYMB_PER_SLOT; ++i_symbol) {
      for (const auto& pdu : pdu_repository.get_pucch_pdus(i_symbol)) {
        if (state_machine.on_create_pdu_task()) {
          notify_discard_pucch(pdu);
        }
      }

      for (const auto& collection : pdu_repository.get_pucch_f1_repository(i_symbol)) {
        if (state_machine.on_create_pdu_task()) {
          notify_discard_pucch(collection);
        }
      }

      for (const auto& pdu : pdu_repository.get_pusch_pdus(i_symbol)) {
        if (state_machine.on_create_pdu_task()) {
          notify_discard_pusch(pdu);
        }
      }

      for ([[maybe_unused]] const auto& pdu : pdu_repository.get_srs_pdus(i_symbol)) {
        if (state_machine.on_create_pdu_task()) {
          state_machine.on_finish_processing_pdu();
        }
      }
    }

    return;
  }

  for (unsigned end_processed_symbol = std::min(end_symbol_index + 1, MAX_NSYMB_PER_SLOT);
       nof_processed_symbols != end_processed_symbol;
       ++nof_processed_symbols) {
    // Process the PDUs belonging to the received symbols.
    process_symbol_pdus(nof_processed_symbols);
  }
}
```

### 4.2 PDU Processing

```195:239:lib/phy/upper/uplink_processor_impl.cpp
void uplink_processor_impl::process_symbol_pdus(unsigned end_symbol_index)
{
  // Obtain all PDUs for the given end symbol index.
  span<const uplink_pdu_slot_repository::pusch_pdu> pusch_pdus = pdu_repository.get_pusch_pdus(end_symbol_index);
  span<const uplink_pdu_slot_repository::pucch_pdu> pucch_pdus = pdu_repository.get_pucch_pdus(end_symbol_index);
  span<const uplink_pdu_slot_repository_impl::pucch_f1_collection> pucch_f1_pdus =
      pdu_repository.get_pucch_f1_repository(end_symbol_index);
  span<const uplink_pdu_slot_repository::srs_pdu> srs_pdus = pdu_repository.get_srs_pdus(end_symbol_index);

  // If the phy tap is configured, send the UL symbols through the tap interface along with their associated PDUs.
  if (ul_tap) {
    // Extract PUCCH Format 1 common PDU parameters.
    static_vector<pucch_processor::format1_common_configuration, MAX_PUCCH_PDUS_PER_SLOT> pucch_f1_common_configs;
    for (const auto& pucch_f1 : pucch_f1_pdus) {
      pucch_f1_common_configs.push_back(pucch_f1.config.common_config);
    }

    // Send the symbols to the tap plugin for external analysis and processing.
    ul_tap->handle_ul_symbol(grid->get_writer(),
                             grid->get_reader(),
                             current_slot,
                             nof_processed_symbols,
                             pusch_pdus,
                             pucch_pdus,
                             pucch_f1_common_configs,
                             srs_pdus);
  }

  // Process each PDU.
  for (const auto& pdu : pucch_pdus) {
    process_pucch(pdu);
  }

  for (const auto& collection : pucch_f1_pdus) {
    process_pucch_f1(collection);
  }

  for (const auto& pdu : pusch_pdus) {
    process_pusch(pdu);
  }

  for (const auto& pdu : srs_pdus) {
    process_srs(pdu);
  }
}
```

**Key Processing Steps**:
1. **PDU Retrieval**: Gets all PDUs (PUSCH, PUCCH, SRS) for the symbol
2. **PHY Tap**: Optionally sends symbols to external tap interface for analysis
3. **Channel Processing**: Processes each channel type:
   - PUCCH (Format 0, 1, 2, 3, 4)
   - PUSCH (data and UCI)
   - SRS (sounding reference signals)

---

## 5. Channel-Specific Processing

### 5.1 PUSCH Processing

```270:336:lib/phy/upper/uplink_processor_impl.cpp
void uplink_processor_impl::process_pusch(const uplink_pdu_slot_repository::pusch_pdu& pdu)
{
  // Notify the creation of the execution task.
  if (!state_machine.on_create_pdu_task()) {
    return;
  }

  const pusch_processor::pdu_t& proc_pdu = pdu.pdu;

  // Temporal sanity check as PUSCH is only supported for data. Remove the check when the UCI is supported for PUSCH.
  srsran_assert(proc_pdu.codeword.has_value(),
                "PUSCH PDU doesn't contain data. Currently, that mode is not supported.");

  // Create buffer identifier.
  trx_buffer_identifier id(proc_pdu.rnti, pdu.harq_id);

  // Determine the number of codeblocks from the TBS and base graph.
  unsigned nof_codeblocks = ldpc::compute_nof_codeblocks(pdu.tb_size.to_bits(), proc_pdu.codeword->ldpc_base_graph);

  // Extract new data flag.
  bool new_data = proc_pdu.codeword->new_data;

  // Reserve receive buffer.
  unique_rx_buffer rm_buffer = rm_buffer_pool.reserve(current_slot, id, nof_codeblocks, new_data);

  // Skip processing if the buffer is not valid. The pool shall log the context and the reason of the failure.
  if (!rm_buffer) {
    notify_discard_pusch(pdu);
    return;
  }

  // Retrieves transport block data and starts PUSCH processing.
  auto data = rx_payload_pool.acquire_payload_buffer(pdu.tb_size);
  if (data.empty()) {
    logger.warning(pdu.pdu.slot.sfn(),
                   pdu.pdu.slot.slot_index(),
                   "UL rnti={} h_id={}: insufficient available payload data in the buffer pool for TB of size {}",
                   pdu.pdu.rnti,
                   pdu.harq_id,
                   pdu.tb_size);
    notify_discard_pusch(pdu);
    return;
  }

  // Try to enqueue asynchronous processing.
  bool success = task_executors.pusch_executor.defer([this, data, rm_buffer2 = std::move(rm_buffer), &pdu]() mutable {
    // Select and configure notifier adaptor.
    // Assume that count_pusch_adaptors will not exceed MAX_PUSCH_PDUS_PER_SLOT.
    unsigned                         notifier_adaptor_id = count_pusch_adaptors.fetch_add(1, std::memory_order_acq_rel);
    pusch_processor_result_notifier& processor_notifier  = pusch_adaptors[notifier_adaptor_id].configure(
        notifier, to_rnti(pdu.pdu.rnti), pdu.pdu.slot, to_harq_id(pdu.harq_id), data, [this]() {
          state_machine.on_finish_processing_pdu();
        });

    trace_point tp = l1_ul_tracer.now();

    pusch_proc->process(data, std::move(rm_buffer2), processor_notifier, grid->get_reader(), pdu.pdu);

    l1_ul_tracer << trace_event("process_pusch", tp);
  });

  // Report the execution failure.
  if (!success) {
    logger.warning(pdu.pdu.slot.sfn(), pdu.pdu.slot.slot_index(), "Failed to execute PUSCH. Ignoring processing.");
    notify_discard_pusch(pdu);
  }
}
```

**PUSCH Processing Steps**:
1. Validates PDU and reserves rate matching buffer
2. Acquires payload buffer for transport block
3. Asynchronously processes via `pusch_executor`:
   - Demodulation
   - Rate dematching
   - LDPC decoding
   - CRC checking
4. Notifies results via `processor_notifier`

### 5.2 PUCCH Processing

```338:394:lib/phy/upper/uplink_processor_impl.cpp
void uplink_processor_impl::process_pucch(const uplink_pdu_slot_repository::pucch_pdu& pdu)
{
  // Notify the creation of the execution task.
  if (!state_machine.on_create_pdu_task()) {
    return;
  }

  bool success = task_executors.pucch_executor.defer([this, &pdu]() {
    trace_point tp = l1_ul_tracer.now();

    pucch_processor_result proc_result;
    // Process the PUCCH.
    switch (pdu.context.format) {
      case pucch_format::FORMAT_0: {
        const auto& format0 = std::get<pucch_processor::format0_configuration>(pdu.config);
        proc_result         = pucch_proc->process(grid->get_reader(), format0);
        l1_ul_tracer << trace_event("pucch0", tp);
      } break;
      case pucch_format::FORMAT_1:
        // Do nothing.
        break;
      case pucch_format::FORMAT_2: {
        const auto& format2 = std::get<pucch_processor::format2_configuration>(pdu.config);
        proc_result         = pucch_proc->process(grid->get_reader(), format2);
        l1_ul_tracer << trace_event("pucch2", tp);
      } break;
      case pucch_format::FORMAT_3: {
        const auto& format3 = std::get<pucch_processor::format3_configuration>(pdu.config);
        proc_result         = pucch_proc->process(grid->get_reader(), format3);
        l1_ul_tracer << trace_event("pucch3", tp);
      } break;
      case pucch_format::FORMAT_4: {
        const auto& format4 = std::get<pucch_processor::format4_configuration>(pdu.config);
        proc_result         = pucch_proc->process(grid->get_reader(), format4);
        l1_ul_tracer << trace_event("pucch4", tp);
      } break;
      default:
        srsran_assert(0, "Invalid PUCCH format={}", fmt::underlying(pdu.context.format));
    }

    // Write the results.
    ul_pucch_results result;
    result.context          = pdu.context;
    result.processor_result = proc_result;

    // Notify the PUCCH results.
    notifier.on_new_pucch_results(result);
    state_machine.on_finish_processing_pdu();
  });

  // Report failed execution.
  if (!success) {
    logger.warning(
        pdu.context.slot.sfn(), pdu.context.slot.slot_index(), "Failed to execute PUCCH. Ignoring processing.");
    notify_discard_pucch(pdu);
  }
}
```

**PUCCH Processing**:
- Supports formats 0, 1, 2, 3, 4
- Processes control information (HARQ-ACK, CSI, SR)
- Notifies results via `notifier.on_new_pucch_results()`

### 5.3 PRACH Processing

```241:268:lib/phy/upper/uplink_processor_impl.cpp
void uplink_processor_impl::process_prach(const prach_buffer& buffer, const prach_buffer_context& context_)
{
  // Notify the creation of the PRACH detection task.
  if (!state_machine.on_prach_detection()) {
    return;
  }

  bool success = task_executors.prach_executor.execute([this, &buffer, context_]() noexcept SRSRAN_RTSAN_NONBLOCKING {
    trace_point tp = l1_ul_tracer.now();

    ul_prach_results ul_results;
    ul_results.context = context_;
    ul_results.result  = prach->detect(buffer, get_prach_dectector_config_from_prach_context(context_));

    // Notify the PRACH results.
    notifier.on_new_prach_results(ul_results);

    l1_ul_tracer << trace_event("process_prach", tp);

    // Notify the end of the PRACH detection.
    state_machine.on_end_prach_detection();
  });

  if (!success) {
    logger.warning(current_slot.sfn(), current_slot.slot_index(), "Failed to execute PRACH. Ignoring detection.");
    state_machine.on_end_prach_detection();
  }
}
```

**PRACH Processing**:
- Detects random access preambles
- Executes synchronously via `prach_executor.execute()`
- Notifies detection results

### 5.4 SRS Processing

```454:479:lib/phy/upper/uplink_processor_impl.cpp
void uplink_processor_impl::process_srs(const uplink_pdu_slot_repository::srs_pdu& pdu)
{
  // Notify the creation of the execution task.
  if (!state_machine.on_create_pdu_task()) {
    return;
  }

  bool success = task_executors.srs_executor.defer([this, &pdu]() {
    trace_point tp = l1_ul_tracer.now();

    ul_srs_results result;
    result.context          = pdu.context;
    result.processor_result = srs->estimate(grid->get_reader(), pdu.config);

    l1_ul_tracer << trace_event("process_srs", tp);

    notifier.on_new_srs_results(result);
    state_machine.on_finish_processing_pdu();
  });

  if (!success) {
    logger.warning(
        pdu.context.slot.sfn(), pdu.context.slot.slot_index(), "Failed to execute SRS. Ignoring processing.");
    state_machine.on_finish_processing_pdu();
  }
}
```

**SRS Processing**:
- Estimates channel state from sounding reference signals
- Used for channel quality estimation and beamforming

---

## Data Flow Summary

```
Baseband Receiver
    ↓
lower_phy_baseband_processor::ul_process()
    ↓
lower_phy_uplink_processor_impl::process()
    ↓
[Symbol Alignment & Collection]
    ↓
[CFO Compensation]
    ↓
[PRACH Processing] ──→ prach_processor_baseband
[PUxCH Processing] ──→ puxch_processor_baseband
    ↓
[Resource Grid Demodulation]
    ↓
upper_phy_rx_symbol_handler_impl::handle_rx_symbol()
    ↓
uplink_processor_impl::handle_rx_symbol()
    ↓
uplink_processor_impl::process_symbol_pdus()
    ↓
┌─────────────────────────────────────────┐
│  Channel-Specific Processing:           │
│  • process_pusch()  → PUSCH decoding    │
│  • process_pucch()  → PUCCH decoding    │
│  • process_prach()  → PRACH detection   │
│  • process_srs()    → SRS estimation    │
└─────────────────────────────────────────┘
    ↓
[Result Notification]
    ↓
upper_phy_rx_results_notifier
    ↓
MAC Layer / Higher Layers
```

---

## Key Components

### Lower PHY Components
- **lower_phy_baseband_processor**: Main orchestrator for baseband processing
- **lower_phy_uplink_processor_impl**: Symbol alignment, CFO compensation, OFDM processing
- **prach_processor**: PRACH symbol processing
- **puxch_processor**: PUSCH/PUCCH/SRS symbol processing

### Upper PHY Components
- **uplink_processor_impl**: Main upper PHY processor
- **pusch_processor**: PUSCH channel decoding
- **pucch_processor**: PUCCH channel decoding
- **prach_detector**: PRACH preamble detection
- **srs_estimator**: SRS channel estimation

### Interfaces
- **uplink_processor_notifier**: Lower PHY → Upper PHY notifications
- **upper_phy_rx_results_notifier**: Upper PHY → MAC layer results
- **uplink_pdu_slot_repository**: PDU storage and retrieval

---

## Threading Model

The uplink processing uses multiple executors for parallel processing:

1. **rx_executor**: Baseband reception
2. **uplink_executor**: Lower PHY uplink processing
3. **pusch_executor**: PUSCH decoding (async)
4. **pucch_executor**: PUCCH decoding (async)
5. **prach_executor**: PRACH detection (sync)
6. **srs_executor**: SRS estimation (async)

---

## Configuration

Uplink processing is configured through:
- **YAML config file**: `gnb_ru_sera_tdd_n78_50mhz_2x2.yml`
- **ru_ofh section**: Uplink compression, port configuration
- **cell_cfg section**: Uplink antennas, TDD configuration

Key configuration parameters:
- `nof_antennas_ul`: Number of uplink antennas
- `ul_port_id`: Uplink port IDs
- `compr_method_ul`: Uplink compression method
- `nof_ul_slots`: Number of uplink slots per frame
- `nof_ul_symbols`: Number of uplink symbols per slot

