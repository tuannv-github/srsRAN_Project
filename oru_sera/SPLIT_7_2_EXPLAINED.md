# O-RAN Split 7.2 Explained

## Overview

**Split 7.2** is an O-RAN functional split that defines the boundary between the **O-DU (Distributed Unit)** and **O-RU (Radio Unit)** in a 5G base station. This split uses the **Open Fronthaul (OFH)** interface to communicate between the DU and RU over Ethernet.

## What is Split 7.2?

In Split 7.2:
- **O-DU handles**: All PHY layer processing (encoding, modulation, FFT/IFFT, precoding)
- **O-RU handles**: RF frontend, ADC/DAC, basic IQ sample processing
- **Interface**: Open Fronthaul (OFH) over Ethernet using eCPRI protocol

### Functional Split Comparison

```
┌─────────────────────────────────────────────────────────────┐
│                    Split 7.2 Architecture                   │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────┐         ┌──────────────────┐       │
│  │      O-DU        │         │      O-RU        │       │
│  │                  │         │                  │       │
│  │  ┌────────────┐  │         │  ┌────────────┐  │       │
│  │  │   MAC      │  │         │  │   RF       │  │       │
│  │  │   RLC      │  │         │  │  Frontend  │  │       │
│  │  │   PDCP     │  │         │  │  ADC/DAC   │  │       │
│  │  └────────────┘  │         │  └────────────┘  │       │
│  │                  │         │                  │       │
│  │  ┌────────────┐  │         │                  │       │
│  │  │ Upper PHY  │  │         │                  │       │
│  │  │ - Encoding │  │         │                  │       │
│  │  │ - Modulate │  │         │                  │       │
│  │  │ - FFT/IFFT │  │         │                  │       │
│  │  │ - Precoding│  │         │                  │       │
│  │  └────────────┘  │         │                  │       │
│  │                  │         │                  │       │
│  │  ┌────────────┐  │         │                  │       │
│  │  │ Lower PHY  │  │         │                  │       │
│  │  │ - OFDM     │  │         │                  │       │
│  │  │ - CP Add   │  │         │                  │       │
│  │  └────────────┘  │         │                  │       │
│  │                  │         │                  │       │
│  └────────┬─────────┘         └────────┬─────────┘       │
│           │                            │                   │
│           │   Open Fronthaul (OFH)    │                   │
│           │   - IQ Samples (compressed)│                   │
│           │   - Control Plane (C-Plane)│                   │
│           │   - User Plane (U-Plane)   │                   │
│           │   - Ethernet/eCPRI         │                   │
│           └────────────────────────────┘                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Split 7.2 vs Split 8

| Aspect | Split 7.2 | Split 8 |
|--------|-----------|---------|
| **DU Processing** | Full PHY (Upper + Lower) | Upper PHY only |
| **RU Processing** | RF only | Lower PHY + RF |
| **Interface** | Open Fronthaul (OFH) | FAPI (Functional API) |
| **Transport** | Ethernet/eCPRI | PCIe/USB/Internal |
| **Latency** | Higher (network) | Lower (local) |
| **Deployment** | Remote/Cloud RU | Co-located |
| **Compression** | Required (IQ samples) | Not needed |

---

## Split 7.2 in srsRAN Project

### Configuration

Your configuration file (`gnb_ru_sera_tdd_n78_50mhz_2x2.yml`) uses split 7.2:

```yaml
ru_ofh:
  t1a_max_cp_dl: 429
  t1a_min_cp_dl: 285
  t1a_max_cp_ul: 429
  t1a_min_cp_ul: 285
  t1a_max_up: 196
  t1a_min_up: 96
  ta4_max: 180
  ta4_min: 110
  is_prach_cp_enabled: true
  compr_method_ul: bfp
  compr_bitwidth_ul: 9
  compr_method_dl: bfp
  compr_bitwidth_dl: 9
  compr_method_prach: bfp
  compr_bitwidth_prach: 9
  enable_ul_static_compr_hdr: true
  enable_dl_static_compr_hdr: true
  iq_scaling: 5
  cells:
    - network_interface: ens12f0np0
      ru_mac_addr: 00:10:61:00:42:fd
      du_mac_addr: 7a:a1:ab:00:f3:10
      vlan_tag_cp: 564
      vlan_tag_up: 564
      prach_port_id: [4, 5]
      dl_port_id: [0, 1]
      ul_port_id: [0, 1]
```

### Key Configuration Parameters

#### Timing Parameters
- **t1a_max_cp_dl/t1a_min_cp_dl**: Control plane downlink timing window (samples)
- **t1a_max_cp_ul/t1a_min_cp_ul**: Control plane uplink timing window (samples)
- **t1a_max_up/t1a_min_up**: User plane timing window (samples)
- **ta4_max/ta4_min**: Timing advance range (samples)

#### Compression Parameters
- **compr_method_ul/dl/prach**: Compression method (`bfp` = Block Floating Point)
- **compr_bitwidth_ul/dl/prach**: Bit width for compression (9 bits)
- **enable_ul_static_compr_hdr**: Use static compression headers for uplink
- **iq_scaling**: IQ scaling factor

#### Network Configuration
- **network_interface**: Ethernet interface name
- **ru_mac_addr**: Radio Unit MAC address
- **du_mac_addr**: Distributed Unit MAC address
- **vlan_tag_cp/up**: VLAN tags for control/user plane
- **dl_port_id/ul_port_id/prach_port_id**: Port IDs for different traffic types

---

## Implementation Architecture

### Code Structure

```
apps/units/flexible_o_du/split_7_2/
├── split_7_2_o_du_application_unit_impl.cpp  # Main application unit
├── split_7_2_o_du_factory.cpp                # Factory for creating DU
└── helpers/
    ├── ru_ofh_config.h                        # OFH configuration
    └── ru_ofh_factories.cpp                   # OFH factory functions

lib/ru/ofh/
├── ru_ofh_impl.cpp                            # RU OFH implementation
├── ru_ofh_impl.h
└── ru_ofh_*.cpp                                # Various OFH handlers

lib/ofh/
├── receiver/                                   # Uplink reception
│   ├── ofh_data_flow_uplane_uplink_data_impl.cpp
│   └── ofh_message_receiver_impl.cpp
├── transmitter/                                # Downlink transmission
│   ├── ofh_data_flow_uplane_downlink_data_impl.cpp
│   └── ofh_uplink_request_handler_impl.cpp
├── compression/                                # IQ compression
│   ├── iq_compression_bfp_impl.cpp
│   └── iq_compression_bfp_avx512.cpp
└── serdes/                                     # Serialization/Deserialization
    └── ofh_uplane_message_decoder_impl.cpp
```

### Data Flow

#### Downlink (DU → RU)

```
O-DU Upper PHY
    ↓ (IQ samples)
OFH Transmitter
    ↓ (Compress IQ samples)
OFH Message Builder
    ↓ (eCPRI/Ethernet frame)
Ethernet Network
    ↓
O-RU Receiver
    ↓ (Decompress)
RF Frontend
    ↓
Antenna
```

**Key Files**:
- `lib/ofh/transmitter/ofh_data_flow_uplane_downlink_data_impl.cpp`
- `lib/ofh/serdes/ofh_uplane_message_builder_impl.cpp`

#### Uplink (RU → DU)

```
Antenna
    ↓
RF Frontend
    ↓ (IQ samples)
O-RU Transmitter
    ↓ (Compress IQ samples)
OFH Message Builder
    ↓ (eCPRI/Ethernet frame)
Ethernet Network
    ↓
O-DU Receiver
    ↓ (Decompress)
OFH Message Decoder
    ↓ (IQ samples)
Lower PHY Uplink Processor
    ↓ (Demodulated symbols)
Upper PHY Uplink Processor
```

**Key Files**:
- `lib/ofh/receiver/ofh_data_flow_uplane_uplink_data_impl.cpp`
- `lib/ofh/serdes/ofh_uplane_message_decoder_impl.cpp`

---

## Open Fronthaul (OFH) Protocol

### Message Types

1. **Control Plane (C-Plane)**
   - Scheduling information
   - Beamforming weights
   - PRACH configuration
   - Timing information

2. **User Plane (U-Plane)**
   - IQ samples (compressed)
   - Symbol data
   - Port information

3. **Management Plane (M-Plane)**
   - Configuration
   - Status monitoring
   - Software management

### Compression Methods

#### Block Floating Point (BFP)
- **Algorithm**: Defined in O-RAN.WG4.CUS Annex A.1.2
- **Bitwidth**: Configurable (typically 9 bits)
- **Benefits**: Reduces bandwidth by ~50% compared to uncompressed IQ
- **Implementation**: `lib/ofh/compression/iq_compression_bfp_impl.cpp`

**Compression Process**:
1. Divide IQ samples into blocks
2. Find maximum magnitude in block
3. Calculate exponent (shared across block)
4. Quantize mantissas to fixed bitwidth
5. Pack into OFH message

### Message Format

```
┌─────────────────────────────────────┐
│      Ethernet Header                │
├─────────────────────────────────────┤
│      eCPRI Header                    │
│      - Message Type                  │
│      - Payload Size                  │
├─────────────────────────────────────┤
│      OFH Header                      │
│      - Filter Index                  │
│      - Slot/Symbol Info              │
│      - Section Info                   │
├─────────────────────────────────────┤
│      Compression Header              │
│      - Compression Method            │
│      - Bitwidth                       │
│      - Block Size                     │
├─────────────────────────────────────┤
│      IQ Data (Compressed)            │
│      - Block Exponents                │
│      - Quantized Mantissas            │
└─────────────────────────────────────┘
```

---

## Timing and Synchronization

### PTP (Precision Time Protocol)

Split 7.2 requires precise timing synchronization between DU and RU:

- **PTP Master**: Typically at DU side
- **PTP Slave**: At RU side
- **Hardware Timestamping**: Required for sub-microsecond accuracy
- **Configuration**: See `oru_sera/ptp/setup_ptp_slave.sh`

### Timing Windows

The configuration defines timing windows to account for network latency:

- **t1a_min/t1a_max**: Minimum/maximum delay for control plane
- **t1a_up**: User plane delay window
- **ta4_min/ta4_max**: Timing advance range

These ensure that:
- Control messages arrive before they're needed
- User plane data arrives within processing window
- Timing advance commands are valid

---

## Uplink Processing in Split 7.2

### Flow

1. **O-RU receives RF signal**
   - ADC converts analog to digital
   - Basic filtering/amplification

2. **O-RU compresses IQ samples**
   - Uses BFP compression
   - Packs into OFH U-Plane message

3. **O-RU transmits over Ethernet**
   - eCPRI encapsulation
   - VLAN tagging
   - Hardware timestamping

4. **O-DU receives OFH message**
   - Decodes eCPRI header
   - Extracts IQ samples
   - Decompresses IQ data

5. **O-DU processes uplink**
   - Lower PHY: OFDM demodulation, CFO compensation
   - Upper PHY: Channel decoding (PUSCH, PUCCH, PRACH, SRS)
   - Results sent to MAC layer

**See**: `UPLINK_PROCESSING_TRACE.md` for detailed code flow

---

## Advantages of Split 7.2

1. **Centralization**: PHY processing centralized at DU
2. **Flexibility**: RU can be simpler, cheaper hardware
3. **Scalability**: Multiple RUs can connect to one DU
4. **Standardization**: O-RAN standard interface
5. **Cloud RAN**: Enables cloud-based PHY processing

## Disadvantages

1. **Latency**: Network transport adds latency
2. **Bandwidth**: Requires high-bandwidth Ethernet (10Gbps+)
3. **Synchronization**: Requires precise PTP timing
4. **Complexity**: More complex than split 8

---

## Testing and Debugging

### Key Logs

- **OFH logs**: Check for message decode errors
- **Timing logs**: Monitor PTP synchronization
- **Compression logs**: Verify compression/decompression
- **Network logs**: Check Ethernet interface status

### Common Issues

1. **Timing synchronization failures**
   - Check PTP configuration
   - Verify network latency
   - Adjust timing windows

2. **Compression errors**
   - Verify compression method matches RU
   - Check bitwidth settings
   - Monitor compression ratio

3. **Network issues**
   - Check VLAN configuration
   - Verify MAC addresses
   - Monitor packet loss

---

## References

- **O-RAN Specification**: O-RAN.WG4.CUS (Control, User and Synchronization Plane Specification)
- **eCPRI Specification**: eCPRI Specification V2.0
- **PTP Standard**: IEEE 1588-2019

---

## Related Files in Your Setup

- **Configuration**: `oru_sera/gnb_ru_sera_tdd_n78_50mhz_2x2.yml`
- **PTP Setup**: `oru_sera/ptp/setup_ptp_slave.sh`
- **Interface Setup**: `oru_sera/interface_setup_vf.sh`
- **Uplink Processing Trace**: `oru_sera/UPLINK_PROCESSING_TRACE.md`

