#!/bin/bash

# Parameter tuning script for perceptron-based cache replacement
# Tests different parameter combinations to find optimal miss reduction

set -e

echo "🔧 Perceptron Parameter Tuning for Optimal Miss Reduction"
echo "========================================================"
echo ""

# Test configuration
MATRIX_SIZE=2048
SPARSITY=0.01
TEST_FLAGS="-dim $MATRIX_SIZE -sparsity $SPARSITY -timing -report-cache-hit-rate"
RESULTS_DIR="../results/parameter_tuning"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create results directory
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/tuning_results_${TIMESTAMP}.txt"

echo "📊 Test Configuration:"
echo "- Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "- Sparsity: ${SPARSITY}"
echo "- Results file: ${RESULTS_FILE}"
echo ""

# Change to perceptron_research directory
cd "$(dirname "$0")/.."

# Parameter ranges to test
THRESHOLDS=(1 2 3 5 7 10)
THETAS=(32 48 68 96 128)
LEARNING_RATES=(1 2 3)

# Function to test a parameter combination
test_parameters() {
    local threshold=$1
    local theta=$2
    local learning_rate=$3
    
    echo "🧪 Testing: τ=$threshold, θ=$theta, lr=$learning_rate"
    
    # Modify perceptron parameters
    sed -i "s/return NewPerceptronVictimFinderWithParams([0-9]*, [0-9]*, [0-9]*)/return NewPerceptronVictimFinderWithParams($threshold, $theta, $learning_rate)/" \
        akita/mem/cache/perceptron_victimfinder.go
    
    # Build and run test
    cd mgpusim/amd/samples/spmv
    go build -o spmv_tune 2>/dev/null
    rm -f akita_sim*.sqlite3
    
    # Run test and capture metrics
    timeout 180s ./spmv_tune $TEST_FLAGS >/dev/null 2>&1 || true
    
    # Extract metrics if SQLite file exists
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
            echo "  - Hits: $hits, Misses: $misses, Hit Rate: ${hit_rate}%"
            
            # Log results
            echo "τ=$threshold θ=$theta lr=$learning_rate hits=$hits misses=$misses hit_rate=${hit_rate}%" >> "$RESULTS_FILE"
        else
            echo "  - No valid metrics"
            echo "τ=$threshold θ=$theta lr=$learning_rate hits=0 misses=0 hit_rate=0%" >> "$RESULTS_FILE"
        fi
        
        rm -f akita_sim*.sqlite3
    else
        echo "  - Test failed"
        echo "τ=$threshold θ=$theta lr=$learning_rate hits=0 misses=0 hit_rate=0%" >> "$RESULTS_FILE"
    fi
    
    cd ../../..
}

# Function to get LRU baseline
get_lru_baseline() {
    echo "📊 Getting LRU baseline..."
    
    # Temporarily disable perceptron
    sed -i 's/WithPerceptronVictimFinder()/\/\/WithPerceptronVictimFinder()/' \
        mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go
    
    cd mgpusim/amd/samples/spmv
    go build -o spmv_lru 2>/dev/null
    rm -f akita_sim*.sqlite3
    
    timeout 180s ./spmv_lru $TEST_FLAGS >/dev/null 2>&1 || true
    
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
            echo "  - LRU: Hits: $lru_hits, Misses: $lru_misses, Hit Rate: ${lru_hit_rate}%"
            echo "LRU_BASELINE hits=$lru_hits misses=$lru_misses hit_rate=${lru_hit_rate}%" >> "$RESULTS_FILE"
        fi
        
        rm -f akita_sim*.sqlite3
    fi
    
    # Re-enable perceptron
    sed -i 's/\/\/WithPerceptronVictimFinder()/WithPerceptronVictimFinder()/' \
        mgpusim/amd/samples/runner/timingconfig/r9nano/builder.go
    
    cd ../../..
}

# Initialize results file
{
    echo "Perceptron Parameter Tuning Results"
    echo "=================================="
    echo "Test started: $(date)"
    echo "Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
    echo "Sparsity: ${SPARSITY}"
    echo ""
} > "$RESULTS_FILE"

# Get LRU baseline
get_lru_baseline

echo ""
echo "🔍 Testing parameter combinations..."

# Test promising combinations first (based on literature)
PROMISING_COMBINATIONS=(
    "1 32 1"   # Lower threshold, lower theta
    "2 48 1"   # Moderate threshold, moderate theta  
    "3 68 1"   # Original MICRO 2016
    "5 96 2"   # Higher threshold, higher theta, higher learning
    "7 128 2"  # Even higher values
    "1 68 2"   # Low threshold, original theta, higher learning
    "2 32 2"   # Low threshold and theta, higher learning
)

echo "Testing ${#PROMISING_COMBINATIONS[@]} promising combinations..."

for combo in "${PROMISING_COMBINATIONS[@]}"; do
    read -r threshold theta learning_rate <<< "$combo"
    test_parameters "$threshold" "$theta" "$learning_rate"
done

echo ""
echo "✅ Parameter tuning completed!"
echo ""

# Analyze results
echo "📈 Analysis:"
echo "==========="

# Find best miss reduction
if [ -f "$RESULTS_FILE" ]; then
    echo "Results saved to: $RESULTS_FILE"
    echo ""
    
    # Extract LRU baseline
    lru_line=$(grep "LRU_BASELINE" "$RESULTS_FILE" || echo "")
    if [ -n "$lru_line" ]; then
        lru_misses=$(echo "$lru_line" | grep -o "misses=[0-9]*" | cut -d= -f2)
        echo "LRU Baseline Misses: $lru_misses"
        echo ""
        
        echo "Top 3 configurations by miss reduction:"
        grep -v "LRU_BASELINE" "$RESULTS_FILE" | grep -v "hits=0" | while read -r line; do
            if [[ $line =~ τ=([0-9]+).*misses=([0-9]+) ]]; then
                perc_misses="${BASH_REMATCH[2]}"
                if [ "$lru_misses" -gt 0 ] && [ "$perc_misses" -gt 0 ]; then
                    reduction=$(echo "scale=2; ($lru_misses-$perc_misses)*100/$lru_misses" | bc)
                    echo "$line miss_reduction=${reduction}%"
                fi
            fi
        done | sort -k4 -nr | head -3
    fi
fi

echo ""
echo "🎯 Next: Use the best parameters for comprehensive comparison!"