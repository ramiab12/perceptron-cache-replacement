#!/bin/bash

# Direct comparison between LRU and Perceptron with different parameters
set -e

echo "🔬 Direct LRU vs Perceptron Comparison"
echo "======================================"

cd "$(dirname "$0")/.."

MATRIX_SIZE=1024
SPARSITY=0.01
FLAGS="-dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate"

echo "📊 Configuration: ${MATRIX_SIZE}x${MATRIX_SIZE}, sparsity=${SPARSITY}"
echo ""

# Function to run test and get metrics
run_test() {
    local binary_name=$1
    local config_name=$2
    
    cd mgpusim/amd/samples/spmv
    go build -o "$binary_name" 2>/dev/null
    rm -f akita_sim*.sqlite3
    
    echo "  Running $config_name simulation..."
    timeout 180s ./"$binary_name" $FLAGS >/dev/null 2>&1 || true
    
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
            echo "  ✅ $config_name: Hits=$hits, Misses=$misses, Hit Rate=${hit_rate}%"
            echo "$hits $misses $hit_rate"
        else
            echo "  ❌ $config_name: No valid results"
            echo "0 0 0"
        fi
        rm -f akita_sim*.sqlite3
    else
        echo "  ❌ $config_name: No database generated"
        echo "0 0 0"
    fi
    
    cd ../../..
}

# Test 1: LRU Baseline
echo "🏷️  Test 1: LRU Baseline"
sed -i 's/WithPerceptronVictimFinder()/\/\/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go

lru_result=$(run_test "spmv_lru" "LRU")
read -r lru_hits lru_misses lru_hit_rate <<< "$lru_result"

# Re-enable perceptron
sed -i 's/\/\/WithPerceptronVictimFinder()/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go

echo ""

# Test 2: Original Perceptron Parameters
echo "🏷️  Test 2: Original Perceptron (τ=3, θ=68, lr=1)"
sed -i "s/return NewPerceptronVictimFinderWithParams([0-9]*, [0-9]*, [0-9]*)/return NewPerceptronVictimFinderWithParams(3, 68, 1)/" \
    akita/mem/cache/perceptron_victimfinder.go

orig_result=$(run_test "spmv_orig" "Original Perceptron")
read -r orig_hits orig_misses orig_hit_rate <<< "$orig_result"

echo ""

# Test 3: Aggressive Parameters
echo "🏷️  Test 3: Aggressive Perceptron (τ=1, θ=32, lr=2)"
sed -i "s/return NewPerceptronVictimFinderWithParams([0-9]*, [0-9]*, [0-9]*)/return NewPerceptronVictimFinderWithParams(1, 32, 2)/" \
    akita/mem/cache/perceptron_victimfinder.go

aggr_result=$(run_test "spmv_aggr" "Aggressive Perceptron")
read -r aggr_hits aggr_misses aggr_hit_rate <<< "$aggr_result"

echo ""

# Test 4: Conservative Parameters  
echo "🏷️  Test 4: Conservative Perceptron (τ=5, θ=96, lr=1)"
sed -i "s/return NewPerceptronVictimFinderWithParams([0-9]*, [0-9]*, [0-9]*)/return NewPerceptronVictimFinderWithParams(5, 96, 1)/" \
    akita/mem/cache/perceptron_victimfinder.go

cons_result=$(run_test "spmv_cons" "Conservative Perceptron")
read -r cons_hits cons_misses cons_hit_rate <<< "$cons_result"

echo ""

# Test 5: High Learning Rate
echo "🏷️  Test 5: High Learning Rate (τ=3, θ=68, lr=3)"
sed -i "s/return NewPerceptronVictimFinderWithParams([0-9]*, [0-9]*, [0-9]*)/return NewPerceptronVictimFinderWithParams(3, 68, 3)/" \
    akita/mem/cache/perceptron_victimfinder.go

high_result=$(run_test "spmv_high" "High Learning Rate")
read -r high_hits high_misses high_hit_rate <<< "$high_result"

# Display Results
echo ""
echo "📊 Comparison Results"
echo "===================="
printf "%-20s %-8s %-8s %-10s %-15s\n" "Configuration" "Hits" "Misses" "Hit Rate" "Miss Reduction"
echo "-----------------------------------------------------------------------"

printf "%-20s %-8s %-8s %-10s %-15s\n" "LRU Baseline" "$lru_hits" "$lru_misses" "${lru_hit_rate}%" "baseline"

if [ "$lru_misses" -gt 0 ]; then
    if [ "$orig_hits" -gt 0 ]; then
        orig_reduction=$(echo "scale=2; ($lru_misses-$orig_misses)*100/$lru_misses" | bc)
        printf "%-20s %-8s %-8s %-10s %-15s\n" "Original (3,68,1)" "$orig_hits" "$orig_misses" "${orig_hit_rate}%" "${orig_reduction}%"
    fi
    
    if [ "$aggr_hits" -gt 0 ]; then
        aggr_reduction=$(echo "scale=2; ($lru_misses-$aggr_misses)*100/$lru_misses" | bc)
        printf "%-20s %-8s %-8s %-10s %-15s\n" "Aggressive (1,32,2)" "$aggr_hits" "$aggr_misses" "${aggr_hit_rate}%" "${aggr_reduction}%"
    fi
    
    if [ "$cons_hits" -gt 0 ]; then
        cons_reduction=$(echo "scale=2; ($lru_misses-$cons_misses)*100/$lru_misses" | bc)
        printf "%-20s %-8s %-8s %-10s %-15s\n" "Conservative (5,96,1)" "$cons_hits" "$cons_misses" "${cons_hit_rate}%" "${cons_reduction}%"
    fi
    
    if [ "$high_hits" -gt 0 ]; then
        high_reduction=$(echo "scale=2; ($lru_misses-$high_misses)*100/$lru_misses" | bc)
        printf "%-20s %-8s %-8s %-10s %-15s\n" "High Learning (3,68,3)" "$high_hits" "$high_misses" "${high_hit_rate}%" "${high_reduction}%"
    fi
fi

echo ""
echo "🎯 Best miss reduction configuration identified!"
echo "💡 Use the configuration with the highest miss reduction percentage."