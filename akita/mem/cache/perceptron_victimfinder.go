package cache

import (
	"github.com/sarchlab/akita/v4/mem/vm"
)

// VictimContext contains context information for victim selection
type VictimContext struct {
	Address     uint64
	PID         vm.PID
	AccessType  string // "read" or "write"
	CacheLineID uint64
}

// CachedPrediction stores both prediction and sum to avoid duplicate calculations
type CachedPrediction struct {
	predictNoReuse bool
	sum            int32
}

// PerceptronVictimFinder implements perceptron-based cache replacement
// Based on MICRO 2016 paper "Perceptron Learning for Reuse Prediction"
// Uses address-as-PC-proxy since we don't have direct PC access in GPU
type PerceptronVictimFinder struct {
	// 32 weights as used in earlier successful implementation
	// Each weight is 6-bit signed (-32 to +31)
	weights [32]int32

	// Prediction threshold (τ from MICRO 2016)
	// If sum >= threshold, predict no reuse (evict block)
	threshold int32

	// Training threshold (θ from MICRO 2016)
	// Only update weights if |sum| < θ or prediction is wrong
	theta int32

	// Learning rate for weight updates
	learningRate int32

	// Cache to store predictions AND sums for training feedback
	// Maps address -> cached prediction with sum to avoid duplicate calculations
	predictionCache map[uint64]CachedPrediction

	// Statistics for monitoring
	totalPredictions   int64
	correctPredictions int64
}

// NewPerceptronVictimFinder creates a new perceptron victim finder with MICRO 2016 paper parameters
func NewPerceptronVictimFinder() *PerceptronVictimFinder {
	return NewPerceptronVictimFinderWithParams(0, 32, 1) // MICRO 2016 paper parameters: τ=0, θ=32, lr=1
}

// NewPerceptronVictimFinderWithParams creates a perceptron with custom parameters
func NewPerceptronVictimFinderWithParams(threshold, theta, learningRate int32) *PerceptronVictimFinder {
	p := &PerceptronVictimFinder{
		threshold:       threshold,
		theta:           theta,
		learningRate:    learningRate,
		predictionCache: make(map[uint64]CachedPrediction),
	}

	// Initialize 32 weights to 0 (matching earlier successful implementation)
	for i := 0; i < 32; i++ {
		p.weights[i] = 0
	}

	// Removed logging for performance

	return p
}

// FindVictim implements the VictimFinder interface
// Uses direct block traversal (no LRU maintenance)
func (p *PerceptronVictimFinder) FindVictim(set *Set) *Block {
	// Direct block traversal when no context is provided
	for _, block := range set.Blocks {
		if !block.IsValid && !block.IsLocked {
			return block
		}
	}

	for _, block := range set.Blocks {
		if !block.IsLocked {
			return block
		}
	}

	if len(set.Blocks) > 0 {
		return set.Blocks[0]
	}
	return nil
}

// FindVictimWithContext implements perceptron-based victim selection
func (p *PerceptronVictimFinder) FindVictimWithContext(set *Set, context *VictimContext) *Block {
	// Calculate prediction sum using direct PC and tag bits (like earlier implementation)
	sum := p.calculatePredictionSum(context.Address)

	// Make prediction: if sum >= threshold, predict no reuse (evict block)
	// if sum < threshold, predict reuse (keep block)
	predictNoReuse := sum >= p.threshold

	// Store BOTH prediction and sum for training feedback (avoids duplicate calculation)
	p.predictionCache[context.Address] = CachedPrediction{
		predictNoReuse: predictNoReuse,
		sum:            sum,
	}

	// Removed all debug logging for performance

	// Find best victim based on prediction and confidence (HYBRID APPROACH)
	victim := p.selectVictim(set, predictNoReuse, sum)

	// Update statistics
	p.totalPredictions++

	return victim
}

// ExtractFeatures extracts 6 features using address-as-PC-proxy (public method)
// Based on MICRO 2016 paper Section IV-F, adapted for GPU context
func (p *PerceptronVictimFinder) ExtractFeatures(context *VictimContext) [6]uint32 {
	return p.extractFeatures(context)
}

// extractFeatures extracts 6 features using address-as-PC-proxy (internal method)
// Based on MICRO 2016 paper Section IV-F, adapted for GPU context
func (p *PerceptronVictimFinder) extractFeatures(context *VictimContext) [6]uint32 {
	features := [6]uint32{}
	addr := context.Address

	// Feature 1: Address bits 6-11 (PC proxy shifted by 2)
	features[0] = uint32((addr >> 6) & 0x3F)

	// Feature 2: Address bits 7-12 (PC proxy shifted by 1)
	features[1] = uint32((addr >> 7) & 0x3F)

	// Feature 3: Address bits 8-13 (PC proxy shifted by 2)
	features[2] = uint32((addr >> 8) & 0x3F)

	// Feature 4: Address bits 9-14 (PC proxy shifted by 3)
	features[3] = uint32((addr >> 9) & 0x3F)

	// Feature 5: Tag bits (address bits 12-17)
	features[4] = uint32((addr >> 12) & 0x3F)

	// Feature 6: Page bits (address bits 15-20)
	features[5] = uint32((addr >> 15) & 0x3F)

	return features
}

// calculatePredictionSum calculates the sum using direct PC and tag bits (like earlier implementation)
func (p *PerceptronVictimFinder) calculatePredictionSum(addr uint64) int32 {
	sum := int32(0)

	// Use direct PC bits (16 bits from address)
	for i := 0; i < 16; i++ {
		if (addr>>uint(i))&1 == 1 {
			sum += p.weights[i]
		}
	}

	// Use tag bits (16 bits from higher address bits)
	for i := 0; i < 16; i++ {
		if (addr>>uint(i+16))&1 == 1 {
			sum += p.weights[i+16]
		}
	}

	return sum
}

// getTableIndex computes table index using hashing + XOR as per MICRO 2016
func (p *PerceptronVictimFinder) getTableIndex(feature uint32, addr uint64) uint32 {
	// Hash the feature to 8 bits (as per paper)
	hashedFeature := hash32(uint64(feature)) & 0xFF

	// XOR with lower 8 bits of address (instead of PC)
	addrBits := uint32(addr & 0xFF)

	return (hashedFeature ^ addrBits) % 256
}

// selectVictim selects the best victim using HYBRID approach from MICRO 2016 paper
func (p *PerceptronVictimFinder) selectVictim(set *Set, predictNoReuse bool, predictionSum int32) *Block {
	// MICRO 2016 HYBRID APPROACH: Use perceptron when confident, LRU baseline when not

	// First pass: Always prefer invalid blocks (regardless of prediction)
	for _, block := range set.Blocks {
		if !block.IsValid && !block.IsLocked {
			return block
		}
	}

	// Check prediction confidence using theta threshold (like MICRO 2016 paper)
	isConfident := abs(predictionSum) >= p.theta

	if isConfident {
		// HIGH CONFIDENCE: Use perceptron prediction
		if predictNoReuse {
			// Perceptron says "no reuse" - find any unlocked block to evict
			for _, block := range set.Blocks {
				if !block.IsLocked {
					return block
				}
			}
		} else {
			// Perceptron says "reuse likely" - use PseudoLRU baseline to preserve locality
			return p.findPseudoLRUVictim(set)
		}
	} else {
		// LOW CONFIDENCE: Fall back to PseudoLRU baseline (like MICRO 2016 paper)
		return p.findPseudoLRUVictim(set)
	}

	// Final fallback
	if len(set.Blocks) > 0 {
		return set.Blocks[0]
	}
	return nil
}

// findPseudoLRUVictim implements PseudoLRU victim selection (MICRO 2016 paper baseline)
func (p *PerceptronVictimFinder) findPseudoLRUVictim(set *Set) *Block {
	numWays := len(set.Blocks)
	victimWay := p.getPseudoLRUVictim(set, numWays)

	// Return the victim block if it's not locked
	if victimWay < numWays && !set.Blocks[victimWay].IsLocked {
		return set.Blocks[victimWay]
	}

	// Fallback: return first unlocked block
	for _, block := range set.Blocks {
		if !block.IsLocked {
			return block
		}
	}

	return nil
}

// getPseudoLRUVictim returns the way ID of the PseudoLRU victim
func (p *PerceptronVictimFinder) getPseudoLRUVictim(set *Set, numWays int) int {
	switch numWays {
	case 2:
		// 2-way: bit 0 indicates which way to replace
		if (set.PseudoLRUBits & 1) == 0 {
			return 0
		}
		return 1
	case 4:
		// 4-way: follow the tree bits to find victim
		//     bit0
		//    /    \
		//  bit1   bit2
		//  / \    / \
		// W0 W1  W2 W3
		if (set.PseudoLRUBits & 1) == 0 {
			// Left subtree
			if (set.PseudoLRUBits & (1 << 1)) == 0 {
				return 0
			}
			return 1
		} else {
			// Right subtree
			if (set.PseudoLRUBits & (1 << 2)) == 0 {
				return 2
			}
			return 3
		}
	case 8:
		// 8-way: follow the 7-bit tree
		return p.getPseudoLRUVictim8Way(set)
	default:
		// Fallback: round-robin
		return int(set.PseudoLRUBits % uint64(numWays))
	}
}

// getPseudoLRUVictim8Way returns victim way for 8-way associative cache
func (p *PerceptronVictimFinder) getPseudoLRUVictim8Way(set *Set) int {
	bits := set.PseudoLRUBits

	if (bits & 1) == 0 {
		// Left subtree (ways 0-3)
		if (bits & (1 << 1)) == 0 {
			// Left-left subtree (ways 0-1)
			if (bits & (1 << 3)) == 0 {
				return 0
			}
			return 1
		} else {
			// Left-right subtree (ways 2-3)
			if (bits & (1 << 4)) == 0 {
				return 2
			}
			return 3
		}
	} else {
		// Right subtree (ways 4-7)
		if (bits & (1 << 2)) == 0 {
			// Right-left subtree (ways 4-5)
			if (bits & (1 << 5)) == 0 {
				return 4
			}
			return 5
		} else {
			// Right-right subtree (ways 6-7)
			if (bits & (1 << 6)) == 0 {
				return 6
			}
			return 7
		}
	}
}

// Training methods

// TrainOnHit trains the predictor when a block is hit (reused)
func (p *PerceptronVictimFinder) TrainOnHit(addr uint64) {
	// Get the actual prediction AND sum we made for this address
	cached, exists := p.predictionCache[addr]
	if !exists {
		// If no prediction cached, skip training (shouldn't happen in normal flow)
		return
	}

	// Removed training logging for performance

	// Train with cached prediction and sum vs actual outcome (OPTIMIZED - no duplicate calculation)
	p.trainWithSum(addr, cached.predictNoReuse, cached.sum, true) // actual = true (reused)

	// Clean up prediction cache to prevent memory leak
	delete(p.predictionCache, addr)
}

// TrainOnEviction trains the predictor when a block is evicted (not reused)
func (p *PerceptronVictimFinder) TrainOnEviction(addr uint64) {
	// Get the actual prediction AND sum we made for this address
	cached, exists := p.predictionCache[addr]
	if !exists {
		// If no prediction cached, skip training (shouldn't happen in normal flow)
		return
	}

	// Removed eviction training logging for performance

	// Train with cached prediction and sum vs actual outcome (OPTIMIZED - no duplicate calculation)
	p.trainWithSum(addr, cached.predictNoReuse, cached.sum, false) // actual = false (not reused)

	// Clean up prediction cache to prevent memory leak
	delete(p.predictionCache, addr)
}

// trainWithSum implements the perceptron learning algorithm using cached sum (OPTIMIZED)
func (p *PerceptronVictimFinder) trainWithSum(addr uint64, predictedNoReuse bool, sum int32, actualReuse bool) {
	// Use the cached sum instead of recalculating (PERFORMANCE OPTIMIZATION)

	// Convert to consistent semantics: actualNoReuse = !actualReuse
	actualNoReuse := !actualReuse

	// Update weights if prediction was wrong or confidence is low
	if predictedNoReuse != actualNoReuse || abs(sum) < p.theta {
		// Update weights based on PC bits (16 bits from address)
		for i := 0; i < 16; i++ {
			if (addr>>uint(i))&1 == 1 {
				if actualReuse {
					// Block was reused - decrement weight (make it less likely to predict no reuse)
					p.weights[i] = max(-32, p.weights[i]-p.learningRate)
				} else {
					// Block was not reused - increment weight (make it more likely to predict no reuse)
					p.weights[i] = min(31, p.weights[i]+p.learningRate)
				}
			}
		}

		// Update weights based on tag bits (16 bits from higher address bits)
		for i := 0; i < 16; i++ {
			if (addr>>uint(i+16))&1 == 1 {
				if actualReuse {
					// Block was reused - decrement weight
					p.weights[i+16] = max(-32, p.weights[i+16]-p.learningRate)
				} else {
					// Block was not reused - increment weight
					p.weights[i+16] = min(31, p.weights[i+16]+p.learningRate)
				}
			}
		}
	}

	// Update accuracy statistics
	if predictedNoReuse == actualNoReuse {
		p.correctPredictions++
	}
}

// Access method for direct training on cache hits (like earlier implementation)
func (p *PerceptronVictimFinder) Access(addr uint64) {
	// Direct training on hit - this is a reuse, so train with actualReuse=true
	cached, exists := p.predictionCache[addr]
	if exists {
		p.trainWithSum(addr, cached.predictNoReuse, cached.sum, true) // Block was accessed, so it was reused (OPTIMIZED)
		delete(p.predictionCache, addr)
	}
}

// train implements the perceptron learning algorithm (fallback method for compatibility)
func (p *PerceptronVictimFinder) train(addr uint64, predictedNoReuse bool, actualReuse bool) {
	// Calculate current prediction confidence (this is the old non-optimized version)
	sum := p.calculatePredictionSum(addr)
	// Delegate to optimized version
	p.trainWithSum(addr, predictedNoReuse, sum, actualReuse)
}

// Utility functions

// hash32 implements a simple hash function for 8-bit hashes (as per MICRO 2016)
func hash32(value uint64) uint32 {
	hash := uint32(0x811c9dc5) // FNV-1a prime
	for i := 0; i < 8; i++ {
		hash ^= uint32(value & 0xFF)
		hash *= 0x01000193 // FNV-1a multiplier
		value >>= 8
	}
	return hash & 0xFF // Return 8-bit hash as per paper
}

// abs returns absolute value of int32
func abs(x int32) int32 {
	if x < 0 {
		return -x
	}
	return x
}

// max returns maximum of two int32 values
func max(a, b int32) int32 {
	if a > b {
		return a
	}
	return b
}

// min returns minimum of two int32 values
func min(a, b int32) int32 {
	if a < b {
		return a
	}
	return b
}

// GetAccuracy returns the prediction accuracy
func (p *PerceptronVictimFinder) GetAccuracy() float64 {
	if p.totalPredictions == 0 {
		return 0.0
	}
	return float64(p.correctPredictions) / float64(p.totalPredictions)
}

// GetStats returns prediction statistics
func (p *PerceptronVictimFinder) GetStats() (int64, int64, float64) {
	accuracy := p.GetAccuracy()
	return p.totalPredictions, p.correctPredictions, accuracy
}
