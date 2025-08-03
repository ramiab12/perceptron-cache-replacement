#!/bin/bash

# Test script to run SPMV with LRU by temporarily disabling perceptron
# This modifies the builder file, runs the test, then restores it

set -e

echo "🔄 Running SPMV Test with LRU"
echo "============================"
echo ""

# Test parameters
MATRIX_SIZE=${1:-2048}
SPARSITY=0.01

echo "📊 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Policy: LRU (perceptron disabled)"
echo ""

# Change to perceptron_research directory
cd "$(dirname "$0")/.."

# Backup the builder file
echo "📁 Backing up builder configuration..."
cp mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go.bak

# Disable perceptron in builder (comment out the WithPerceptronVictimFinder line)
echo "🔧 Disabling perceptron victim finder..."
sed -i 's/\.WithPerceptronVictimFinder()/\/\/.WithPerceptronVictimFinder()/' mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go

# Build and run with LRU
cd mgpusim/amd/samples/spmv
echo "🏗️ Building with LRU..."
go build -o spmv_lru_test

echo "🏃 Running LRU test..."
./spmv_lru_test -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate

# Extract metrics
if [ -f "akita_sim_*.sqlite3" ]; then
    DB=$(ls -t akita_sim_*.sqlite3 | head -1)
    echo ""
    echo "📊 LRU Results:"
    echo "=============="
    
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
    cp "$DB" ../../../../results/lru_${MATRIX_SIZE}_$(date +%Y%m%d_%H%M%S).db
    rm -f akita_sim_*.sqlite3
fi

# Restore the builder file
cd ../../../..
echo ""
echo "🔧 Restoring perceptron configuration..."
mv mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go.bak mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go

echo ""
echo "✅ LRU test completed!"