#!/bin/bash

# Comprehensive KMeans Test Script
# Tests KMeans with perceptron vs LRU cache replacement
# Measures cache performance and timing metrics from database

set -e

echo "🚀 KMeans Comprehensive Perceptron vs LRU Test"
echo "============================================="
echo ""

TIMEOUT=1200
RESULTS_DIR="$HOME/perceptron_research/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_FILE="$RESULTS_DIR/kmeans_comprehensive_results_$TIMESTAMP.txt"

# Sweep points and features to modulate reuse; keep clusters moderate
POINT_SCALES=(1024)
FEATURES=(64 72 80 88 96 104 112 120 128)
CLUSTERS=16
MAX_ITER=5

mkdir -p "$RESULTS_DIR"

echo "📊 Test Configuration:"
echo "- Workload: KMeans"
echo "- Points: ${POINT_SCALES[@]}"
echo "- Features: ${FEATURES[@]}"
echo "- Clusters: $CLUSTERS, Max-Iter: $MAX_ITER"
echo "- Timeout per test: ${TIMEOUT}s"
echo "- Results file: $RESULTS_FILE"
echo ""

cat > "$RESULTS_FILE" << EOF
KMeans Comprehensive Perceptron vs LRU Test Results
===================================================
Test started: $(date)
Configuration:
- Points: ${POINT_SCALES[@]}
- Features: ${FEATURES[@]}
- Clusters: $CLUSTERS, Max-Iter: $MAX_ITER
- Timeout: ${TIMEOUT}s

Format: Points x Features | Policy | Hits | Misses | Hit-Rate | Total-Time | Avg-Latency | Miss-Reduction | Latency-Improvement
=============================================================================================================================

EOF

extract_metrics() {
    local db_file=$1
    if [ ! -f "$db_file" ]; then
        echo "0 0 0 0"
        return
    fi

    local cache_result=$(sqlite3 "$db_file" "SELECT \
        COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit') THEN Value END),0),\
        COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0)\
        FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';" 2>/dev/null)

    local total_time=$(sqlite3 "$db_file" "SELECT COALESCE(SUM(Value),0) FROM mgpusim_metrics WHERE What IN ('total_time','execution_time','total_execution_time');" 2>/dev/null)
    if [ "$total_time" = "0" ]; then
        total_time=$(sqlite3 "$db_file" "SELECT COALESCE(SUM(Value),0) FROM mgpusim_metrics WHERE What='kernel_time';" 2>/dev/null)
    fi

    local avg_latency=$(sqlite3 "$db_file" "SELECT COALESCE(AVG(Value),0) FROM mgpusim_metrics WHERE What='req_average_latency' AND Location LIKE '%L2Cache%';" 2>/dev/null)

    if [ -n "$cache_result" ] && [ -n "$total_time" ]; then
        local hits=$(echo "${cache_result%%|*}" | cut -d. -f1)
        local misses=$(echo "${cache_result##*|}" | cut -d. -f1)
        echo "$hits $misses $total_time $avg_latency"
    else
        echo "0 0 0 0"
    fi
}

run_kmeans_test() {
    local points=$1
    local feats=$2
    local repo_dir=$3
    local binary_name=$4

    cd "$repo_dir/amd/samples/kmeans"
    rm -f akita_sim*.sqlite3

    go build -o "$binary_name" > /dev/null 2>&1 || { echo "BUILD_FAILED 0 0 0"; return; }

    local flags="-points $points -features $feats -clusters $CLUSTERS -max-iter $MAX_ITER -timing -report-cache-hit-rate -report-cache-latency"

    timeout $TIMEOUT ./$binary_name $flags > /dev/null 2>&1
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        sleep 1
        local db=""
        for i in {1..10}; do
            db=$(ls -t akita_sim*.sqlite3 2>/dev/null | head -1)
            if [ -n "$db" ]; then
                local cnt=$(sqlite3 "$db" "SELECT COUNT(*) FROM mgpusim_metrics;" 2>/dev/null || echo 0)
                if [ "$cnt" -gt 0 ]; then
                    break
                fi
            fi
            sleep 1
        done
        if [ -n "$db" ]; then
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

test_combo() {
    local points=$1
    local feats=$2

    echo ""
    echo "🔬 Testing KMeans points=${points}, features=${feats}"
    echo "==============================================="

    echo "🔄 Testing Perceptron..."
    read p_hits p_misses p_hit_rate p_total_time p_avg_latency <<<$(run_kmeans_test "$points" "$feats" "/home/rami/perceptron_research/mgpusim" "kmeans_perc")
    echo "  ✅ Perceptron: hits=$p_hits, misses=$p_misses, hit-rate=$p_hit_rate%, total-time=${p_total_time}s, avg-latency=${p_avg_latency:-0}s"

    echo "🔄 Testing LRU..."
    read l_hits l_misses l_hit_rate l_total_time l_avg_latency <<<$(run_kmeans_test "$points" "$feats" "/home/rami/mgpusim_original" "kmeans_lru")
    echo "  ✅ LRU: hits=$l_hits, misses=$l_misses, hit-rate=$l_hit_rate%, total-time=${l_total_time}s, avg-latency=${l_avg_latency:-0}s"

    if [[ "$p_hits" =~ ^[0-9]+$ ]] && [[ "$l_hits" =~ ^[0-9]+$ ]] && [ "$p_misses" -gt 0 ] && [ "$l_misses" -gt 0 ]; then
        local miss_reduction=$(echo "scale=2; ($l_misses-$p_misses)*100/$l_misses" | bc -l)
        local l_latency_decimal=$(printf "%.10f" "$l_avg_latency")
        local p_latency_decimal=$(printf "%.10f" "$p_avg_latency")
        local latency_improvement="0"
        if (( $(echo "$l_latency_decimal > 0" | bc -l) )); then
            latency_improvement=$(echo "scale=2; ($l_latency_decimal-$p_latency_decimal)*100/$l_latency_decimal" | bc -l)
        fi

        cat >> "$RESULTS_FILE" << EOF

points=${points}, features=${feats} Results ($(date)):
------------------------------------------------------
Perceptron | $p_hits | $p_misses | $p_hit_rate% | ${p_total_time}s | ${p_avg_latency:-0}s
LRU        | $l_hits | $l_misses | $l_hit_rate% | ${l_total_time}s | ${l_avg_latency:-0}s
Improvements: Miss reduction: $miss_reduction%, Latency improvement: $latency_improvement%

EOF

        echo "📈 Results Summary:"
        printf "   Perceptron: hits=%-8s misses=%-8s hit-rate=%s%% total-time=%ss avg-latency=%ss\n" "$p_hits" "$p_misses" "$p_hit_rate" "$p_total_time" "${p_avg_latency:-0}"
        printf "   LRU:        hits=%-8s misses=%-8s hit-rate=%s%% total-time=%ss avg-latency=%ss\n" "$l_hits" "$l_misses" "$l_hit_rate" "$l_total_time" "${l_avg_latency:-0}"
        printf "   📊 Miss reduction: %s%%, Latency improvement: %s%%\n" "$miss_reduction" "$latency_improvement"

        if (( $(echo "$miss_reduction > 10" | bc -l) )); then
            echo "   🎉 EXCELLENT: >10% miss reduction!" | tee -a "$RESULTS_FILE"
        elif (( $(echo "$miss_reduction > 5" | bc -l) )); then
            echo "   🔥 GREAT: >5% miss reduction!" | tee -a "$RESULTS_FILE"
        fi

        if (( $(echo "$latency_improvement > 5" | bc -l 2>/dev/null || echo "0") )); then
            echo "   🚀 SPEEDY: >5% latency improvement!" | tee -a "$RESULTS_FILE"
        fi

        echo "✅ Results appended to: $RESULTS_FILE"
    else
        echo "   ❌ Test failed or incomplete results"
        cat >> "$RESULTS_FILE" << EOF

points=${points}, features=${feats} Results ($(date)):
------------------------------------------------------
❌ FAILED - Perceptron: $p_hits $p_misses $p_hit_rate $p_total_time ${p_avg_latency:-0}
❌ FAILED - LRU: $l_hits $l_misses $l_hit_rate $l_total_time ${l_avg_latency:-0}

EOF
    fi
}

echo "🧪 Starting KMeans comprehensive tests..."
echo ""

total_tests=$(( ${#POINT_SCALES[@]} * ${#FEATURES[@]} ))
current_test=0
for pts in "${POINT_SCALES[@]}"; do
  for feats in "${FEATURES[@]}"; do
    current_test=$((current_test + 1))
    echo "🔄 Progress: Test $current_test/$total_tests"
    test_combo "$pts" "$feats"
  done
done

echo ""
echo "🎯 All Tests Completed!"
echo "======================="
cat >> "$RESULTS_FILE" << EOF

=====================================================================================================
Test completed: $(date)
Total tests run: $total_tests combinations
Results file: $RESULTS_FILE

🔍 To view full results: cat $RESULTS_FILE
EOF

echo "Test finished: $(date)"
echo "📊 Complete results saved to: $RESULTS_FILE"
echo ""
echo "🔍 To view results:"
echo "   cat $RESULTS_FILE"
echo "   tail -n 50 $RESULTS_FILE  # View recent results"


