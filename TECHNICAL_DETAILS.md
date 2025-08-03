# Technical Implementation Details

## 🔧 Detailed Implementation Breakdown

### Core Algorithm Implementation

#### Perceptron Prediction Logic
```go
// Core prediction algorithm from MICRO 2016
func (p *PerceptronVictimFinder) FindVictimWithContext(set *Set, context *VictimContext) *Block {
    // Step 1: Extract 6 features from address (PC proxy)
    features := p.extractFeatures(context)
    
    // Step 2: Calculate weighted sum from all feature tables
    sum := int32(0)
    for i := 0; i < 6; i++ {
        tableIndex := p.getTableIndex(features[i], context.Address)
        sum += p.featureTables[i][tableIndex]
    }
    
    // Step 3: Make prediction based on threshold
    predictNoReuse := sum >= p.threshold  // τ = 3
    
    // Step 4: Select victim based on prediction
    return p.selectVictim(set, predictNoReuse)
}
```

#### Feature Extraction Strategy
Our address-as-PC-proxy approach maps memory address bits to simulate PC-based features:

```go
func (p *PerceptronVictimFinder) extractFeatures(context *VictimContext) [6]uint32 {
    addr := context.Address
    
    // Mimic MICRO 2016 PC-based features using address bits
    return [6]uint32{
        uint32((addr >> 6) & 0x3F),   // Simulates PC >> 2
        uint32((addr >> 7) & 0x3F),   // Simulates PC >> 1  
        uint32((addr >> 8) & 0x3F),   // Simulates PC >> 2
        uint32((addr >> 9) & 0x3F),   // Simulates PC >> 3
        uint32((addr >> 12) & 0x3F),  // Tag bits
        uint32((addr >> 15) & 0x3F),  // Page bits
    }
}
```

**Rationale**: Memory access patterns in GPU kernels often correlate with instruction patterns, making address bits a reasonable proxy for PC information.

#### Hashing and Indexing
Following MICRO 2016 exactly:

```go
func (p *PerceptronVictimFinder) getTableIndex(feature uint32, addr uint64) uint32 {
    // 1. Hash feature to 8 bits (reduces aliasing)
    hashedFeature := hash32(uint64(feature)) & 0xFF
    
    // 2. XOR with address bits (adds context)
    addrBits := uint32(addr & 0xFF)
    
    // 3. Final index into 256-entry table
    return (hashedFeature ^ addrBits) % 256
}

// FNV-1a hash implementation
func hash32(value uint64) uint32 {
    hash := uint32(0x811c9dc5) // FNV-1a prime
    for i := 0; i < 8; i++ {
        hash ^= uint32(value & 0xFF)
        hash *= 0x01000193 // FNV-1a multiplier
        value >>= 8
    }
    return hash & 0xFF
}
```

### Training Algorithm

#### Online Learning Implementation
```go
func (p *PerceptronVictimFinder) train(features [6]uint32, addr uint64, predicted bool, actual bool) {
    sum := p.calculatePredictionSum(features, addr)
    
    // Train if: prediction wrong OR confidence low (|sum| < θ)
    if predicted != actual || abs(sum) < p.theta {
        for i := 0; i < 6; i++ {
            tableIndex := p.getTableIndex(features[i], addr)
            
            if actual {
                // Block was reused → decrease "no reuse" prediction
                p.featureTables[i][tableIndex] = max(-32, 
                    p.featureTables[i][tableIndex] - p.learningRate)
            } else {
                // Block not reused → increase "no reuse" prediction
                p.featureTables[i][tableIndex] = min(31, 
                    p.featureTables[i][tableIndex] + p.learningRate)
            }
        }
    }
    
    // Update accuracy statistics
    if predicted == actual {
        p.correctPredictions++
    }
    p.totalPredictions++
}
```

### Integration Architecture

#### Cache Pipeline Integration
The perceptron integrates at the cache directory stage where victim selection occurs:

```
Memory Request → Top Parser → Directory Stage → Bank Stage → Response
                                    ↓
                            Victim Selection
                                    ↓
                        PerceptronVictimFinder.FindVictimWithContext()
                                    ↓
                            Feature Extraction
                                    ↓
                            Prediction & Selection
```

#### Context Flow
```go
// In directorystage.go
func (ds *directoryStage) handleReadMiss(trans *transaction) bool {
    // Create context with all available information
    context := &cache.VictimContext{
        Address:     trans.read.Address,
        PID:         trans.read.PID,
        AccessType:  "read",
        CacheLineID: cacheLineID,
    }
    
    // Use context-aware victim selection
    victim := ds.cache.directory.FindVictimWithContext(cacheLineID, context)
    
    // ... continue with eviction/fetch logic
}
```

### Performance Measurement Infrastructure

#### Cache Metrics Collection
We fixed a critical bug in MGPUSim's cache metrics collection:

```go
// BEFORE (buggy):
func (r *reporter) injectCacheHitRateTracer(s *simulation.Simulation) {
    if !*reportAll && !*cacheLatencyReportFlag {  // WRONG FLAG!
        return
    }
    // ...
}

// AFTER (fixed):
func (r *reporter) injectCacheHitRateTracer(s *simulation.Simulation) {
    if !*reportAll && !*cacheHitRateReportFlag {  // CORRECT FLAG!
        return
    }
    // ...
}
```

#### SQLite Data Extraction
```sql
-- Query to extract L2 cache hit/miss metrics
SELECT 
    COALESCE(SUM(CASE WHEN What IN ('read-hit','write-hit') THEN Value END), 0) as hits,
    COALESCE(SUM(CASE WHEN What IN ('read-miss','write-miss') THEN Value END), 0) as misses
FROM mgpusim_metrics 
WHERE Location LIKE '%L2Cache%';
```

#### Performance Calculation
```bash
# Calculate hit rates and miss reduction
hits_perc=3575  # From perceptron run
miss_perc=1514
hits_lru=3691   # From LRU run  
miss_lru=1507

# Hit rates
hr_perc=$(echo "scale=2; ($hits_perc*100)/($hits_perc+$miss_perc)" | bc)  # 70.26%
hr_lru=$(echo "scale=2; ($hits_lru*100)/($hits_lru+$miss_lru)" | bc)      # 71.01%

# Miss reduction  
miss_reduction=$(echo "scale=2; ($miss_lru-$miss_perc)*100/$miss_lru" | bc)  # -0.46%
```

### Build System Integration

#### Go Module Configuration
```go
// perceptron_research/go.mod
module perceptron_research

go 1.24

replace github.com/sarchlab/akita/v4 => ./akita

// mgpusim/go.mod  
module github.com/sarchlab/mgpusim/v4

require (
    github.com/sarchlab/akita/v4 v4.5.1
    // ... other dependencies
)

replace github.com/sarchlab/akita/v4 => ../akita
```

#### Builder Pattern Integration
```go
// In writeback/builder.go
type Builder struct {
    // ... existing fields
    usePerceptron bool  // NEW FIELD
}

func (b Builder) WithPerceptronVictimFinder() Builder {
    b.usePerceptron = true
    return b
}

func (b *Builder) configureCache(cacheModule *Comp) {
    var victimFinder cache.VictimFinder
    if b.usePerceptron {
        victimFinder = cache.NewPerceptronVictimFinder()
    } else {
        victimFinder = cache.NewLRUVictimFinder()
    }
    // ... rest of configuration
}
```

### Debugging and Diagnostics

#### Statistics Collection
```go
type PerceptronVictimFinder struct {
    // ... core fields
    totalPredictions   int64
    correctPredictions int64
}

func (p *PerceptronVictimFinder) GetAccuracy() float64 {
    if p.totalPredictions == 0 {
        return 0.0
    }
    return float64(p.correctPredictions) / float64(p.totalPredictions)
}

func (p *PerceptronVictimFinder) GetStats() (int64, int64, float64) {
    accuracy := p.GetAccuracy()
    return p.totalPredictions, p.correctPredictions, accuracy
}
```

#### Weight Distribution Analysis
```go
// Helper function to analyze weight distributions
func (p *PerceptronVictimFinder) AnalyzeWeights() map[string]interface{} {
    stats := make(map[string]interface{})
    
    for tableIdx := 0; tableIdx < 6; tableIdx++ {
        table := p.featureTables[tableIdx]
        
        var sum, min, max int32 = 0, 31, -32
        for _, weight := range table {
            sum += weight
            if weight < min { min = weight }
            if weight > max { max = weight }
        }
        
        stats[fmt.Sprintf("table_%d", tableIdx)] = map[string]interface{}{
            "avg": float64(sum) / 256.0,
            "min": min,
            "max": max,
        }
    }
    
    return stats
}
```

### Error Handling and Edge Cases

#### Division by Zero Protection
```bash
# In comprehensive_test.sh
if [ "$((h1 + m1))" -eq 0 ]; then
    hr1="0.00"
else
    hr1=$(echo "scale=2; ($h1*100)/($h1+$m1)" | bc)
fi

if [ "$m0" -eq 0 ]; then
    red="0.00"  
else
    red=$(echo "scale=2; ($m0-$m1)*100/$m0" | bc)
fi
```

#### Floating Point Conversion
```bash
# Convert SQLite floating point results to integers
h1=$(echo "${out_perc%%|*}" | cut -d. -f1)  # "3575.0" → "3575"
m1=$(echo "${out_perc##*|}" | cut -d. -f1)  # "1514.0" → "1514"
```

#### Weight Saturation
```go
func (p *PerceptronVictimFinder) train(...) {
    // ... training logic
    
    // Ensure weights stay within 6-bit signed range [-32, +31]
    if actual {
        p.featureTables[i][tableIndex] = max(-32, 
            p.featureTables[i][tableIndex] - p.learningRate)
    } else {
        p.featureTables[i][tableIndex] = min(31, 
            p.featureTables[i][tableIndex] + p.learningRate)
    }
}
```

### Compatibility and Backward Support

#### Interface Backward Compatibility
```go
// VictimFinder interface supports both old and new methods
type VictimFinder interface {
    FindVictim(set *Set) *Block                              // Original method
    FindVictimWithContext(set *Set, context *VictimContext) *Block  // New method
}

// LRUVictimFinder implements both for compatibility
func (e *LRUVictimFinder) FindVictimWithContext(set *Set, context *VictimContext) *Block {
    return e.FindVictim(set)  // Fallback to original implementation
}
```

#### Graceful Degradation
```go
// Directory falls back gracefully if perceptron isn't available
func (d *DirectoryImpl) FindVictimWithContext(addr uint64, context *VictimContext) *Block {
    set, _ := d.getSet(addr)
    
    // Try perceptron first
    if perceptronVF, ok := d.victimFinder.(*PerceptronVictimFinder); ok {
        return perceptronVF.FindVictimWithContext(set, context)
    }
    
    // Fallback to standard victim finder
    return d.victimFinder.FindVictim(set)
}
```

### Testing Framework Architecture

#### Test Isolation
```bash
# Each test cleans up SQLite files to avoid contamination
cleanup_sqlite() {
    local dir=$1
    cd "$dir"
    if ls akita_sim*.sqlite3 1> /dev/null 2>&1; then
        ls -t akita_sim*.sqlite3 | tail -n +2 | xargs -r rm -f
    fi
}
```

#### Parallel Test Execution
```bash
# Tests run both versions in sequence with proper cleanup
test_matrix_size() {
    local size=$1
    
    # Clean before test
    cleanup_sqlite "$perc_repo/amd/samples/spmv"
    cleanup_sqlite "$lru_repo/amd/samples/spmv"
    
    # Run perceptron version
    cd "$perc_repo/amd/samples/spmv"
    go build -o run_perc
    rm -f akita_sim*.sqlite3
    ./run_perc $flags 1>&2
    
    # Extract metrics immediately
    db_perc=$(ls -t akita_sim*.sqlite3 | head -1)
    # ... extract and process results
    
    # Run LRU version
    cd "$lru_repo/amd/samples/spmv"  
    go build -o run_lru
    rm -f akita_sim*.sqlite3
    ./run_lru $flags 1>&2
    
    # Extract and compare
    # ... comparison logic
}
```

This comprehensive technical documentation captures all the intricate details of our implementation, from the core algorithms to the testing infrastructure.