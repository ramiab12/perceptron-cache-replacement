#!/bin/bash

# Quick parameter tuning script - tests a few key combinations
# For faster iteration during development

set -e

echo "⚡ Quick Perceptron Parameter Tuning"
echo "==================================="
echo ""

# Test configuration  
MATRIX_SIZE=1024
SPARSITY=0.01
TEST_FLAGS="-dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate"

echo "📊 Quick Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo ""

cd "$(dirname "$0")/.."

# Function to test parameters and get miss count
test_params() {
    local threshold=$1
    local theta=$2 
    local learning_rate=$3
    local label=$4
    
    echo "🧪 Testing $label: τ=$threshold, θ=$theta, lr=$learning_rate"
    
    # Update parameters
    sed -i "s/return NewPerceptronVictimFinderWithParams([0-9]*, [0-9]*, [0-9]*)/return NewPerceptronVictimFinderWithParams($threshold, $theta, $learning_rate)/" \
        akita/mem/cache/perceptron_victimfinder.go
    
    cd mgpusim/amd/samples/spmv
    go build -o spmv_quick 2>/dev/null
    rm -f akita_sim*.sqlite3
    
    timeout 120s ./spmv_quick $TEST_FLAGS >/dev/null 2>&1 || true
    
    if ls akita_sim*.sqlite3 1> /dev/null 2>&1; then
        db=$(ls -t akita_sim*.sqlite3 | head -1)
        result=$(sqlite3 "$db" \
          "SELECT \
           COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit')  THEN Value END),0), \
           COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0) \
           FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';" 2>/dev/null || echo "0|0")
        
        hits=$(echo "${result%%|*}" | cut -d. -f1)
        misses=$(echo "${result##*|}" | cut -d. -f1)
        
        if [ -n "$hits" ] && [ -n "$misses" ] && [ "$hits" -gt 0 ]; then
            hit_rate=$(echo "scale=2; ($hits*100)/($hits+$misses)" | bc)
            echo "  ✅ Hits: $hits, Misses: $misses, Hit Rate: ${hit_rate}%"
            echo "$hits $misses"
        else
            echo "  ❌ No valid metrics"
            echo "0 0"
        fi
        rm -f akita_sim*.sqlite3
    else
        echo "  ❌ Test failed"
        echo "0 0"
    fi
    
    cd ../../..
}

# Get LRU baseline
echo "📊 Getting LRU baseline..."
sed -i 's/WithPerceptronVictimFinder()/\/\/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go

cd mgpusim/amd/samples/spmv
go build -o spmv_lru 2>/dev/null
rm -f akita_sim*.sqlite3
timeout 120s ./spmv_lru $TEST_FLAGS >/dev/null 2>&1 || true

lru_hits=0
lru_misses=0
if ls akita_sim*.sqlite3 1> /dev/null 2>&1; then
    db=$(ls -t akita_sim*.sqlite3 | head -1)
    result=$(sqlite3 "$db" \
      "SELECT \
       COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit')  THEN Value END),0), \
       COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0) \
       FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';" 2>/dev/null || echo "0|0")
    
    lru_hits=$(echo "${result%%|*}" | cut -d. -f1)
    lru_misses=$(echo "${result##*|}" | cut -d. -f1)
    
    if [ -n "$lru_hits" ] && [ -n "$lru_misses" ] && [ "$lru_hits" -gt 0 ]; then
        lru_hit_rate=$(echo "scale=2; ($lru_hits*100)/($lru_hits+$lru_misses)" | bc)
        echo "  📊 LRU Baseline: Hits: $lru_hits, Misses: $lru_misses, Hit Rate: ${lru_hit_rate}%"
    fi
    rm -f akita_sim*.sqlite3
fi

# Re-enable perceptron
sed -i 's/\/\/WithPerceptronVictimFinder()/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go
cd ../../..

echo ""
echo "🔍 Testing key parameter combinations..."

# Test configurations
declare -A results
declare -A configs

configs["original"]="3 68 1"
configs["aggressive"]="1 32 2" 
configs["conservative"]="5 96 1"
configs["balanced"]="2 48 2"
configs["high_threshold"]="7 128 1"

for name in "${!configs[@]}"; do
    read -r threshold theta learning_rate <<< "${configs[$name]}"
    result=$(test_params "$threshold" "$theta" "$learning_rate" "$name")
    hits=$(echo "$result" | tail -1 | cut -d' ' -f1)
    misses=$(echo "$result" | tail -1 | cut -d' ' -f2)
    results["$name"]="$hits $misses"
done

echo ""
echo "📈 Quick Results Summary:"
echo "========================"
printf "%-12s %-8s %-8s %-10s %-12s\n" "Config" "Hits" "Misses" "Hit Rate" "Miss Reduction"
echo "--------------------------------------------------------"

printf "%-12s %-8s %-8s %-10s %-12s\n" "LRU" "$lru_hits" "$lru_misses" "${lru_hit_rate}%" "baseline"

for name in "${!results[@]}"; do
    read -r hits misses <<< "${results[$name]}"
    if [ "$hits" -gt 0 ] && [ "$misses" -gt 0 ]; then
        hit_rate=$(echo "scale=2; ($hits*100)/($hits+$misses)" | bc)
        if [ "$lru_misses" -gt 0 ]; then
            reduction=$(echo "scale=2; ($lru_misses-$misses)*100/$lru_misses" | bc)
            printf "%-12s %-8s %-8s %-10s %-12s\n" "$name" "$hits" "$misses" "${hit_rate}%" "${reduction}%"
        fi
    fi
done

echo ""
echo "🎯 Use the best configuration for comprehensive testing!"