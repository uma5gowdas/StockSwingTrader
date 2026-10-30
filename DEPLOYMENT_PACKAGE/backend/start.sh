#!/bin/bash

# StockSwingTrader Backend Startup Script
# Launches the Node/Express backend on port 3000

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_status() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

print_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

# Check if Node.js is installed
if ! command -v node &> /dev/null; then
    print_error "Node.js is not installed. Please install Node.js v16 or higher."
    exit 1
fi

# Check if npm is installed
if ! command -v npm &> /dev/null; then
    print_error "npm is not installed. Please install npm."
    exit 1
fi

print_status "StockSwingTrader Backend Startup"
print_status "Node version: $(node --version)"
print_status "npm version: $(npm --version)"

cd "$SCRIPT_DIR"

# Check if node_modules exists
if [ ! -d "node_modules" ]; then
    print_warning "node_modules not found. Installing dependencies..."
    npm install
fi

# Check if server.js exists
if [ ! -f "server.js" ]; then
    print_error "server.js not found in backend directory"
    exit 1
fi

# Kill any existing process on port 3000 (optional)
if command -v lsof &> /dev/null; then
    PID=$(lsof -ti:3000 2>/dev/null || true)
    if [ ! -z "$PID" ]; then
        print_warning "Port 3000 is in use (PID: $PID). Attempting to kill..."
        kill -9 $PID 2>/dev/null || true
        sleep 1
    fi
fi

# Start the server
print_status "Starting backend server on port 3000..."
print_status "Frontend expected on http://localhost:5173"
print_status "API documentation available at http://localhost:3000/api/health"

# Use npm start to run the server
npm start
