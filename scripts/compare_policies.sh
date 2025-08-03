#!/bin/bash

# Comprehensive comparison script for Perceptron vs LRU
# Runs both tests and compares the results

set -e

echo "🔬 Perceptron vs LRU Performance Comparison"
echo "=========================================="
echo ""

# Test parameters
MATRIX_SIZE=${1:-2048}
SPARSITY=0.01
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "📊 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Timestamp: ${TIMESTAMP}"
echo ""

# Change to perceptron_research directory
cd "$(dirname "$0")/.."

# Create results directory
mkdir -p results

BUILDER_FILE="mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go"

echo "🔄 Phase 1: Testing LRU Policy"
echo "=============================="

# Backup and modify builder for LRU
cp "$BUILDER_FILE" "${BUILDER_FILE}.original"

# Comment out the perceptron line properly
sed -i 's/WithPerceptronVictimFinder()/\/\/WithPerceptronVictimFinder()/' "$BUILDER_FILE"

# Verify the change
echo "Verifying LRU configuration..."
if grep -q "//WithPerceptronVictimFinder()" "$BUILDER_FILE"; then
    echo "✅ Perceptron disabled successfully"
else
    echo "❌ Failed to disable perceptron"
    exit 1
fi

# Build and run LRU test
cd mgpusim/amd/samples/spmv
echo "Building LRU version..."
go build -o spmv_lru_test 2>&1 | grep -v "PERCEPTRON" || true

echo "Running LRU test..."
./spmv_lru_test -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate 2>&1 | grep -v "PERCEPTRON" | tee lru_output.log

# Extract LRU metrics
LRU_HITS=""
LRU_MISSES=""
if [ -f "akita_sim_*.sqlite3" ]; then
    LRU_DB=$(ls -t akita_sim_*.sqlite3 | head -1)
    LRU_HITS=$(sqlite3 "$LRU_DB" "SELECT COALESCE(SUM(hit_count), 0) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" 2>/dev/null | cut -d. -f1)
    LRU_MISSES=$(sqlite3 "$LRU_DB" "SELECT COALESCE(SUM(miss_count), 0) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" 2>/dev/null | cut -d. -f1)
    cp "$LRU_DB" "../../../../results/lru_${MATRIX_SIZE}_${TIMESTAMP}.db"
    rm -f akita_sim_*.sqlite3
fi

cd ../../../..

echo ""
echo "🧠 Phase 2: Testing Perceptron Policy"
echo "===================================="

# Restore perceptron configuration
cp "${BUILDER_FILE}.original" "$BUILDER_FILE"

# Verify the change
echo "Verifying Perceptron configuration..."
if grep -q "WithPerceptronVictimFinder()" "$BUILDER_FILE" && ! grep -q "//WithPerceptronVictimFinder()" "$BUILDER_FILE"; then
    echo "✅ Perceptron enabled successfully"
else
    echo "❌ Failed to enable perceptron"
    exit 1
fi

# Build and run Perceptron test
cd mgpusim/amd/samples/spmv
echo "Building Perceptron version..."
go build -o spmv_perceptron_test

echo "Running Perceptron test (with learning)..."
./spmv_perceptron_test -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate 2>&1 | grep -E "(PERCEPTRON|hit_count|miss_count)" | head -50

# Extract Perceptron metrics
PERC_HITS=""
PERC_MISSES=""
if [ -f "akita_sim_*.sqlite3" ]; then
    PERC_DB=$(ls -t akita_sim_*.sqlite3 | head -1)
    PERC_HITS=$(sqlite3 "$PERC_DB" "SELECT COALESCE(SUM(hit_count), 0) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" 2>/dev/null | cut -d. -f1)
    PERC_MISSES=$(sqlite3 "$PERC_DB" "SELECT COALESCE(SUM(miss_count), 0) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" 2>/dev/null | cut -d. -f1)
    cp "$PERC_DB" "../../../../results/perceptron_${MATRIX_SIZE}_${TIMESTAMP}.db"
    rm -f akita_sim_*.sqlite3
fi

cd ../../../..

# Clean up
rm -f "${BUILDER_FILE}.original"

echo ""
echo "📊 Performance Comparison Results"
echo "================================"
echo ""

# Display and save results
RESULTS_FILE="results/comparison_${MATRIX_SIZE}_${TIMESTAMP}.txt"

{
    echo "Performance Comparison - Matrix Size ${MATRIX_SIZE}x${MATRIX_SIZE}"
    echo "=================================================="
    echo "Timestamp: $TIMESTAMP"
    echo "Sparsity: $SPARSITY"
    echo ""
    
    if [ -n "$LRU_HITS" ] && [ -n "$LRU_MISSES" ] && [ "$LRU_HITS" != "0" ]; then
        LRU_TOTAL=$((LRU_HITS + LRU_MISSES))
        LRU_HIT_RATE=$((LRU_HITS * 100 / LRU_TOTAL))
        
        echo "LRU Policy:"
        echo "  - Hits:     $LRU_HITS"
        echo "  - Misses:   $LRU_MISSES"
        echo "  - Total:    $LRU_TOTAL"
        echo "  - Hit Rate: ${LRU_HIT_RATE}%"
    else
        echo "LRU Policy: No data available"
    fi
    
    echo ""
    
    if [ -n "$PERC_HITS" ] && [ -n "$PERC_MISSES" ] && [ "$PERC_HITS" != "0" ]; then
        PERC_TOTAL=$((PERC_HITS + PERC_MISSES))
        PERC_HIT_RATE=$((PERC_HITS * 100 / PERC_TOTAL))
        
        echo "Perceptron Policy:"
        echo "  - Hits:     $PERC_HITS"
        echo "  - Misses:   $PERC_MISSES"
        echo "  - Total:    $PERC_TOTAL"
        echo "  - Hit Rate: ${PERC_HIT_RATE}%"
    else
        echo "Perceptron Policy: No data available"
    fi
    
    echo ""
    
    # Calculate improvement if both have data
    if [ -n "$LRU_MISSES" ] && [ -n "$PERC_MISSES" ] && [ "$LRU_MISSES" -gt 0 ]; then
        MISS_REDUCTION=$(( (LRU_MISSES - PERC_MISSES) * 100 / LRU_MISSES ))
        HIT_IMPROVEMENT=$(( (PERC_HITS - LRU_HITS) * 100 / LRU_HITS ))
        
        echo "Performance Impact:"
        echo "  - Miss Reduction:    ${MISS_REDUCTION}%"
        echo "  - Hit Improvement:   ${HIT_IMPROVEMENT}%"
        
        if [ "$MISS_REDUCTION" -gt 0 ]; then
            echo "  - Result: ✅ Perceptron IMPROVES cache performance!"
        elif [ "$MISS_REDUCTION" -lt 0 ]; then
            echo "  - Result: ❌ Perceptron underperforms (may need tuning)"
        else
            echo "  - Result: ➖ Performance is identical"
        fi
    fi
} | tee "$RESULTS_FILE"

echo ""
echo "📁 Results saved to: $RESULTS_FILE"
echo ""
echo "✅ Comparison test completed!"