#!/bin/bash

# Quick comparison test - single matrix size to verify perceptron vs LRU performance
# Tests both implementations and compares results

set -e

echo "🚀 Quick Perceptron vs LRU Comparison Test"
echo "========================================="
echo ""

# Test parameters
MATRIX_SIZE=2048
SPARSITY=0.01
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "📊 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Timestamp: ${TIMESTAMP}"
echo ""

# Change to MGPUSim directory
cd "$(dirname "$0")/../mgpusim/amd/samples/spmv"

# Create results directory
mkdir -p ../../../../../../results

echo "🧠 Phase 1: Testing Perceptron Implementation"
echo "============================================="
echo "Building perceptron version..."
go build -o spmv_perceptron

echo "Running perceptron test..."
./spmv_perceptron -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate

# Extract metrics from perceptron
echo ""
echo "Extracting perceptron metrics..."
if [ -f "akita_sim_*.sqlite3" ]; then
    PERC_DB=$(ls -t akita_sim_*.sqlite3 | head -1)
    echo "Using database: $PERC_DB"
    
    PERC_HITS=$(sqlite3 "$PERC_DB" "SELECT SUM(hit_count) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" | cut -d. -f1)
    PERC_MISSES=$(sqlite3 "$PERC_DB" "SELECT SUM(miss_count) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" | cut -d. -f1)
    
    echo "Perceptron - Hits: $PERC_HITS, Misses: $PERC_MISSES"
    
    # Save perceptron DB
    cp "$PERC_DB" "../../../../../../results/perceptron_${MATRIX_SIZE}_${TIMESTAMP}.db"
    rm -f akita_sim_*.sqlite3
else
    echo "❌ No perceptron database found!"
fi

echo ""
echo "🔄 Phase 2: Testing LRU Implementation"
echo "======================================"
echo "Building LRU version (using mgpusim_original)..."
cd ../../../mgpusim_original/amd/samples/spmv
go build -o spmv_lru

echo "Running LRU test..."
./spmv_lru -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate

# Extract metrics from LRU
echo ""
echo "Extracting LRU metrics..."
if [ -f "akita_sim_*.sqlite3" ]; then
    LRU_DB=$(ls -t akita_sim_*.sqlite3 | head -1)
    echo "Using database: $LRU_DB"
    
    LRU_HITS=$(sqlite3 "$LRU_DB" "SELECT SUM(hit_count) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" | cut -d. -f1)
    LRU_MISSES=$(sqlite3 "$LRU_DB" "SELECT SUM(miss_count) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" | cut -d. -f1)
    
    echo "LRU - Hits: $LRU_HITS, Misses: $LRU_MISSES"
    
    # Save LRU DB
    cp "$LRU_DB" "../../../../../../../../results/lru_${MATRIX_SIZE}_${TIMESTAMP}.db"
    rm -f akita_sim_*.sqlite3
else
    echo "❌ No LRU database found!"
fi

echo ""
echo "📊 Performance Comparison Results"
echo "================================"

# Calculate metrics if we have data
if [ -n "$PERC_HITS" ] && [ -n "$LRU_HITS" ] && [ "$PERC_HITS" -gt 0 ] && [ "$LRU_HITS" -gt 0 ]; then
    # Calculate hit rates
    PERC_TOTAL=$((PERC_HITS + PERC_MISSES))
    LRU_TOTAL=$((LRU_HITS + LRU_MISSES))
    
    if [ "$PERC_TOTAL" -gt 0 ] && [ "$LRU_TOTAL" -gt 0 ]; then
        PERC_HIT_RATE=$((PERC_HITS * 100 / PERC_TOTAL))
        LRU_HIT_RATE=$((LRU_HITS * 100 / LRU_TOTAL))
        
        echo "Matrix Size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
        echo ""
        echo "LRU Performance:"
        echo "  - Hits: $LRU_HITS"
        echo "  - Misses: $LRU_MISSES"
        echo "  - Hit Rate: ${LRU_HIT_RATE}%"
        echo ""
        echo "Perceptron Performance:"
        echo "  - Hits: $PERC_HITS"
        echo "  - Misses: $PERC_MISSES"
        echo "  - Hit Rate: ${PERC_HIT_RATE}%"
        echo ""
        
        # Calculate improvement
        if [ "$LRU_MISSES" -gt 0 ]; then
            MISS_REDUCTION=$(( (LRU_MISSES - PERC_MISSES) * 100 / LRU_MISSES ))
            echo "📈 Miss Reduction: ${MISS_REDUCTION}%"
            
            if [ "$MISS_REDUCTION" -gt 0 ]; then
                echo "✅ Perceptron IMPROVES performance!"
            elif [ "$MISS_REDUCTION" -lt 0 ]; then
                echo "❌ Perceptron underperforms (needs tuning)"
            else
                echo "➖ Performance is identical"
            fi
        fi
        
        # Save summary
        SUMMARY_FILE="../../../../../../results/quick_comparison_${TIMESTAMP}.txt"
        {
            echo "Quick Comparison Results - $TIMESTAMP"
            echo "===================================="
            echo "Matrix Size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
            echo "Sparsity: $SPARSITY"
            echo ""
            echo "LRU: Hits=$LRU_HITS, Misses=$LRU_MISSES, HitRate=${LRU_HIT_RATE}%"
            echo "Perceptron: Hits=$PERC_HITS, Misses=$PERC_MISSES, HitRate=${PERC_HIT_RATE}%"
            echo "Miss Reduction: ${MISS_REDUCTION}%"
        } > "$SUMMARY_FILE"
        
        echo ""
        echo "📁 Results saved to: $SUMMARY_FILE"
    else
        echo "❌ Error: Total accesses is 0"
    fi
else
    echo "❌ Error: Missing metrics data"
fi

echo ""
echo "✅ Quick comparison test completed!"