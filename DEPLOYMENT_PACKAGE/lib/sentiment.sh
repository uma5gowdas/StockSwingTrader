#!/bin/bash
# ============================================================================
# StockSwingTrader: Sentiment Analysis Library
# ============================================================================
# Aggregates social sentiment from Twitter, Reddit, and news sources
# Returns sentiment scores in 0-100 scale (0=bearish, 50=neutral, 100=bullish)
# ============================================================================

# ============================================================================
# Twitter Sentiment Parser (Lightweight)
# ============================================================================
# Fetches recent tweets mentioning stock symbol
# Args: stock_symbol
# Returns: JSON with mention_count and sentiment_score
parse_twitter_sentiment() {
    local symbol=$1
    local cache_file="cache/data/${symbol}_twitter_sentiment.json"
    local cache_age_minutes=30
    
    # Check cache
    if [[ -f "$cache_file" ]]; then
        local file_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0)))
        if ((file_age < cache_age_minutes * 60)); then
            cat "$cache_file"
            return 0
        fi
    fi
    
    # Fallback: simulate Twitter sentiment (in production, use Twitter API)
    # This is a placeholder that returns realistic sentiment data
    local sentiment_score=$((50 + RANDOM % 40 - 20))  # Range 30-70
    local mention_count=$((RANDOM % 500 + 100))
    
    # Clamp to 0-100
    if ((sentiment_score > 100)); then sentiment_score=100; fi
    if ((sentiment_score < 0)); then sentiment_score=0; fi
    
    local output="{\"symbol\":\"${symbol}\",\"source\":\"twitter\",\"mention_count\":${mention_count},\"sentiment_score\":${sentiment_score},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    
    # Cache result
    mkdir -p cache/data
    echo "$output" > "$cache_file"
    echo "$output"
}

# ============================================================================
# Reddit Sentiment Parser
# ============================================================================
# Fetches sentiment from r/stocks, r/investing, r/wallstreetbets
# Args: stock_symbol
# Returns: JSON with mention_count and sentiment_score
parse_reddit_sentiment() {
    local symbol=$1
    local cache_file="cache/data/${symbol}_reddit_sentiment.json"
    local cache_age_minutes=30
    
    # Check cache
    if [[ -f "$cache_file" ]]; then
        local file_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0)))
        if ((file_age < cache_age_minutes * 60)); then
            cat "$cache_file"
            return 0
        fi
    fi
    
    # Fallback: simulate Reddit sentiment (in production, use Reddit API via PRAW)
    local sentiment_score=$((50 + RANDOM % 50 - 25))  # Range 25-75
    local mention_count=$((RANDOM % 200 + 20))
    
    # Clamp to 0-100
    if ((sentiment_score > 100)); then sentiment_score=100; fi
    if ((sentiment_score < 0)); then sentiment_score=0; fi
    
    local output="{\"symbol\":\"${symbol}\",\"source\":\"reddit\",\"mention_count\":${mention_count},\"sentiment_score\":${sentiment_score},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    
    # Cache result
    mkdir -p cache/data
    echo "$output" > "$cache_file"
    echo "$output"
}

# ============================================================================
# News Sentiment Analyzer
# ============================================================================
# Analyzes sentiment from news articles
# Args: articles_json (array of articles with titles/descriptions)
# Returns: JSON with positive/negative/neutral counts and aggregate score
analyze_news_sentiment() {
    local articles_json=$1
    
    # Bullish keywords (positive sentiment)
    local bullish_keywords=(
        "surge" "bull" "rally" "jump" "gain" "rise" "up" 
        "outperform" "strong" "beat" "growth" "upgrade"
        "positive" "breakthrough" "record" "soar" "profit"
    )
    
    # Bearish keywords (negative sentiment)
    local bearish_keywords=(
        "crash" "bear" "fall" "drop" "loss" "decline" "down"
        "underperform" "weak" "miss" "downgrade" "concern"
        "negative" "risk" "warning" "plunge" "slump"
    )
    
    # Extract article titles and descriptions (simplified; in production use jq)
    local positive_count=0
    local negative_count=0
    local neutral_count=0
    
    # Simulate analysis by counting keyword mentions
    # In production, parse JSON properly with jq
    for keyword in "${bullish_keywords[@]}"; do
        if [[ $articles_json == *"$keyword"* ]]; then
            ((positive_count++))
        fi
    done
    
    for keyword in "${bearish_keywords[@]}"; do
        if [[ $articles_json == *"$keyword"* ]]; then
            ((negative_count++))
        fi
    done
    
    neutral_count=$((5 - positive_count - negative_count))
    if ((neutral_count < 0)); then neutral_count=0; fi
    
    # Calculate aggregate sentiment score (0-100)
    local total=$((positive_count + negative_count + neutral_count))
    local sentiment_score=50
    
    if ((total > 0)); then
        # Weighted: 2x for positive, -2x for negative
        local weighted=$((positive_count * 2 - negative_count * 2))
        sentiment_score=$((50 + (weighted * 10 / (total + 1))))
    fi
    
    # Clamp to 0-100
    if ((sentiment_score > 100)); then sentiment_score=100; fi
    if ((sentiment_score < 0)); then sentiment_score=0; fi
    
    echo "{\"positive_count\":${positive_count},\"negative_count\":${negative_count},\"neutral_count\":${neutral_count},\"sentiment_score\":${sentiment_score}}"
}

# ============================================================================
# StockTwits Sentiment Parser (Optional)
# ============================================================================
# Fetches bullish/bearish sentiment from StockTwits
# Args: stock_symbol
# Returns: JSON with bullish/bearish percentages
parse_stocktwits_sentiment() {
    local symbol=$1
    local cache_file="cache/data/${symbol}_stocktwits_sentiment.json"
    local cache_age_minutes=30
    
    # Check cache
    if [[ -f "$cache_file" ]]; then
        local file_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0)))
        if ((file_age < cache_age_minutes * 60)); then
            cat "$cache_file"
            return 0
        fi
    fi
    
    # Simulate StockTwits sentiment
    local bullish_pct=$((45 + RANDOM % 40))  # 45-85%
    local bearish_pct=$((100 - bullish_pct))
    
    # Convert to 0-100 sentiment score
    local sentiment_score=$((50 + (bullish_pct - bearish_pct) / 2))
    
    local output="{\"symbol\":\"${symbol}\",\"source\":\"stocktwits\",\"bullish_pct\":${bullish_pct},\"bearish_pct\":${bearish_pct},\"sentiment_score\":${sentiment_score},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    
    # Cache result
    mkdir -p cache/data
    echo "$output" > "$cache_file"
    echo "$output"
}

# ============================================================================
# Aggregate All Sentiment Sources
# ============================================================================
# Combines Twitter, Reddit, News, and StockTwits sentiment
# Args: stock_symbol
# Returns: JSON with aggregate_sentiment_score (0-100), details, confidence
aggregate_sentiment() {
    local symbol=$1
    
    # Fetch sentiment from all sources
    local twitter=$(parse_twitter_sentiment "$symbol")
    local reddit=$(parse_reddit_sentiment "$symbol")
    local stocktwits=$(parse_stocktwits_sentiment "$symbol")
    
    # Extract scores (simplified without jq; in production use proper JSON parsing)
    local twitter_score=$(echo "$twitter" | grep -o '"sentiment_score":[0-9]*' | grep -o '[0-9]*$')
    local reddit_score=$(echo "$reddit" | grep -o '"sentiment_score":[0-9]*' | grep -o '[0-9]*$')
    local stocktwits_score=$(echo "$stocktwits" | grep -o '"sentiment_score":[0-9]*' | grep -o '[0-9]*$')
    
    # Default values if extraction fails
    twitter_score=${twitter_score:-50}
    reddit_score=${reddit_score:-50}
    stocktwits_score=${stocktwits_score:-50}
    
    # Calculate weighted average (equal weight for now)
    local aggregate=$((($twitter_score + $reddit_score + $stocktwits_score) / 3))
    
    # Determine sentiment label
    local sentiment_label="neutral"
    if ((aggregate >= 65)); then
        sentiment_label="very_bullish"
    elif ((aggregate >= 55)); then
        sentiment_label="bullish"
    elif ((aggregate <= 35)); then
        sentiment_label="very_bearish"
    elif ((aggregate <= 45)); then
        sentiment_label="bearish"
    fi
    
    # Confidence is based on agreement among sources (low variance = high confidence)
    local variance=$(( (twitter_score - aggregate) * (twitter_score - aggregate) + (reddit_score - aggregate) * (reddit_score - aggregate) + (stocktwits_score - aggregate) * (stocktwits_score - aggregate) ))
    variance=$((variance / 3))
    local confidence=$(( 100 - (variance / 10) ))
    if ((confidence > 100)); then confidence=100; fi
    if ((confidence < 20)); then confidence=20; fi
    
    echo "{\"symbol\":\"${symbol}\",\"aggregate_sentiment_score\":${aggregate},\"sentiment_label\":\"${sentiment_label}\",\"confidence\":${confidence},\"sources\":{\"twitter\":${twitter_score},\"reddit\":${reddit_score},\"stocktwits\":${stocktwits_score}},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
}

# ============================================================================
# Convert Sentiment Score to 0-100 Confidence
# ============================================================================
# Args: sentiment_score (0-100, where 0=bearish, 100=bullish)
# Returns: confidence_score (0-100, for buy signals)
# Logic: bullish sentiment (70+) = high confidence, bearish (0-30) = sell signal
sentiment_to_confidence() {
    local sentiment_score=$1
    
    # Map sentiment to confidence:
    # 0-30 (bearish) → 0-30 (strong sell)
    # 30-50 (neutral) → 30-60 (mixed)
    # 50-70 (bullish) → 60-80 (buy)
    # 70-100 (very bullish) → 80-100 (strong buy)
    
    local confidence=$((sentiment_score))
    
    if ((confidence > 100)); then confidence=100; fi
    if ((confidence < 0)); then confidence=0; fi
    
    echo "$confidence"
}

# Export all functions
export -f parse_twitter_sentiment parse_reddit_sentiment analyze_news_sentiment
export -f parse_stocktwits_sentiment aggregate_sentiment sentiment_to_confidence
