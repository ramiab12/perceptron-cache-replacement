#!/bin/bash

# Debug test script to verify perceptron integration and feature extraction
# Runs a small SPMV test with detailed logging

set -e

echo "🔍 Perceptron Debug Test"
echo "======================="
echo ""

# Test parameters
MATRIX_SIZE=1024
SPARSITY=0.01

echo "📊 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Focus: Perceptron integration verification"
echo ""

# Change to MGPUSim directory
cd "$(dirname "$0")/../mgpusim/amd/samples/spmv"

echo "📦 Building SPMV test..."
go build -o spmv_debug

echo "✅ Build successful!"
echo ""

echo "🏃 Running debug test with perceptron logging..."
echo "Looking for:"
echo "- [L2CACHE] L2 cache builder messages"
echo "- [BUILDER] Victim finder selection messages"  
echo "- [PERCEPTRON] Initialization and prediction messages"
echo ""

# Run test and filter for our debug messages
./spmv_debug -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -trace-mem -report-cache-hit-rate 2>&1 | \
grep -E "\[L2CACHE\]|\[BUILDER\]|\[PERCEPTRON\]" | head -20

echo ""
echo "🧪 Test completed!"
echo ""
echo "📋 What to verify:"
echo "1. ✅ L2 cache should show 'PerceptronVictimFinder enabled'"
echo "2. ✅ Builder should show 'Using PerceptronVictimFinder'"
echo "3. ✅ Perceptron should show initialization with correct parameters"
echo "4. ✅ Perceptron should show prediction logs with features and decisions"
echo ""
echo "If you don't see these messages, the perceptron may not be active!"