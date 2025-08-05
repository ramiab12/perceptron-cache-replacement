#!/bin/bash

# Simplified Comprehensive SPMV Test Script
# Tests SPMV workload with perceptron vs LRU cache replacement
# Measures cache performance AND kernel execution time from database
# Single results file with appended results as tests complete

set -e

echo "🚀 SPMV Comprehensive Perceptron vs LRU Test"
echo "============================================"
echo ""

# Test parameters
SPARSITY=0.01
FIXED_SEED=12345
TIMEOUT=900  # 15 minutes per test
RESULTS_DIR="$HOME/perceptron_research/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/spmv_comprehensive_results_$TIMESTAMP.txt"

# Matrix sizes to test (up to 4096 as requested)
MATRIX_SIZES=(1024 2048 4096 8192 16384)

# Create results directory
mkdir -p "$RESULTS_DIR"

echo "📊 Test Configuration:"
echo "- Workload: SPMV (Sparse Matrix-Vector Multiplication)"
echo "- Matrix sizes: ${MATRIX_SIZES[@]}"
echo "- Sparsity: $SPARSITY"
echo "- Fixed seed: $FIXED_SEED"
echo "- Timeout per test: ${TIMEOUT}s"
echo "- Results file: $RESULTS_FILE"
echo ""

# Initialize results file with header
cat > "$RESULTS_FILE" << EOF
SPMV Comprehensive Perceptron vs LRU Test Results
================================================
Test started: $(date)
Configuration:
- Matrix sizes: ${MATRIX_SIZES[@]}
- Sparsity: $SPARSITY
- Fixed seed: $FIXED_SEED
- Timeout: ${TIMEOUT}s

Format: Size | Policy | Hits | Misses | Hit-Rate | Kernel-Time | Miss-Reduction | Time-Improvement
=====================================================================================================

EOF

# Function to extract metrics from database
extract_metrics() {
    local db_file=$1
    
    if [ ! -f "$db_file" ]; then
        echo "0 0 0"
        return
    fi
    
    # Extract cache hits/misses
    local cache_result=$(sqlite3 "$db_file" "SELECT 
        COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit') THEN Value END),0),
        COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0)
        FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';" 2>/dev/null)
    
    # Extract kernel execution time
    local kernel_time=$(sqlite3 "$db_file" "SELECT 
        COALESCE(SUM(Value),0) 
        FROM mgpusim_metrics WHERE What='kernel_time';" 2>/dev/null)
    
    if [ -n "$cache_result" ] && [ -n "$kernel_time" ]; then
        local hits=$(echo "${cache_result%%|*}" | cut -d. -f1)
        local misses=$(echo "${cache_result##*|}" | cut -d. -f1)
        echo "$hits $misses $kernel_time"
    else
        echo "0 0 0"
    fi
}

# Function to run a single SPMV test
run_spmv_test() {
    local size=$1
    local policy=$2
    local repo_dir=$3
    local binary_name=$4
    
    cd "$repo_dir/amd/samples/spmv"
    
    # Clean previous results
    rm -f akita_sim*.sqlite3
    
    # Build binary quietly
    go build -o "$binary_name" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "BUILD_FAILED 0 0 0" >&2
        return
    fi
    
    # Prepare command
    local flags="-dim $size -sparsity $SPARSITY -seed $FIXED_SEED -timing -report-cache-hit-rate"
    
    # Run test with timeout
    timeout $TIMEOUT ./$binary_name $flags > /dev/null 2>&1
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        # Get the latest database
        local db=$(ls -t akita_sim*.sqlite3 2>/dev/null | head -1)
        if [ -n "$db" ]; then
            # Extract metrics
            read hits misses kernel_time <<<$(extract_metrics "$db")
            
            if [ "$hits" -gt 0 ] || [ "$misses" -gt 0 ]; then
                local total=$((hits + misses))
                local hit_rate=$(echo "scale=2; ($hits*100)/($total)" | bc 2>/dev/null || echo "0")
                
                echo "$hits $misses $hit_rate $kernel_time"
            else
                echo "NO_METRICS 0 0 0"
            fi
        else
            echo "NO_DATABASE 0 0 0"
        fi
    elif [ $exit_code -eq 124 ]; then
        echo "TIMEOUT 0 0 0"
    else
        echo "FAILED 0 0 0"
    fi
}

# Function to test a specific matrix size
test_matrix_size() {
    local size=$1
    
    echo ""
    echo "🔬 Testing SPMV ${size}x${size} Matrix"
    echo "======================================"
    
    # Test perceptron
    echo "🔄 Testing Perceptron..."
    read p_hits p_misses p_hit_rate p_kernel_time <<<$(run_spmv_test "$size" "Perceptron" "/home/rami/perceptron_research/mgpusim" "spmv_perc")
    echo "  ✅ Perceptron: hits=$p_hits, misses=$p_misses, hit-rate=$p_hit_rate%, kernel-time=${p_kernel_time}s"
    
    # Test LRU
    echo "🔄 Testing LRU..."
    read l_hits l_misses l_hit_rate l_kernel_time <<<$(run_spmv_test "$size" "LRU" "/home/rami/mgpusim_original" "spmv_lru")
    echo "  ✅ LRU: hits=$l_hits, misses=$l_misses, hit-rate=$l_hit_rate%, kernel-time=${l_kernel_time}s"
    
    # Calculate improvements and append to results file
    if [[ "$p_hits" =~ ^[0-9]+$ ]] && [[ "$l_hits" =~ ^[0-9]+$ ]] && [ "$p_misses" -gt 0 ] && [ "$l_misses" -gt 0 ]; then
        local miss_reduction=$(echo "scale=2; ($l_misses-$p_misses)*100/$l_misses" | bc -l)
        # Convert scientific notation to decimal for bc
        local l_time_decimal=$(printf "%.10f" "$l_kernel_time")
        local p_time_decimal=$(printf "%.10f" "$p_kernel_time")
        local time_improvement=$(echo "scale=2; ($l_time_decimal-$p_time_decimal)*100/$l_time_decimal" | bc -l)
        
        # Append results to file
        cat >> "$RESULTS_FILE" << EOF

${size}x${size} Matrix Results ($(date)):
------------------------------------------
Perceptron | $p_hits | $p_misses | $p_hit_rate% | ${p_kernel_time}s
LRU        | $l_hits | $l_misses | $l_hit_rate% | ${l_kernel_time}s
Improvements: Miss reduction: $miss_reduction%, Time improvement: $time_improvement%

EOF
        
        echo "📈 Results Summary:"
        printf "   Perceptron: hits=%-8s misses=%-8s hit-rate=%s%% kernel-time=%ss\n" "$p_hits" "$p_misses" "$p_hit_rate" "$p_kernel_time"
        printf "   LRU:        hits=%-8s misses=%-8s hit-rate=%s%% kernel-time=%ss\n" "$l_hits" "$l_misses" "$l_hit_rate" "$l_kernel_time"
        printf "   📊 Miss reduction: %s%%, Time improvement: %s%%\n" "$miss_reduction" "$time_improvement"
        
        # Highlight exceptional results
        if (( $(echo "$miss_reduction > 10" | bc -l) )); then
            echo "   🎉 EXCELLENT: >10% miss reduction!" | tee -a "$RESULTS_FILE"
        elif (( $(echo "$miss_reduction > 5" | bc -l) )); then
            echo "   🔥 GREAT: >5% miss reduction!" | tee -a "$RESULTS_FILE"
        fi
        
        if (( $(echo "$time_improvement > 5" | bc -l) )); then
            echo "   ⚡ FAST: >5% execution time improvement!" | tee -a "$RESULTS_FILE"
        fi
        
        # Real-time append to show progress
        echo "✅ Results appended to: $RESULTS_FILE"
        
    else
        echo "   ❌ Test failed or incomplete results"
        cat >> "$RESULTS_FILE" << EOF

${size}x${size} Matrix Results ($(date)):
------------------------------------------
❌ FAILED - Perceptron: $p_hits $p_misses $p_hit_rate $p_kernel_time
❌ FAILED - LRU: $l_hits $l_misses $l_hit_rate $l_kernel_time

EOF
    fi
}

# Main test execution
echo "🧪 Starting SPMV comprehensive tests..."
echo ""

total_tests=${#MATRIX_SIZES[@]}
current_test=0

for size in "${MATRIX_SIZES[@]}"; do
    current_test=$((current_test + 1))
    echo "🔄 Progress: Test $current_test/$total_tests"
    test_matrix_size "$size"
done

# Final summary
echo ""
echo "🎯 All Tests Completed!"
echo "======================="
cat >> "$RESULTS_FILE" << EOF

=====================================================================================================
Test completed: $(date)
Total tests run: $total_tests matrix sizes
Results file: $RESULTS_FILE

🔍 To view full results: cat $RESULTS_FILE
EOF

echo "Test finished: $(date)"
echo "📊 Complete results saved to: $RESULTS_FILE"
echo ""
echo "🔍 To view results:"
echo "   cat $RESULTS_FILE"
echo "   tail -n 50 $RESULTS_FILE  # View recent results"