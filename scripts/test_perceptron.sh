#!/bin/bash

# Test script for perceptron-based cache replacement
# This script builds and tests the perceptron implementation

set -e

echo "🧪 Testing Perceptron-Based Cache Replacement"
echo "=============================================="

# Change to MGPUSim directory
cd "$(dirname "$0")/../mgpusim/amd/samples/spmv"

echo "📦 Building SPMV test..."
go build -o spmv_test

echo "✅ Build successful!"

echo ""
echo "🧪 Running test with perceptron-based cache replacement..."
echo "Matrix size: 2048x2048, Sparsity: 0.1"

# Run test with perceptron
./spmv_test -dim 2048 -sparsity 0.1 -timing -report-cache-hit-rate

echo ""
echo "✅ Test completed successfully!"
echo ""
echo "📊 Results:"
echo "- Check the output above for cache hit rates and performance metrics"
echo "- Compare with original LRU implementation in ~/mgpusim_original"
echo ""
echo "🔧 To enable perceptron in your cache configuration:"
echo "   cache := writeback.MakeBuilder().WithPerceptronVictimFinder().Build(\"L2Cache\")" 