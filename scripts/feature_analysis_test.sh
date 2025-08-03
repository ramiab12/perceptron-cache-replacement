#!/bin/bash

# Feature analysis test to capture and analyze perceptron predictions and features
# Runs SPMV test and captures detailed perceptron behavior

set -e

echo "🔬 Perceptron Feature Analysis Test"
echo "=================================="
echo ""

# Test parameters
MATRIX_SIZE=1024
SPARSITY=0.01
LOG_FILE="../logs/perceptron_features_$(date +%Y%m%d_%H%M%S).log"

echo "📊 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Log file: ${LOG_FILE}"
echo ""

# Create logs directory
mkdir -p ../logs

# Change to MGPUSim directory
cd "$(dirname "$0")/../mgpusim/amd/samples/spmv"

echo "🏃 Running SPMV with full perceptron logging..."

# Run test and capture all output
./spmv_debug -dim $MATRIX_SIZE -sparsity $SPARSITY -timing -trace-mem -report-cache-hit-rate 2>&1 | tee "$LOG_FILE"

echo ""
echo "📊 Analysis Results:"
echo "=================="

# Count perceptrons initialized
perceptron_count=$(grep -c "\[PERCEPTRON\] Initialized" "$LOG_FILE" || echo "0")
echo "🧠 Perceptrons initialized: $perceptron_count"

# Count predictions made
prediction_count=$(grep -c "\[PERCEPTRON\] Prediction" "$LOG_FILE" || echo "0")
echo "🎯 Predictions logged: $prediction_count"

# Show sample predictions if any
if [ "$prediction_count" -gt 0 ]; then
    echo ""
    echo "📋 Sample Predictions:"
    grep "\[PERCEPTRON\] Prediction" "$LOG_FILE" | head -5
else
    echo "⚠️  No predictions logged - may need to reduce logging threshold"
fi

echo ""
echo "📁 Full log saved to: $LOG_FILE"
echo ""
echo "🔍 Next Steps:"
echo "1. Check if predictions are being made (look for prediction logs)"
echo "2. Analyze feature patterns and distributions"
echo "3. Verify prediction logic is working correctly"
echo "4. Compare performance with LRU baseline"