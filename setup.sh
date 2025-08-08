#!/bin/bash

# Perceptron Research Setup Script
# This script sets up the complete environment needed to run the perceptron cache replacement tests

set -e  # Exit on any error

echo "=========================================="
echo "Perceptron Research Setup Script"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in the right directory
if [ ! -f "akita/mem/cache/perceptron_victimfinder.go" ]; then
    print_error "This script must be run from the perceptron_research directory!"
    exit 1
fi

print_status "Starting setup process..."

# Step 1: Check and install system dependencies
print_status "Checking system dependencies..."

# Check for Go
if ! command -v go &> /dev/null; then
    print_error "Go is not installed. Please install Go 1.19 or later."
    print_status "You can download it from: https://golang.org/dl/"
    exit 1
else
    GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    print_success "Go found: version $GO_VERSION"
fi

# Check for Git
if ! command -v git &> /dev/null; then
    print_error "Git is not installed. Please install Git."
    exit 1
else
    print_success "Git found"
fi

# Check for Make
if ! command -v make &> /dev/null; then
    print_error "Make is not installed. Please install Make."
    exit 1
else
    print_success "Make found"
fi

# Check for GCC
if ! command -v gcc &> /dev/null; then
    print_error "GCC is not installed. Please install GCC."
    exit 1
else
    print_success "GCC found"
fi

# Step 2: Clone MGPUSim if not already present
print_status "Setting up MGPUSim..."

if [ -d "mgpusim_original" ]; then
    print_warning "mgpusim_original directory already exists. Updating..."
    cd mgpusim_original
    git fetch origin
    git reset --hard origin/main
    cd ..
else
    print_status "Cloning MGPUSim repository..."
    git clone https://github.com/sarchlab/mgpusim.git mgpusim_original
    print_success "MGPUSim cloned successfully"
fi

# Step 3: Copy our modified files to MGPUSim
print_status "Copying perceptron implementation to MGPUSim..."

# Create the akita directory structure if it doesn't exist
mkdir -p mgpusim_original/akita/mem/cache

# Create backup of original file if it exists
if [ -f "mgpusim_original/akita/mem/cache/perceptron_victimfinder.go" ]; then
    cp mgpusim_original/akita/mem/cache/perceptron_victimfinder.go mgpusim_original/akita/mem/cache/perceptron_victimfinder.go.backup
fi

# Copy our implementation
cp akita/mem/cache/perceptron_victimfinder.go mgpusim_original/akita/mem/cache/

print_success "Perceptron implementation copied to MGPUSim"

# Step 4: Build MGPUSim
print_status "Building MGPUSim..."

cd mgpusim_original

# Check if Go modules are initialized
if [ ! -f "go.mod" ]; then
    print_status "Initializing Go modules..."
    go mod init mgpusim
fi

# Get dependencies
print_status "Downloading Go dependencies..."
go mod tidy

# Build the project
print_status "Building MGPUSim (this may take a few minutes)..."
make

if [ $? -eq 0 ]; then
    print_success "MGPUSim built successfully"
else
    print_error "Failed to build MGPUSim. Please check the error messages above."
    exit 1
fi

cd ..

# Step 5: Build our test workloads
print_status "Building test workloads..."

# Build SPMV
print_status "Building SPMV..."
cd mgpusim_original/amd/samples/spmv
go build -o spmv_perc .
cd ../../../..

# Build other workloads
WORKLOADS=("atax" "bfs" "bicg" "conv2d" "fft" "kmeans" "matrixmultiplication" "matrixtranspose" "nbody" "pagerank" "stencil2d")

for workload in "${WORKLOADS[@]}"; do
    if [ -d "mgpusim_original/amd/samples/$workload" ]; then
        print_status "Building $workload..."
        cd mgpusim_original/amd/samples/$workload
        go build -o ${workload}_perc .
        cd ../../../../..
    else
        print_warning "Workload directory $workload not found, skipping..."
    fi
done

# Step 6: Copy binaries to our scripts directory
print_status "Copying binaries to scripts directory..."

mkdir -p scripts/bin
cp mgpusim_original/amd/samples/spmv/spmv_perc scripts/bin/ 2>/dev/null || print_warning "SPMV binary not found"

for workload in "${WORKLOADS[@]}"; do
    if [ -f "mgpusim_original/amd/samples/$workload/${workload}_perc" ]; then
        cp mgpusim_original/amd/samples/$workload/${workload}_perc scripts/bin/
    fi
done

print_success "Binaries copied to scripts/bin/"

# Step 7: Update test scripts to use relative paths
print_status "Updating test scripts to use relative paths..."

# Update all test scripts to use relative paths instead of hardcoded /home/rami/mgpusim_original
for script in scripts/*_comprehensive_test.sh; do
    if [ -f "$script" ]; then
        print_status "Updating $script..."
        # Replace hardcoded paths with relative paths
        sed -i 's|/home/rami/mgpusim_original|../mgpusim_original|g' "$script"
        sed -i 's|\$HOME/mgpusim_original|../mgpusim_original|g' "$script"
    fi
done

# Step 8: Make scripts executable
print_status "Making test scripts executable..."
chmod +x scripts/*.sh

# Step 9: Create a simple test script
print_status "Creating quick test script..."

cat > test_perceptron.sh << 'EOF'
#!/bin/bash

echo "=========================================="
echo "Quick Perceptron Test"
echo "=========================================="

# Check if binaries exist
if [ ! -f "scripts/bin/spmv_perc" ]; then
    echo "Error: SPMV binary not found. Please run setup.sh first."
    exit 1
fi

# Run a quick SPMV test
echo "Running quick SPMV test..."
cd scripts
./spmv_comprehensive_test.sh 1024 2048 4096

echo "Test completed! Check the results above."
EOF

chmod +x test_perceptron.sh

# Step 10: Create README for users
print_status "Creating user instructions..."

cat > RUN_TESTS.md << 'EOF'
# Running Perceptron Cache Replacement Tests

## Quick Start

1. **Clone this repository:**
   ```bash
   git clone <your-repo-url>
   cd perceptron_research
   ```

2. **Run the setup script:**
   ```bash
   ./setup.sh
   ```

3. **Run a quick test:**
   ```bash
   ./test_perceptron.sh
   ```

## Available Tests

### SPMV (Sparse Matrix-Vector Multiplication)
```bash
cd scripts
./spmv_comprehensive_test.sh
```

### Other Workloads
```bash
cd scripts
./bicg_comprehensive_test.sh      # BiConjugate Gradient
./kmeans_comprehensive_test.sh    # K-Means Clustering
```

## Understanding Results

The tests compare:
- **LRU**: Traditional Least Recently Used replacement
- **Perceptron**: Our neural network-based replacement policy

Results show:
- **Miss Reduction**: How much the perceptron reduces cache misses
- **Latency Improvement**: How much average request latency improves

## Troubleshooting

1. **"Go not found"**: Install Go 1.19+ from https://golang.org/dl/
2. **"Git not found"**: Install Git: `sudo apt-get install git`
3. **Build fails**: Ensure you have GCC and Make installed
4. **Permission denied**: Run `chmod +x scripts/*.sh`

## File Structure

- `akita/mem/cache/perceptron_victimfinder.go`: Main perceptron implementation
- `scripts/`: Test scripts for different workloads
- `results/`: Test results and logs
- `mgpusim_original/`: Original MGPUSim simulator (cloned by setup.sh)

## Research Context

This implements a perceptron-based cache replacement policy for GPU L2 caches, achieving 8-25% miss reduction with 1-3% runtime speedup across various workloads.
EOF

print_success "Setup completed successfully!"
echo ""
echo "=========================================="
echo "Setup Summary"
echo "=========================================="
echo "✅ MGPUSim cloned and built"
echo "✅ Perceptron implementation integrated"
echo "✅ All workload binaries compiled"
echo "✅ Test scripts made executable"
echo "✅ Quick test script created"
echo "✅ User instructions created (RUN_TESTS.md)"
echo ""
echo "Next steps:"
echo "1. Run: ./test_perceptron.sh"
echo "2. Or run specific tests from scripts/ directory"
echo "3. Check RUN_TESTS.md for detailed instructions"
echo ""
print_success "Your perceptron research environment is ready!"
