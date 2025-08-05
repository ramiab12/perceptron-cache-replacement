package cache

import (
	"github.com/sarchlab/akita/v4/mem/mem"
	"github.com/sarchlab/akita/v4/mem/vm"
)

// A Block of a cache is the information that is associated with a cache line
type Block struct {
	PID          vm.PID
	Tag          uint64
	WayID        int
	SetID        int
	CacheAddress uint64
	IsValid      bool
	IsDirty      bool
	ReadCount    int
	IsLocked     bool
	DirtyMask    []bool
	// PseudoLRU doesn't need per-block tracking - uses set-level bit tree
}

// A Set is a list of blocks where a certain piece memory can be stored at
type Set struct {
	Blocks []*Block
	// PseudoLRU: binary tree of bits for efficient LRU approximation (MICRO 2016 paper approach)
	PseudoLRUBits uint64 // Bit vector for PseudoLRU tree (supports up to 64-way associativity)
}

// A Directory stores the information about what is stored in the cache.
type Directory interface {
	Lookup(pid vm.PID, address uint64) *Block
	FindVictim(address uint64) *Block
	FindVictimWithContext(address uint64, context *VictimContext) *Block
	Visit(block *Block)
	TotalSize() uint64
	WayAssociativity() int
	GetSets() []Set
	GetVictimFinder() VictimFinder
	Reset()
}

// A DirectoryImpl is the default implementation of a Directory
//
// The directory can translate from the request address (can be either virtual
// address or physical address) to the cache based address.
type DirectoryImpl struct {
	NumSets       int
	NumWays       int
	BlockSize     int
	AddrConverter mem.AddressConverter

	Sets []Set

	victimFinder VictimFinder
}

// NewDirectory returns a new directory object
func NewDirectory(
	set, way, blockSize int,
	victimFinder VictimFinder,
) *DirectoryImpl {
	d := new(DirectoryImpl)
	d.victimFinder = victimFinder
	d.Sets = make([]Set, set)

	d.NumSets = set
	d.NumWays = way
	d.BlockSize = blockSize

	d.Reset()

	return d
}

// TotalSize returns the maximum number of bytes can be stored in the cache
func (d *DirectoryImpl) TotalSize() uint64 {
	return uint64(d.NumSets) * uint64(d.NumWays) * uint64(d.BlockSize)
}

// Get the set that a certain address should store at
func (d *DirectoryImpl) getSet(reqAddr uint64) (set *Set, setID int) {
	if d.AddrConverter != nil {
		reqAddr = d.AddrConverter.ConvertExternalToInternal(reqAddr)
	}

	setID = int(reqAddr / uint64(d.BlockSize) % uint64(d.NumSets))
	set = &d.Sets[setID]

	return
}

// Lookup finds the block that reqAddr. If the reqAddr is valid
// in the cache, return the block information. Otherwise, return nil
func (d *DirectoryImpl) Lookup(PID vm.PID, reqAddr uint64) *Block {
	set, _ := d.getSet(reqAddr)
	for _, block := range set.Blocks {
		if block.IsValid && block.Tag == reqAddr && block.PID == PID {
			return block
		}
	}

	return nil
}

// FindVictim returns a block that can be used to stored data at address addr.
//
// If it is valid, the cache controller need to decide what to do to evict the
// the data in the block
func (d *DirectoryImpl) FindVictim(addr uint64) *Block {
	set, _ := d.getSet(addr)
	block := d.victimFinder.FindVictim(set)

	return block
}

// FindVictimWithContext returns a block that can be used to stored data at address addr.
// Uses context information for perceptron-based victim selection.
func (d *DirectoryImpl) FindVictimWithContext(addr uint64, context *VictimContext) *Block {
	set, _ := d.getSet(addr)

	// Try perceptron victim finder first
	if perceptronVF, ok := d.victimFinder.(*PerceptronVictimFinder); ok {
		return perceptronVF.FindVictimWithContext(set, context)
	}

	// Fallback to regular FindVictim
	return d.victimFinder.FindVictim(set)
}

// Visit updates PseudoLRU bits (MICRO 2016 paper approach - very efficient)
func (d *DirectoryImpl) Visit(block *Block) {
	// PseudoLRU: Update binary tree bits to mark this way as recently used
	set := &d.Sets[block.SetID]
	d.updatePseudoLRU(set, block.WayID)
}

// updatePseudoLRU updates the PseudoLRU tree bits for a given way
func (d *DirectoryImpl) updatePseudoLRU(set *Set, wayID int) {
	numWays := len(set.Blocks)

	// For common associativities, use optimized bit patterns
	switch numWays {
	case 2:
		// 2-way: 1 bit (bit 0)
		// Way 0 accessed -> set bit 0 to 1, Way 1 accessed -> set bit 0 to 0
		if wayID == 0 {
			set.PseudoLRUBits |= 1 // Set bit 0
		} else {
			set.PseudoLRUBits &= ^uint64(1) // Clear bit 0
		}
	case 4:
		// 4-way: 3 bits (tree structure)
		//     bit0
		//    /    \
		//  bit1   bit2
		//  / \    / \
		// W0 W1  W2 W3
		if wayID < 2 {
			set.PseudoLRUBits &= ^uint64(1) // Clear bit 0 (left subtree)
			if wayID == 0 {
				set.PseudoLRUBits |= (1 << 1) // Set bit 1
			} else {
				set.PseudoLRUBits &= ^uint64(1 << 1) // Clear bit 1
			}
		} else {
			set.PseudoLRUBits |= 1 // Set bit 0 (right subtree)
			if wayID == 2 {
				set.PseudoLRUBits |= (1 << 2) // Set bit 2
			} else {
				set.PseudoLRUBits &= ^uint64(1 << 2) // Clear bit 2
			}
		}
	case 8:
		// 8-way: 7 bits (full binary tree)
		d.updatePseudoLRU8Way(set, wayID)
	default:
		// Fallback: use simple round-robin for other associativities
		set.PseudoLRUBits = (set.PseudoLRUBits + 1) % uint64(numWays)
	}
}

// updatePseudoLRU8Way handles 8-way associative PseudoLRU
func (d *DirectoryImpl) updatePseudoLRU8Way(set *Set, wayID int) {
	// 8-way PseudoLRU tree: 7 bits
	//        bit0
	//      /      \
	//    bit1     bit2
	//   /   \    /    \
	// bit3 bit4 bit5 bit6
	// /|   |\ /|   |\
	//W0W1 W2W3W4W5 W6W7

	if wayID < 4 {
		set.PseudoLRUBits &= ^uint64(1) // Clear bit 0 (left subtree)
		if wayID < 2 {
			set.PseudoLRUBits &= ^uint64(1 << 1) // Clear bit 1
			if wayID == 0 {
				set.PseudoLRUBits |= (1 << 3) // Set bit 3
			} else {
				set.PseudoLRUBits &= ^uint64(1 << 3) // Clear bit 3
			}
		} else {
			set.PseudoLRUBits |= (1 << 1) // Set bit 1
			if wayID == 2 {
				set.PseudoLRUBits |= (1 << 4) // Set bit 4
			} else {
				set.PseudoLRUBits &= ^uint64(1 << 4) // Clear bit 4
			}
		}
	} else {
		set.PseudoLRUBits |= 1 // Set bit 0 (right subtree)
		if wayID < 6 {
			set.PseudoLRUBits &= ^uint64(1 << 2) // Clear bit 2
			if wayID == 4 {
				set.PseudoLRUBits |= (1 << 5) // Set bit 5
			} else {
				set.PseudoLRUBits &= ^uint64(1 << 5) // Clear bit 5
			}
		} else {
			set.PseudoLRUBits |= (1 << 2) // Set bit 2
			if wayID == 6 {
				set.PseudoLRUBits |= (1 << 6) // Set bit 6
			} else {
				set.PseudoLRUBits &= ^uint64(1 << 6) // Clear bit 6
			}
		}
	}
}

// GetSets returns all the sets in a directory
func (d *DirectoryImpl) GetSets() []Set {
	return d.Sets
}

// Reset will mark all the blocks in the directory invalid
func (d *DirectoryImpl) Reset() {
	d.Sets = make([]Set, d.NumSets)
	for i := 0; i < d.NumSets; i++ {
		for j := 0; j < d.NumWays; j++ {
			block := new(Block)
			block.IsValid = false
			block.SetID = i
			block.WayID = j
			block.CacheAddress = uint64(i*d.NumWays+j) * uint64(d.BlockSize)
			d.Sets[i].Blocks = append(d.Sets[i].Blocks, block)
			// LRU queue initialization removed for performance
		}
	}
}

// WayAssociativity returns the number of ways per set in the cache.
func (d *DirectoryImpl) WayAssociativity() int {
	return d.NumWays
}

// GetVictimFinder returns the victim finder used by this directory.
func (d *DirectoryImpl) GetVictimFinder() VictimFinder {
	return d.victimFinder
}
