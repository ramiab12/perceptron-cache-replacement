#!/bin/bash

# Simple parameter tuning script
set -e

echo "🎯 Simple Perceptron Parameter Tuning"
echo "====================================="

cd "$(dirname "$0")/.."

# Function to test parameters
test_params() {
    local threshold=$1
    local theta=$2
    local lr=$3
    local label=$4
    
    echo ""
    echo "Testing $label (τ=$threshold, θ=$theta, lr=$lr)..."
    
    # Update parameters
    sed -i "s/return NewPerceptronVictimFinderWithParams([0-9]*, [0-9]*, [0-9]*)/return NewPerceptronVictimFinderWithParams($threshold, $theta, $lr)/" \
        akita/mem/cache/perceptron_victimfinder.go
    
    cd mgpusim/amd/samples/spmv
    go build -o spmv_tune 2>/dev/null
    rm -f akita_sim*.sqlite3
    
    timeout 300s ./spmv_tune -dim 1024 -sparsity 0.01 -timing -report-cache-hit-rate >/dev/null 2>&1 || true
    
    if ls akita_sim*.sqlite3 1> /dev/null 2>&1; then
        db=$(ls -t akita_sim*.sqlite3 | head -1)
        result=$(sqlite3 "$db" "SELECT COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit') THEN Value END),0), COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0) FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';" 2>/dev/null || echo "0|0")
        
        hits=$(echo "${result%%|*}" | cut -d. -f1)
        misses=$(echo "${result##*|}" | cut -d. -f1)
        
        if [ -n "$hits" ] && [ -n "$misses" ] && [ "$hits" -gt 0 ]; then
            hit_rate=$(echo "scale=2; ($hits*100)/($hits+$misses)" | bc)
            echo "  ✅ Hits: $hits, Misses: $misses, Hit Rate: ${hit_rate}%"
            echo "$hits $misses"
        else
            echo "  ❌ Failed"
            echo "0 0"
        fi
        rm -f akita_sim*.sqlite3
    else
        echo "  ❌ No database"
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
timeout 300s ./spmv_lru -dim 1024 -sparsity 0.01 -timing -report-cache-hit-rate >/dev/null 2>&1 || true

lru_hits=0
lru_misses=0
if ls akita_sim*.sqlite3 1> /dev/null 2>&1; then
    db=$(ls -t akita_sim*.sqlite3 | head -1)
    result=$(sqlite3 "$db" "SELECT COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit') THEN Value END),0), COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END),0) FROM mgpusim_metrics WHERE Location LIKE '%L2Cache%';" 2>/dev/null || echo "0|0")
    
    lru_hits=$(echo "${result%%|*}" | cut -d. -f1)
    lru_misses=$(echo "${result##*|}" | cut -d. -f1)
    
    if [ -n "$lru_hits" ] && [ -n "$lru_misses" ] && [ "$lru_hits" -gt 0 ]; then
        lru_hit_rate=$(echo "scale=2; ($lru_hits*100)/($lru_hits+$lru_misses)" | bc)
        echo "  LRU: Hits=$lru_hits, Misses=$lru_misses, Hit Rate=${lru_hit_rate}%"
    fi
    rm -f akita_sim*.sqlite3
fi

# Re-enable perceptron
sed -i 's/\/\/WithPerceptronVictimFinder()/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go
cd ../../..

# Test configurations
echo ""
echo "🔍 Testing parameter configurations..."

# Configuration 1: Original
result1=$(test_params 3 68 1 "Original")
read -r hits1 misses1 <<< "$result1"

# Configuration 2: Aggressive  
result2=$(test_params 1 32 2 "Aggressive")
read -r hits2 misses2 <<< "$result2"

# Configuration 3: Conservative
result3=$(test_params 5 96 1 "Conservative") 
read -r hits3 misses3 <<< "$result3"

# Configuration 4: High Learning
result4=$(test_params 3 68 3 "High Learning")
read -r hits4 misses4 <<< "$result4"

# Configuration 5: Low Threshold
result5=$(test_params 1 68 1 "Low Threshold")
read -r hits5 misses5 <<< "$result5"

# Display results
echo ""
echo "📊 Results Summary"
echo "=================="
printf "%-15s %-8s %-8s %-10s %-15s\n" "Config" "Hits" "Misses" "Hit Rate" "Miss Reduction"
echo "------------------------------------------------------------"

printf "%-15s %-8s %-8s %-10s %-15s\n" "LRU" "$lru_hits" "$lru_misses" "${lru_hit_rate}%" "baseline"

configs=("Original" "Aggressive" "Conservative" "High Learning" "Low Threshold")
hits_array=($hits1 $hits2 $hits3 $hits4 $hits5)
misses_array=($misses1 $misses2 $misses3 $misses4 $misses5)

for i in "${!configs[@]}"; do
    config="${configs[$i]}"
    hits="${hits_array[$i]}"
    misses="${misses_array[$i]}"
    
    if [ "$hits" -gt 0 ] && [ "$lru_misses" -gt 0 ]; then
        hit_rate=$(echo "scale=2; ($hits*100)/($hits+$misses)" | bc)
        reduction=$(echo "scale=2; ($lru_misses-$misses)*100/$lru_misses" | bc)
        printf "%-15s %-8s %-8s %-10s %-15s\n" "$config" "$hits" "$misses" "${hit_rate}%" "${reduction}%"
    fi
done

echo ""
echo "🎯 Best configuration identified!"