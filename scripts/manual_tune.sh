#!/bin/bash

# Manual parameter tuning - test specific configurations
set -e

echo "🎯 Manual Perceptron Parameter Tuning"
echo "====================================="

cd "$(dirname "$0")/.."

# Test function
test_config() {
    local threshold=$1
    local theta=$2
    local lr=$3
    local label=$4
    
    echo ""
    echo "🧪 Testing $label (τ=$threshold, θ=$theta, lr=$lr)..."
    
    # Update parameters in the code
    sed -i "s/return NewPerceptronVictimFinderWithParams([0-9]*, [0-9]*, [0-9]*)/return NewPerceptronVictimFinderWithParams($threshold, $theta, $lr)/" \
        akita/mem/cache/perceptron_victimfinder.go
    
    # Build and test
    cd mgpusim/amd/samples/spmv
    go build -o spmv_tune 2>/dev/null
    rm -f akita_sim*.sqlite3
    
    echo "  Running simulation..."
    timeout 180s ./spmv_tune -dim 1024 -sparsity 0.01 -timing -report-cache-hit-rate >/dev/null 2>&1 || true
    
    # Get results
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
            echo "  ✅ Results: Hits=$hits, Misses=$misses, Hit Rate=${hit_rate}%"
            echo "$hits $misses $hit_rate"
        else
            echo "  ❌ No valid results"
            echo "0 0 0"
        fi
        rm -f akita_sim*.sqlite3
    else
        echo "  ❌ No database file generated"
        echo "0 0 0"
    fi
    
    cd ../../..
}

# Get LRU baseline first
echo "📊 Getting LRU Baseline..."
sed -i 's/WithPerceptronVictimFinder()/\/\/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go

cd mgpusim/amd/samples/spmv
go build -o spmv_lru 2>/dev/null
rm -f akita_sim*.sqlite3
echo "  Running LRU simulation..."
timeout 180s ./spmv_lru -dim 1024 -sparsity 0.01 -timing -report-cache-hit-rate >/dev/null 2>&1 || true

lru_result="0 0 0"
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
        echo "  📊 LRU: Hits=$lru_hits, Misses=$lru_misses, Hit Rate=${lru_hit_rate}%"
        lru_result="$lru_hits $lru_misses $lru_hit_rate"
    fi
    rm -f akita_sim*.sqlite3
fi

# Re-enable perceptron
sed -i 's/\/\/WithPerceptronVictimFinder()/WithPerceptronVictimFinder()/' \
    mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go
cd ../../..

# Test different configurations
echo ""
echo "🔍 Testing Perceptron Configurations..."

# Store results
declare -A configs
declare -A results

configs["original"]="3 68 1"
configs["aggressive"]="1 32 2"
configs["conservative"]="5 96 1" 
configs["balanced"]="2 48 1"
configs["high_learn"]="3 68 3"

for name in "${!configs[@]}"; do
    read -r threshold theta lr <<< "${configs[$name]}"
    result=$(test_config "$threshold" "$theta" "$lr" "$name")
    results["$name"]=$(echo "$result" | tail -1)
done

# Display results
echo ""
echo "📈 Parameter Tuning Results"
echo "=========================="
printf "%-12s %-8s %-8s %-10s %-15s\n" "Config" "Hits" "Misses" "Hit Rate" "Miss Reduction"
echo "-----------------------------------------------------------"

read -r lru_h lru_m lru_hr <<< "$lru_result"
printf "%-12s %-8s %-8s %-10s %-15s\n" "LRU" "$lru_h" "$lru_m" "${lru_hr}%" "baseline"

for name in "${!results[@]}"; do
    read -r hits misses hit_rate <<< "${results[$name]}"
    if [ "$hits" -gt 0 ] && [ "$lru_m" -gt 0 ]; then
        reduction=$(echo "scale=2; ($lru_m-$misses)*100/$lru_m" | bc)
        printf "%-12s %-8s %-8s %-10s %-15s\n" "$name" "$hits" "$misses" "${hit_rate}%" "${reduction}%"
    fi
done | sort -k5 -nr

echo ""
echo "🎯 Best configuration identified! Use it for comprehensive testing."