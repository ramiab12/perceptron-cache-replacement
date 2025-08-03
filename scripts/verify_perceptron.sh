#!/bin/bash

# Simple verification script to confirm perceptron is working
# Runs a small test and checks for perceptron activity

set -e

echo "🔍 Verifying Perceptron Implementation"
echo "====================================="
echo ""

# Small test for quick verification
MATRIX_SIZE=1024
SPARSITY=0.01

cd "$(dirname "$0")/../mgpusim/amd/samples/spmv"

echo "🏗️ Building SPMV test..."
go build -o spmv_verify 2>/dev/null

echo "🏃 Running verification test..."
echo ""

# Run and capture perceptron logs
./spmv_verify -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate 2>&1 | \
grep -E "(PERCEPTRON|L2CACHE)" | head -20

echo ""
echo "📊 Checking for key indicators:"
echo ""

# Check for initialization
if ./spmv_verify -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate 2>&1 | grep -q "Initialized PerceptronVictimFinder"; then
    echo "✅ Perceptron initialization: CONFIRMED"
else
    echo "❌ Perceptron initialization: NOT FOUND"
fi

# Check for predictions
if ./spmv_verify -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate 2>&1 | grep -q "Prediction #"; then
    echo "✅ Perceptron predictions: ACTIVE"
else
    echo "❌ Perceptron predictions: NOT FOUND"
fi

# Check for training
if ./spmv_verify -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate 2>&1 | grep -q "TrainOnHit"; then
    echo "✅ Perceptron training: ACTIVE"
else
    echo "❌ Perceptron training: NOT FOUND"
fi

# Extract final metrics
echo ""
echo "📈 Cache Performance Metrics:"
if [ -f "akita_sim_*.sqlite3" ]; then
    DB=$(ls -t akita_sim_*.sqlite3 | head -1)
    
    HITS=$(sqlite3 "$DB" "SELECT COALESCE(SUM(hit_count), 0) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" 2>/dev/null)
    MISSES=$(sqlite3 "$DB" "SELECT COALESCE(SUM(miss_count), 0) FROM cache_hit_rate WHERE component_name LIKE '%L2Cache%';" 2>/dev/null)
    
    # Convert to integers
    HITS=${HITS%.*}
    MISSES=${MISSES%.*}
    
    if [ -n "$HITS" ] && [ -n "$MISSES" ] && [ "$HITS" -gt 0 ]; then
        TOTAL=$((HITS + MISSES))
        HIT_RATE=$((HITS * 100 / TOTAL))
        
        echo "- L2 Cache Hits: $HITS"
        echo "- L2 Cache Misses: $MISSES"
        echo "- L2 Cache Hit Rate: ${HIT_RATE}%"
    else
        echo "- No cache metrics found"
    fi
    
    rm -f akita_sim_*.sqlite3
fi

echo ""
echo "✅ Verification complete!"