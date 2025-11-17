#!/bin/bash
# CPU Compression Capability Checker for srsRAN OFH Compression
# Checks which compression implementation will be used based on CPU features

echo "=== CPU Compression Capability Check ==="
echo ""

# Check architecture
ARCH=$(uname -m)
echo "Architecture: $ARCH"

if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
    echo "⚠️  Unsupported architecture: $ARCH"
    exit 1
fi

# Check x86_64 features
if [ "$ARCH" = "x86_64" ]; then
    echo ""
    echo "=== x86_64 SIMD Features ==="
    
    # Read CPU flags from /proc/cpuinfo
    CPU_FLAGS=$(grep "^flags" /proc/cpuinfo | head -1)
    
    # Required AVX512 features for BFP compression
    echo "AVX512 Features (required for optimal BFP compression):"
    echo "$CPU_FLAGS" | grep -q "avx512f" && echo "  ✅ AVX512F (Foundation)" || echo "  ❌ AVX512F"
    echo "$CPU_FLAGS" | grep -q "avx512dq" && echo "  ✅ AVX512DQ (Doubleword/Quadword)" || echo "  ❌ AVX512DQ"
    echo "$CPU_FLAGS" | grep -q "avx512cd" && echo "  ✅ AVX512CD (Conflict Detection)" || echo "  ❌ AVX512CD"
    echo "$CPU_FLAGS" | grep -q "avx512bw" && echo "  ✅ AVX512BW (Byte/Word)" || echo "  ❌ AVX512BW"
    echo "$CPU_FLAGS" | grep -q "avx512vl" && echo "  ✅ AVX512VL (Vector Length)" || echo "  ❌ AVX512VL"
    echo "$CPU_FLAGS" | grep -q "avx512vbmi" && echo "  ✅ AVX512VBMI (Vector Byte Manipulation) - Required for decompression" || echo "  ❌ AVX512VBMI"
    
    echo ""
    echo "AVX2 Features (fallback):"
    echo "$CPU_FLAGS" | grep -q "avx2" && echo "  ✅ AVX2" || echo "  ❌ AVX2"
    
    echo ""
    echo "=== Expected Implementation ==="
    if echo "$CPU_FLAGS" | grep -q "avx512f" && \
       echo "$CPU_FLAGS" | grep -q "avx512dq" && \
       echo "$CPU_FLAGS" | grep -q "avx512cd" && \
       echo "$CPU_FLAGS" | grep -q "avx512bw" && \
       echo "$CPU_FLAGS" | grep -q "avx512vl" && \
       echo "$CPU_FLAGS" | grep -q "avx512vbmi"; then
        echo "✅ AVX512 BFP implementation will be used (optimal performance)"
        echo "   - File: iq_compression_bfp_avx512.cpp"
        echo "   - Throughput: 4 PRBs processed in parallel"
        echo "   - SIMD Width: 512 bits (32 samples)"
    elif echo "$CPU_FLAGS" | grep -q "avx2"; then
        echo "⚠️  AVX2 BFP implementation will be used (good performance)"
        echo "   - File: iq_compression_bfp_avx2.cpp"
        echo "   - Throughput: 2 PRBs processed in parallel"
        echo "   - SIMD Width: 256 bits (16 samples)"
    else
        echo "⚠️  Generic BFP implementation will be used (slower performance)"
        echo "   - File: iq_compression_bfp_impl.cpp"
        echo "   - Throughput: 1 PRB at a time"
        echo "   - No SIMD optimizations"
    fi
fi

# Check ARM features
if [ "$ARCH" = "aarch64" ]; then
    echo ""
    echo "=== ARM NEON Features ==="
    CPU_FLAGS=$(grep "^Features" /proc/cpuinfo | head -1)
    echo "$CPU_FLAGS" | grep -q "asimd" && echo "  ✅ NEON (Advanced SIMD)" || echo "  ❌ NEON"
    
    echo ""
    echo "=== Expected Implementation ==="
    if echo "$CPU_FLAGS" | grep -q "asimd"; then
        echo "✅ NEON BFP implementation will be used (optimal performance)"
        echo "   - File: iq_compression_bfp_neon.cpp"
        echo "   - Throughput: 4 PRBs processed in parallel"
    else
        echo "⚠️  Generic BFP implementation will be used (slower performance)"
        echo "   - File: iq_compression_bfp_impl.cpp"
        echo "   - Throughput: 1 PRB at a time"
    fi
fi

echo ""
echo "=== CPU Model ==="
lscpu | grep "Model name" | sed 's/^[[:space:]]*/  /'

echo ""
echo "=== Compression Configuration ==="
if [ -f "oru_sera/gnb_ru_sera_tdd_n78_50mhz_2x2.yml" ]; then
    echo "Config file found. Compression settings:"
    grep -A 1 "compr_method" oru_sera/gnb_ru_sera_tdd_n78_50mhz_2x2.yml | head -3 | sed 's/^/  /'
else
    echo "  Config file not found in expected location"
fi

echo ""
echo "=== Summary ==="
if [ "$ARCH" = "x86_64" ]; then
    if echo "$CPU_FLAGS" | grep -q "avx512f.*avx512vbmi"; then
        echo "✅ Your CPU supports AVX512 - optimal compression performance"
    elif echo "$CPU_FLAGS" | grep -q "avx2"; then
        echo "⚠️  Your CPU supports AVX2 - good compression performance"
    else
        echo "❌ Your CPU does not support AVX2/AVX512 - using generic implementation"
    fi
fi

