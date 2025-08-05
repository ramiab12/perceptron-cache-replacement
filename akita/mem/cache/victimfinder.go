package cache

// A VictimFinder decides with block should be evicted
type VictimFinder interface {
	FindVictim(set *Set) *Block
	FindVictimWithContext(set *Set, context *VictimContext) *Block
}

// LRUVictimFinder evicts the least recently used block to evict
type LRUVictimFinder struct {
}

// NewLRUVictimFinder returns a newly constructed lru evictor
func NewLRUVictimFinder() *LRUVictimFinder {
	e := new(LRUVictimFinder)
	return e
}

// FindVictim returns the least recently used block in a set
func (e *LRUVictimFinder) FindVictim(set *Set) *Block {
	// First try evicting an empty block
	for _, block := range set.Blocks {
		if !block.IsValid && !block.IsLocked {
			return block
		}
	}

	// Use PseudoLRU: efficient bit-based LRU approximation
	numWays := len(set.Blocks)
	victimWay := getPseudoLRUVictim(set, numWays)

	// Return the victim block if it's not locked
	if victimWay < numWays && !set.Blocks[victimWay].IsLocked {
		return set.Blocks[victimWay]
	}

	// Final fallback
	if len(set.Blocks) > 0 {
		return set.Blocks[0]
	}
	return nil
}

// FindVictimWithContext implements the VictimFinder interface
// Falls back to regular PseudoLRU behavior for compatibility
func (e *LRUVictimFinder) FindVictimWithContext(set *Set, context *VictimContext) *Block {
	return e.FindVictim(set)
}

// getPseudoLRUVictim returns the way ID of the PseudoLRU victim (shared implementation)
func getPseudoLRUVictim(set *Set, numWays int) int {
	switch numWays {
	case 2:
		if (set.PseudoLRUBits & 1) == 0 {
			return 0
		}
		return 1
	case 4:
		if (set.PseudoLRUBits & 1) == 0 {
			if (set.PseudoLRUBits & (1 << 1)) == 0 {
				return 0
			}
			return 1
		} else {
			if (set.PseudoLRUBits & (1 << 2)) == 0 {
				return 2
			}
			return 3
		}
	case 8:
		return getPseudoLRUVictim8Way(set)
	default:
		return int(set.PseudoLRUBits % uint64(numWays))
	}
}

// getPseudoLRUVictim8Way returns victim way for 8-way associative cache (shared implementation)
func getPseudoLRUVictim8Way(set *Set) int {
	bits := set.PseudoLRUBits

	if (bits & 1) == 0 {
		if (bits & (1 << 1)) == 0 {
			if (bits & (1 << 3)) == 0 {
				return 0
			}
			return 1
		} else {
			if (bits & (1 << 4)) == 0 {
				return 2
			}
			return 3
		}
	} else {
		if (bits & (1 << 2)) == 0 {
			if (bits & (1 << 5)) == 0 {
				return 4
			}
			return 5
		} else {
			if (bits & (1 << 6)) == 0 {
				return 6
			}
			return 7
		}
	}
}
