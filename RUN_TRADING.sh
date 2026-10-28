#!/bin/bash

# Source the configuration (loads API credentials)
source config.sh

# Now run the trading command
./StockSwingTrader_Agent.sh "$@"

