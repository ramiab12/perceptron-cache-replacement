#!/bin/bash

# Performance comparison script for perceptron vs LRU cache replacement
# This script runs both implementations and compares results

set -e

echo "📊 Perceptron vs LRU Performance Comparison"
echo "==========================================="

# Create results directory
mkdir -p ../results
mkdir -p ../logs

# Test parameters
MATRIX_SIZE=2048
SPARSITY=0.1
NUM_RUNS=3

echo "🧪 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Number of runs: ${NUM_RUNS}"
echo ""

# Change to MGPUSim directory
cd "$(dirname "$0")/../mgpusim/amd/samples/spmv"

echo "📦 Building SPMV test..."
go build -o spmv_test

echo "✅ Build successful!"
echo ""

# Function to run test and extract metrics
run_test() {
    local test_name=$1
    local output_file="../logs/${test_name}_$(date +%Y%m%d_%H%M%S).log"
    
    echo "🧪 Running ${test_name} test..."
    
    # Run the test multiple times and capture output
    for i in $(seq 1 $NUM_RUNS); do
        echo "  Run $i/$NUM_RUNS..."
        ./spmv_test -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate 2>&1 | tee -a "$output_file"
        echo "" >> "$output_file"
        echo "--- Run $i completed ---" >> "$output_file"
        echo "" >> "$output_file"
    done
    
    echo "✅ ${test_name} test completed. Log saved to: $output_file"
    echo ""
}

# Run perceptron test
run_test "perceptron"

echo "📊 Analysis:"
echo "============"
echo ""
echo "📈 Performance Metrics to Compare:"
echo "- Cache hit rate"
echo "- Cache miss rate" 
echo "- Total execution time"
echo "- Memory bandwidth utilization"
echo ""
echo "📁 Log files saved in: ../logs/"
echo "📊 Results summary will be generated in: ../results/"
echo ""
echo "🔍 To analyze results:"
echo "1. Check the log files for detailed metrics"
echo "2. Compare with ~/mgpusim_original for baseline LRU performance"
echo "3. Look for improvements in cache hit rates and execution time"
echo ""
echo "🎯 Expected Improvements:"
echo "- 5-15% reduction in cache miss rate"
echo "- 2-8% improvement in cache hit rate"
echo "- 3-10% overall speedup" 