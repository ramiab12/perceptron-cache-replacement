#!/bin/bash

# Quick comparison between LRU and Perceptron with current parameters
set -e

echo "🚀 Quick LRU vs Perceptron Comparison"
echo "====================================="

cd "$(dirname "$0")/.."

FLAGS="-dim 1024 -sparsity 0.01 -timing -report-cache-hit-rate"

# Function to run test
run_test() {
    local name=$1
    local binary=$2
    
    echo "Testing $name..."
    cd mgpusim/amd/samples/spmv
    go build -o "$binary" 2>/dev/null
    rm -f akita_sim*.sqlite3
    
    timeout 300s ./"$binary" $FLAGS >/dev/null 2>&1 || true
    
    if ls akita_sim*.sqlite3 1> /dev/null 2>&1; then
        db=$(ls -t akita_sim*.sqlite3 | head -1)
        result=$(sqlite3 "$db" "SELECT COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit') THEN Value END),0), COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0) FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';" 2>/dev/null || echo "0|0")
        
        hits=$(echo "${result%%|*}" | cut -d. -f1)
        misses=$(echo "${result##*|}" | cut -d. -f1)
        
        if [ -n "$hits" ] && [ -n "$misses" ] && [ "$hits" -gt 0 ]; then
            hit_rate=$(echo "scale=2; ($hits*100)/($hits+$misses)" | bc)
            echo "  ✅ $name: Hits=$hits, Misses=$misses, Hit Rate=${hit_rate}%"
            echo "$hits $misses $hit_rate"
        else
            echo "  ❌ $name: Failed"
            echo "0 0 0"
        fi
        rm -f akita_sim*.sqlite3
    else
        echo "  ❌ $name: No database"
        echo "0 0 0"
    fi
    
    cd ../../..
}

# Test 1: LRU
echo "🏷️  Test 1: LRU Baseline"
sed -i 's/WithPerceptronVictimFinder()/\/\/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go

lru_result=$(run_test "LRU" "spmv_lru")
read -r lru_hits lru_misses lru_hit_rate <<< "$lru_result"

echo ""

# Test 2: Current Perceptron
echo "🏷️  Test 2: Current Perceptron (τ=3, θ=68, lr=3)"
sed -i 's/\/\/WithPerceptronVictimFinder()/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go

perc_result=$(run_test "Perceptron" "spmv_perc")
read -r perc_hits perc_misses perc_hit_rate <<< "$perc_result"

# Results
echo ""
echo "📊 Quick Comparison Results"
echo "=========================="
printf "%-15s %-8s %-8s %-10s %-15s\n" "Configuration" "Hits" "Misses" "Hit Rate" "Miss Reduction"
echo "------------------------------------------------------------"

printf "%-15s %-8s %-8s %-10s %-15s\n" "LRU" "$lru_hits" "$lru_misses" "${lru_hit_rate}%" "baseline"

if [ "$lru_misses" -gt 0 ] && [ "$perc_hits" -gt 0 ]; then
    reduction=$(echo "scale=2; ($lru_misses-$perc_misses)*100/$lru_misses" | bc)
    printf "%-15s %-8s %-8s %-10s %-15s\n" "Perceptron" "$perc_hits" "$perc_misses" "${perc_hit_rate}%" "${reduction}%"
    
    echo ""
    if (( $(echo "$reduction > 0" | bc -l) )); then
        echo "🎉 SUCCESS: Perceptron achieves ${reduction}% miss reduction!"
    else
        echo "⚠️  Current parameters need tuning. Miss reduction: ${reduction}%"
    fi
else
    echo "❌ Unable to calculate miss reduction"
fi

echo ""
echo "🎯 Current perceptron parameters: τ=3, θ=68, lr=3"