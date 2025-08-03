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
	for _, block := range set.LRUQueue {
		if !block.IsValid && !block.IsLocked {
			return block
		}
	}

	for _, block := range set.LRUQueue {
		if !block.IsLocked {
			return block
		}
	}

	return set.LRUQueue[0]
}

// FindVictimWithContext implements the VictimFinder interface
// Falls back to regular LRU behavior for compatibility
func (e *LRUVictimFinder) FindVictimWithContext(set *Set, context *VictimContext) *Block {
	return e.FindVictim(set)
}
