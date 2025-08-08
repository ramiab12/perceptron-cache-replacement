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
MATRIX_SIZES=(1024 2048 3072 4096 5120 6144 7168 8192)

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

Format: Size | Policy | Hits | Misses | Hit-Rate | Total-Time | Avg-Latency | Miss-Reduction | Latency-Improvement
==================================================================================================================

EOF

# Function to extract metrics from database
extract_metrics() {
    local db_file=$1
    
    if [ ! -f "$db_file" ]; then
        echo "0 0 0 0"
        return
    fi
    
    # Extract cache hits/misses
    local cache_result=$(sqlite3 "$db_file" "SELECT 
        COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit') THEN Value END),0),
        COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0)
        FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';" 2>/dev/null)
    
    # Extract total execution time (try different possible metric names)
    local total_time=$(sqlite3 "$db_file" "SELECT 
        COALESCE(SUM(Value),0) 
        FROM mgpusim_metrics WHERE What='total_time' OR What='execution_time' OR What='total_execution_time';" 2>/dev/null)
    
    # Fallback to kernel_time if total_time not found
    if [ "$total_time" = "0" ]; then
        total_time=$(sqlite3 "$db_file" "SELECT 
            COALESCE(SUM(Value),0) 
            FROM mgpusim_metrics WHERE What='kernel_time';" 2>/dev/null)
    fi
    
    # Extract average request latency for L2 cache
    local avg_latency=$(sqlite3 "$db_file" "SELECT 
        COALESCE(AVG(Value),0) 
        FROM mgpusim_metrics WHERE What='req_average_latency' AND Location LIKE '%L2Cache%';" 2>/dev/null)
    
    # Debug: Check what latency metrics are available
    if [ "$avg_latency" = "0" ] || [ -z "$avg_latency" ]; then
        local available_latency=$(sqlite3 "$db_file" "SELECT DISTINCT What, Location FROM mgpusim_metrics WHERE What LIKE '%latency%' OR What LIKE '%Latency%';" 2>/dev/null)
        if [ -n "$available_latency" ]; then
            echo "DEBUG: Available latency metrics: $available_latency" >&2
        fi
        
        # Try alternative latency queries
        local alt_latency=$(sqlite3 "$db_file" "SELECT COALESCE(AVG(Value),0) FROM mgpusim_metrics WHERE What='req_average_latency';" 2>/dev/null)
        if [ -n "$alt_latency" ] && [ "$alt_latency" != "0" ]; then
            avg_latency="$alt_latency"
            echo "DEBUG: Found alternative latency: $avg_latency" >&2
        fi
    fi
    
    if [ -n "$cache_result" ] && [ -n "$total_time" ]; then
        local hits=$(echo "${cache_result%%|*}" | cut -d. -f1)
        local misses=$(echo "${cache_result##*|}" | cut -d. -f1)
        echo "$hits $misses $total_time $avg_latency"
    else
        echo "0 0 0 0"
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
    local flags="-dim $size -sparsity $SPARSITY -timing -report-cache-hit-rate -report-all"
    
    # Run test with timeout
    timeout $TIMEOUT ./$binary_name $flags > /dev/null 2>&1
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        # Get the latest database
        local db=$(ls -t akita_sim*.sqlite3 2>/dev/null | head -1)
        if [ -n "$db" ]; then
            # Extract metrics
            read hits misses total_time avg_latency <<<$(extract_metrics "$db")
            
            if [ "$hits" -gt 0 ] || [ "$misses" -gt 0 ]; then
                local total=$((hits + misses))
                local hit_rate=$(echo "scale=2; ($hits*100)/($total)" | bc 2>/dev/null || echo "0")
                
                echo "$hits $misses $hit_rate $total_time $avg_latency"
            else
                echo "NO_METRICS 0 0 0 0"
            fi
        else
            echo "NO_DATABASE 0 0 0 0"
        fi
    elif [ $exit_code -eq 124 ]; then
        echo "TIMEOUT 0 0 0 0"
    else
        echo "FAILED 0 0 0 0"
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
    read p_hits p_misses p_hit_rate p_total_time p_avg_latency <<<$(run_spmv_test "$size" "Perceptron" "/home/rami/perceptron_research/mgpusim" "spmv_perc")
    echo "  ✅ Perceptron: hits=$p_hits, misses=$p_misses, hit-rate=$p_hit_rate%, total-time=${p_total_time}s, avg-latency=${p_avg_latency:-0}s"
    
    # Test LRU
    echo "🔄 Testing LRU..."
    read l_hits l_misses l_hit_rate l_total_time l_avg_latency <<<$(run_spmv_test "$size" "LRU" "/home/rami/mgpusim_original" "spmv_lru")
    echo "  ✅ LRU: hits=$l_hits, misses=$l_misses, hit-rate=$l_hit_rate%, total-time=${l_total_time}s, avg-latency=${l_avg_latency:-0}s"
    
    # Calculate improvements and append to results file
    if [[ "$p_hits" =~ ^[0-9]+$ ]] && [[ "$l_hits" =~ ^[0-9]+$ ]] && [ "$p_misses" -gt 0 ] && [ "$l_misses" -gt 0 ]; then
        local miss_reduction=$(echo "scale=2; ($l_misses-$p_misses)*100/$l_misses" | bc -l)
        
        # Calculate latency improvement (handle zero latency case)
        local l_latency_decimal=$(printf "%.10f" "$l_avg_latency")
        local p_latency_decimal=$(printf "%.10f" "$p_avg_latency")
        local latency_improvement="0"
        if (( $(echo "$l_latency_decimal > 0" | bc -l) )); then
            latency_improvement=$(echo "scale=2; ($l_latency_decimal-$p_latency_decimal)*100/$l_latency_decimal" | bc -l)
        fi
        
        # Append results to file
        cat >> "$RESULTS_FILE" << EOF

${size}x${size} Matrix Results ($(date)):
------------------------------------------
Perceptron | $p_hits | $p_misses | $p_hit_rate% | ${p_total_time}s | ${p_avg_latency:-0}s
LRU        | $l_hits | $l_misses | $l_hit_rate% | ${l_total_time}s | ${l_avg_latency:-0}s
Improvements: Miss reduction: $miss_reduction%, Latency improvement: $latency_improvement%

EOF
        
        echo "📈 Results Summary:"
        printf "   Perceptron: hits=%-8s misses=%-8s hit-rate=%s%% total-time=%ss avg-latency=%ss\n" "$p_hits" "$p_misses" "$p_hit_rate" "$p_total_time" "${p_avg_latency:-0}"
        printf "   LRU:        hits=%-8s misses=%-8s hit-rate=%s%% total-time=%ss avg-latency=%ss\n" "$l_hits" "$l_misses" "$l_hit_rate" "$l_total_time" "${l_avg_latency:-0}"
        printf "   📊 Miss reduction: %s%%, Latency improvement: %s%%\n" "$miss_reduction" "$latency_improvement"
        
        # Highlight exceptional results
        if (( $(echo "$miss_reduction > 10" | bc -l) )); then
            echo "   🎉 EXCELLENT: >10% miss reduction!" | tee -a "$RESULTS_FILE"
        elif (( $(echo "$miss_reduction > 5" | bc -l) )); then
            echo "   🔥 GREAT: >5% miss reduction!" | tee -a "$RESULTS_FILE"
        fi
        

        
        if (( $(echo "$latency_improvement > 5" | bc -l 2>/dev/null || echo "0") )); then
            echo "   🚀 SPEEDY: >5% latency improvement!" | tee -a "$RESULTS_FILE"
        fi
        
        # Real-time append to show progress
        echo "✅ Results appended to: $RESULTS_FILE"
        
    else
        echo "   ❌ Test failed or incomplete results"
        cat >> "$RESULTS_FILE" << EOF

${size}x${size} Matrix Results ($(date)):
------------------------------------------
❌ FAILED - Perceptron: $p_hits $p_misses $p_hit_rate $p_total_time ${p_avg_latency:-0}
❌ FAILED - LRU: $l_hits $l_misses $l_hit_rate $l_total_time ${l_avg_latency:-0}

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