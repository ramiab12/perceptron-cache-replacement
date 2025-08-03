#!/bin/bash

# Test script to run SPMV with Perceptron enabled
# Uses the current configuration with perceptron active

set -e

echo "🧠 Running SPMV Test with Perceptron"
echo "==================================="
echo ""

# Test parameters
MATRIX_SIZE=${1:-2048}
SPARSITY=0.01

echo "📊 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Policy: Perceptron (learning enabled)"
echo ""

# Change to SPMV directory
cd "$(dirname "$0")/../mgpusim/amd/samples/spmv"

# Build and run with Perceptron
echo "🏗️ Building with Perceptron..."
go build -o spmv_perceptron_test

echo "🏃 Running Perceptron test..."
./spmv_perceptron_test -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate

# Extract metrics
if [ -f "akita_sim_*.sqlite3" ]; then
    DB=$(ls -t akita_sim_*.sqlite3 | head -1)
    echo ""
    echo "📊 Perceptron Results:"
    echo "===================="
    
    HITS=$(sqlite3 "$DB" "SELECT SUM(hit_count) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" 2>/dev/null | cut -d. -f1)
    MISSES=$(sqlite3 "$DB" "SELECT SUM(miss_count) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" 2>/dev/null | cut -d. -f1)
    
    if [ -n "$HITS" ] && [ -n "$MISSES" ]; then
        TOTAL=$((HITS + MISSES))
        if [ "$TOTAL" -gt 0 ]; then
            HIT_RATE=$((HITS * 100 / TOTAL))
            echo "- Hits: $HITS"
            echo "- Misses: $MISSES" 
            echo "- Hit Rate: ${HIT_RATE}%"
        fi
    fi
    
    # Save the database
    mkdir -p ../../../../results
    cp "$DB" ../../../../results/perceptron_${MATRIX_SIZE}_$(date +%Y%m%d_%H%M%S).db
    rm -f akita_sim_*.sqlite3
fi

echo ""
echo "✅ Perceptron test completed!"