#!/bin/bash

##############################################################################
# ML Predictor Module - XGBoost Based Stock Direction Prediction
# 
# Functions:
#   ml_predict_direction(symbol, period) - Predict stock direction using XGBoost
#
# Dependencies: Python 3.8+, xgboost, pandas, numpy, joblib
##############################################################################

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}"
MODELS_DIR="${LIB_DIR}/models"
PYTHON_SCRIPT="${LIB_DIR}/ml_inference.py"

##############################################################################
# Function: ml_predict_direction
# Description: Predicts stock price direction using trained XGBoost model
# 
# Arguments:
#   $1 - symbol: Stock symbol (e.g., "AAPL")
#   $2 - period: Forecast period in days (e.g., 5)
#   $3 - ohlcv_json: Current OHLCV data as JSON (optional stdin)
#
# Returns:
#   JSON with direction, confidence, probability
#   {"direction": "up"|"down", "confidence": 0-100, "probability": 0.0-1.0}
#   {"error": "message"} on failure
#
# Example:
#   ml_predict_direction "AAPL" 5
##############################################################################
ml_predict_direction() {
    local symbol="${1:-}"
    local period="${2:-5}"
    
    if [[ -z "$symbol" ]]; then
        echo "{\"error\": \"Symbol is required\"}" >&2
        return 1
    fi
    
    # Check if model file exists
    if [[ ! -f "${MODELS_DIR}/xgboost_predictor.pkl" ]]; then
        echo "{\"error\": \"Model file not found at ${MODELS_DIR}/xgboost_predictor.pkl. Run train_ml_model.py first.\"}" >&2
        return 1
    fi
    
    # Check if Python inference script exists
    if [[ ! -f "${PYTHON_SCRIPT}" ]]; then
        echo "{\"error\": \"Python inference script not found at ${PYTHON_SCRIPT}\"}" >&2
        return 1
    fi
    
    # Read OHLCV data from stdin or create placeholder for current data fetch
    local ohlcv_data
    if [[ -t 0 ]]; then
        # No stdin, create placeholder data structure
        ohlcv_data=$(cat <<'EOF'
{
  "symbol": "PLACEHOLDER",
  "open": 0.0,
  "high": 0.0,
  "low": 0.0,
  "close": 0.0,
  "volume": 0
}
EOF
)
    else
        # Read from stdin
        ohlcv_data=$(cat)
    fi
    
    # Call Python inference script with symbol and period. stderr (warnings)
    # is kept separate so stdout stays pure JSON.
    local result
    local err_file
    err_file=$(mktemp "${TMPDIR:-/tmp}/ml_predict_err.XXXXXX")
    result=$(python3 "${PYTHON_SCRIPT}" --symbol "${symbol}" --period "${period}" 2>"$err_file" <<< "${ohlcv_data}")
    
    local exit_code=$?
    local err_text
    err_text=$(tail -1 "$err_file" | tr -d '"\\')
    rm -f "$err_file"
    
    if [[ $exit_code -ne 0 ]]; then
        local reason
        reason=$(echo "$result" | jq -r '.error // empty' 2>/dev/null)
        echo "{\"error\": \"Python inference failed: ${reason:-$err_text}\"}" >&2
        return 1
    fi
    
    echo "${result}"
    return 0
}

##############################################################################
# Function: ml_get_model_status
# Description: Checks if model is trained and ready for inference
#
# Returns:
#   JSON with model status information
##############################################################################
ml_get_model_status() {
    if [[ -f "${MODELS_DIR}/xgboost_predictor.pkl" ]]; then
        local file_size
        file_size=$(stat -f%z "${MODELS_DIR}/xgboost_predictor.pkl" 2>/dev/null || stat -c%s "${MODELS_DIR}/xgboost_predictor.pkl" 2>/dev/null)
        
        local mod_time
        mod_time=$(stat -f%Sm -t "%Y-%m-%d %H:%M:%S" "${MODELS_DIR}/xgboost_predictor.pkl" 2>/dev/null || stat -c%y "${MODELS_DIR}/xgboost_predictor.pkl" 2>/dev/null | cut -d' ' -f1-2)
        
        echo "{\"status\": \"ready\", \"model_file\": \"${MODELS_DIR}/xgboost_predictor.pkl\", \"size_bytes\": ${file_size}, \"modified\": \"${mod_time}\"}"
    else
        echo "{\"status\": \"not_trained\", \"message\": \"Model not found. Run train_ml_model.py to train.\"}"
    fi
}

##############################################################################
# Function: ml_batch_predict
# Description: Batch predict for multiple symbols
#
# Arguments:
#   $1 - symbols_list: JSON array of symbols
#   $2 - period: Forecast period
#
# Returns:
#   JSON array of predictions
##############################################################################
ml_batch_predict() {
    local symbols_list="${1:-}"
    local period="${2:-5}"
    
    if [[ -z "$symbols_list" ]]; then
        echo "{\"error\": \"Symbols list is required\"}" >&2
        return 1
    fi
    
    # Extract symbols from JSON array and predict each
    local results="["
    local first=true
    
    # Simple JSON array parser for symbols
    while IFS= read -r symbol; do
        symbol=$(echo "$symbol" | tr -d ' "')
        if [[ -n "$symbol" ]]; then
            if [[ "$first" == true ]]; then
                first=false
            else
                results+=","
            fi
            
            local prediction
            prediction=$(ml_predict_direction "$symbol" "$period" 2>/dev/null)
            results+="${prediction}"
        fi
    done < <(echo "$symbols_list" | grep -oE '"[^"]+"' | tr -d '"')
    
    results+="]"
    echo "$results"
}

##############################################################################
# Main execution: Allow sourcing or direct invocation
##############################################################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being executed directly
    case "${1:-}" in
        predict)
            ml_predict_direction "$2" "$3"
            ;;
        status)
            ml_get_model_status
            ;;
        batch)
            ml_batch_predict "$2" "$3"
            ;;
        *)
            cat <<'USAGE'
Usage: ml_predictor.sh <command> [options]

Commands:
  predict <symbol> <period>    Predict direction for a symbol (default period=5)
  status                        Check model status
  batch <json_array> <period>   Batch predict for multiple symbols

Examples:
  ./ml_predictor.sh predict AAPL 5
  ./ml_predictor.sh status
  ./ml_predictor.sh batch '["AAPL", "MSFT"]' 5

Environment:
  Models directory: ${MODELS_DIR}
  Python script: ${PYTHON_SCRIPT}

USAGE
            exit 1
            ;;
    esac
fi
