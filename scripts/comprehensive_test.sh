#!/bin/bash

# Comprehensive test script for perceptron vs LRU cache replacement
# Tests SPMV with growing matrix sizes from 1024 to 16384 with 0.01 sparsity
# Uses the user's compare.sh script to extract and compare results

set -e

echo "🧪 Comprehensive Perceptron vs LRU Performance Test"
echo "=================================================="
echo ""

# Test parameters
SPARSITY=0.01
START_SIZE=2048
END_SIZE=2048
COMPARE_SCRIPT="$HOME/compare.sh"

# Check if compare.sh exists
if [ ! -f "$COMPARE_SCRIPT" ]; then
    echo "❌ Error: compare.sh not found at $COMPARE_SCRIPT"
    exit 1
fi

# Create results directory
mkdir -p ../results
RESULTS_FILE="../results/comprehensive_results_$(date +%Y%m%d_%H%M%S).txt"

echo "📊 Test Configuration:"
echo "- Matrix sizes: ${START_SIZE} to ${END_SIZE} (powers of 2)"
echo "- Sparsity: ${SPARSITY}"
echo "- Compare script: ${COMPARE_SCRIPT}"
echo "- Results file: ${RESULTS_FILE}"
echo ""

# Function to clean old SQLite files but keep the most recent one
cleanup_sqlite() {
    local dir=$1
    echo "🧹 Cleaning old SQLite files in $dir..."
    cd "$dir"
    if ls akita_sim*.sqlite3 1> /dev/null 2>&1; then
        # Keep only the most recent SQLite file
        ls -t akita_sim*.sqlite3 | tail -n +2 | xargs -r rm -f
        echo "   Kept most recent SQLite file: $(ls -t akita_sim*.sqlite3 | head -1)"
    fi
}

# Function to test a specific matrix size
test_matrix_size() {
    local size=$1
    echo ""
    echo "🔬 Testing Matrix Size: ${size}x${size}"
    echo "================================="
    
    # Clean old SQLite files from both repositories before test
    cleanup_sqlite "$HOME/perceptron_research/mgpusim/amd/samples/spmv"
    cleanup_sqlite "$HOME/mgpusim_original/amd/samples/spmv"
    
    # Run comparison using the user's compare.sh script
    echo "🏃 Running comparison..."
    
    # Use the exact same approach as compare.sh but with our perceptron repo
    local perc_repo="$HOME/perceptron_research/mgpusim"
    local lru_repo="$HOME/mgpusim_original"
    local flags="-dim $size -sparsity $SPARSITY -timing -trace-mem -report-cache-hit-rate"
    
    echo "sample : spmv"
    echo "flags  : $flags"
    echo "----------"
    
    # Run perceptron version
    echo "  Running perceptron version..."
    cd "$perc_repo/amd/samples/spmv"
    go build -o run_perc
    rm -f akita_sim*.sqlite3
    ./run_perc $flags 1>&2 
    db_perc=$(ls -t akita_sim*.sqlite3 | head -1)
    echo "  [perc] using $db_perc" >&2
    out_perc=$(sqlite3 "$db_perc" \
      "SELECT \
       COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit')  THEN Value END),0), \
       COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0) \
       FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';")
    h1=$(echo "${out_perc%%|*}" | cut -d. -f1)
    m1=$(echo "${out_perc##*|}" | cut -d. -f1)
    
    # Run LRU version  
    echo "  Running LRU version..."
    cd "$lru_repo/amd/samples/spmv"
    go build -o run_lru
    rm -f akita_sim*.sqlite3
    ./run_lru $flags 1>&2 
    db_lru=$(ls -t akita_sim*.sqlite3 | head -1)
    echo "  [lru] using $db_lru" >&2
    out_lru=$(sqlite3 "$db_lru" \
      "SELECT \
       COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit')  THEN Value END),0), \
       COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0) \
       FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';")
    h0=$(echo "${out_lru%%|*}" | cut -d. -f1)
    m0=$(echo "${out_lru##*|}" | cut -d. -f1)
    
    # Calculate metrics (same as compare.sh) with division by zero protection
    if [ "$((h1 + m1))" -eq 0 ]; then
        hr1="0.00"
    else
        hr1=$(echo "scale=2; ($h1*100)/($h1+$m1)" | bc)
    fi
    
    if [ "$((h0 + m0))" -eq 0 ]; then
        hr0="0.00"
    else
        hr0=$(echo "scale=2; ($h0*100)/($h0+$m0)" | bc)
    fi
    
    if [ "$m0" -eq 0 ]; then
        red="0.00"
    else
        red=$(echo  "scale=2; ($m0-$m1)*100/$m0"   | bc)
    fi
    
    # Display results
    printf "\nPerceptron  hits %-10s misses %-10s hit-rate %s%%\n" "$h1" "$m1" "$hr1"
    printf "LRU         hits %-10s misses %-10s hit-rate %s%%\n" "$h0" "$m0" "$hr0"
    printf "Miss-reduction: %s%%\n" "$red"
    
    # Save results to file
    {
        echo "Matrix Size: ${size}x${size}"
        echo "Sparsity: ${SPARSITY}"
        echo "Timestamp: $(date)"
        echo "----------------------------------------"
        printf "Perceptron  hits %-10s misses %-10s hit-rate %s%%\n" "$h1" "$m1" "$hr1"
        printf "LRU         hits %-10s misses %-10s hit-rate %s%%\n" "$h0" "$m0" "$hr0"
        printf "Miss-reduction: %s%%\n" "$red"
        echo ""
        echo "========================================"
        echo ""
    } >> "$RESULTS_FILE"
    
    # Clean up SQLite files after test
    cleanup_sqlite "$HOME/perceptron_research/mgpusim/amd/samples/spmv"
    cleanup_sqlite "$HOME/mgpusim_original/amd/samples/spmv"
}

# Main test loop - test powers of 2 from 1024 to 16384
echo "🚀 Starting comprehensive tests..."
{
    echo "Comprehensive Perceptron vs LRU Performance Test Results"
    echo "======================================================="
    echo "Test started: $(date)"
    echo "Sparsity: ${SPARSITY}"
    echo ""
} > "$RESULTS_FILE"

current_size=$START_SIZE
while [ $current_size -le $END_SIZE ]; do
    test_matrix_size $current_size
    current_size=$((current_size * 2))
done

echo ""
echo "✅ All tests completed!"
echo ""
echo "📊 Results Summary:"
echo "=================="
echo "📁 Detailed results saved to: $RESULTS_FILE"
echo ""
echo "🔍 Quick Summary:"
grep -E "(Matrix Size|Miss-reduction)" "$RESULTS_FILE" | paste - - | while read -r matrix_line reduction_line; do
    matrix=$(echo "$matrix_line" | cut -d: -f2 | xargs)
    reduction=$(echo "$reduction_line" | cut -d: -f2 | xargs)
    printf "%-15s -> Miss Reduction: %s\n" "$matrix" "$reduction"
done

echo ""
echo "📈 Analysis:"
echo "- Check $RESULTS_FILE for detailed metrics"
echo "- Look for consistent miss reduction improvements"
echo "- Higher matrix sizes may show better perceptron performance"
echo "- Expected: 5-15% miss reduction, 2-8% hit rate improvement"
echo ""
echo "🎯 Performance Targets Met:"
if grep -q "Miss-reduction: [5-9]\|Miss-reduction: 1[0-5]" "$RESULTS_FILE"; then
    echo "✅ Miss reduction targets achieved (5-15%)"
else
    echo "⚠️  Check results - miss reduction may need tuning"
fi

echo ""
echo "🏁 Test completed successfully!"