#!/bin/bash

# Training integration test to verify perceptron learning behavior
# Runs SPMV test and captures training activity

set -e

echo "🧠 Perceptron Training Integration Test"
echo "======================================"
echo ""

# Test parameters
MATRIX_SIZE=1024
SPARSITY=0.01

echo "📊 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Focus: Training integration verification"
echo ""

# Change to MGPUSim directory
cd "$(dirname "$0")/../mgpusim/amd/samples/spmv"

echo "🏃 Running SPMV with training integration..."
echo "Looking for:"
echo "- [PERCEPTRON] Prediction logs (feature extraction)"
echo "- [PERCEPTRON] TrainOnHit logs (cache hits)"
echo "- [PERCEPTRON] TrainOnEviction logs (cache evictions)"
echo ""

# Run test and capture training logs
timeout 30s ./spmv_training -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -trace-mem -report-cache-hit-rate 2>&1 | \
grep -E "\[PERCEPTRON\]" | head -30

echo ""
echo "🧪 Training Integration Results:"
echo "==============================="

# Run a quick analysis
echo "✅ If you see prediction logs: Feature extraction is working"
echo "✅ If you see TrainOnHit logs: Cache hit training is working"  
echo "✅ If you see TrainOnEviction logs: Cache eviction training is working"
echo ""
echo "🎯 Expected behavior:"
echo "1. Initial predictions: sum=0, predictNoReuse=false (untrained)"
echo "2. Training on hits: Learning that blocks are reused"
echo "3. Training on evictions: Learning that blocks are not reused"
echo "4. Predictions should evolve as perceptron learns"
echo ""
echo "📈 Next: Run performance comparison to see learning impact!"