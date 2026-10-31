#!/bin/bash
# ============================================================================
# StockSwingTrader: Sentiment Analysis Library
# ============================================================================
# One deterministic sentiment path:
#   aggregate_sentiment SYMBOL
#     -> parse_twitter_sentiment / parse_reddit_sentiment /
#        parse_stocktwits_sentiment  (no API integration: always "unavailable")
#     -> news_sentiment SYMBOL
#          -> fetch_news_articles (Finnhub company-news, else NewsAPI
#             everything; only when a real key is configured)
#          -> analyze_news_sentiment (per-article weighted keyword classifier
#             with negation discount, ported from v6.2 Phase 1
#             phase1/lib/sentiment_analyzer.sh)
#   Only available sources are averaged. If none is available the aggregate
#   score is null and callers give sentiment 0 weight.
#
# Scores use a 0-100 scale (0=bearish, 50=neutral, 100=bullish).
# There is no randomness in this file: earlier versions generated random
# social scores, which made identical inputs produce different signals.
# ============================================================================

# ----------------------------------------------------------------------------
# _sentiment_unavailable SYMBOL SOURCE REASON
# Description: Standard "no data" record for a source
# Returns: JSON {symbol, source, status:"unavailable", reason, sentiment_score:null, timestamp}
# ----------------------------------------------------------------------------
_sentiment_unavailable() {
    jq -cn --arg symbol "$1" --arg source "$2" --arg reason "$3" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{symbol:$symbol, source:$source, status:"unavailable", reason:$reason, sentiment_score:null, timestamp:$ts}'
}

# ----------------------------------------------------------------------------
# _sentiment_key_configured VALUE
# Description: rc 0 if VALUE looks like a real API key (not empty/demo/YOUR_*)
# ----------------------------------------------------------------------------
_sentiment_key_configured() {
    local key="$1"
    [[ -n "$key" && "$key" != "demo" && "$key" != YOUR_* ]]
}

# ============================================================================
# Social sources (no API integration)
# ============================================================================
# Args: stock_symbol
# Returns: unavailable JSON. These used to return random numbers; there is no
# Twitter/Reddit/StockTwits client configured, so they now say so explicitly.
parse_twitter_sentiment() {
    _sentiment_unavailable "$1" "twitter" "no API configured"
}

parse_reddit_sentiment() {
    _sentiment_unavailable "$1" "reddit" "no API configured"
}

parse_stocktwits_sentiment() {
    _sentiment_unavailable "$1" "stocktwits" "no API configured"
}

# ============================================================================
# News fetch
# ============================================================================
# ----------------------------------------------------------------------------
# fetch_news_articles SYMBOL
# Description: Fetch recent articles for SYMBOL. Finnhub company-news (last 7
#   days) if ENABLE_FINNHUB != false and API_KEY_FINNHUB is real; otherwise
#   NewsAPI everything if ENABLE_NEWSAPI != false and API_KEY_NEWSAPI is real.
#   Keys are sent in headers, never in the URL. Returns 1 immediately when
#   SST_OFFLINE=1 or no key is configured (no network attempt).
# Returns: JSON array [{headline, summary}] on line 1 and the provider name
#   (finnhub|newsapi) on line 2; rc 1 when nothing usable was fetched.
# ----------------------------------------------------------------------------
fetch_news_articles() {
    local symbol="$1"
    [[ "${SST_OFFLINE:-0}" == "1" ]] && return 1
    [[ "$symbol" =~ ^[A-Za-z0-9.-]{1,10}$ ]] || return 1

    local n="${SENTIMENT_NEWS_COUNT:-10}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=10
    local max_time="${SENTIMENT_TIMEOUT_SECONDS:-5}"
    [[ "$max_time" =~ ^[0-9]+$ ]] || max_time=5

    local raw articles provider=""
    if [[ "${ENABLE_FINNHUB:-true}" != "false" ]] && _sentiment_key_configured "$API_KEY_FINNHUB"; then
        local to from
        to=$(date -u +%F)
        from=$(date -u -v-7d +%F 2>/dev/null || date -u -d '7 days ago' +%F)
        raw=$(curl -sS --connect-timeout 2 --max-time "$max_time" \
            -H "X-Finnhub-Token: $API_KEY_FINNHUB" \
            "${FINNHUB_BASE_URL:-https://finnhub.io/api/v1}/company-news?symbol=${symbol}&from=${from}&to=${to}" 2>/dev/null)
        articles=$(echo "$raw" | jq -c --argjson n "$n" \
            'if type == "array" then [.[:$n][] | {headline:(.headline // ""), summary:(.summary // "")}] else empty end' 2>/dev/null)
        provider="finnhub"
    elif [[ "${ENABLE_NEWSAPI:-true}" != "false" ]] && _sentiment_key_configured "$API_KEY_NEWSAPI"; then
        raw=$(curl -sS --connect-timeout 2 --max-time "$max_time" \
            -H "X-Api-Key: $API_KEY_NEWSAPI" \
            "${NEWSAPI_BASE_URL:-https://newsapi.org/v2}/everything?q=${symbol}&language=en&sortBy=publishedAt&pageSize=${n}" 2>/dev/null)
        articles=$(echo "$raw" | jq -c \
            'if (.articles | type) == "array" then [.articles[] | {headline:(.title // ""), summary:(.description // "")}] else empty end' 2>/dev/null)
        provider="newsapi"
    else
        return 1
    fi

    if [[ -z "$articles" || "$articles" == "[]" ]]; then
        return 1
    fi
    echo "$articles"
    echo "$provider"
}

# ============================================================================
# News Sentiment Analyzer
# ============================================================================
# ----------------------------------------------------------------------------
# analyze_news_sentiment ARTICLES_JSON
# Description: Per-article weighted keyword classification (v6.2 Phase 1
#   keyword tables). Each article's "headline summary" text is lowercased and
#   matched by substring. When a negation word is present, both bullish and
#   bearish weights are multiplied by SENTIMENT_NEGATION_DISCOUNT (0.7). The
#   article is BULLISH/BEARISH by the larger weight, else NEUTRAL.
#   bias = (bullish - bearish) / articles, score = round(50 + 50*bias).
#   A non-array argument is treated as one article's text (old call style).
# Args: ARTICLES_JSON ([{headline, summary}] or plain text)
# Returns: JSON {positive_count, negative_count, neutral_count,
#   articles_analyzed, sentiment_bias, sentiment_score, status}
#   Zero articles -> sentiment_score null, status "unavailable".
# ----------------------------------------------------------------------------
analyze_news_sentiment() {
    local input="$1"
    local lines
    lines=$(printf '%s' "$input" | jq -r 'if type == "array" then .[] | ((.headline // "") + " " + (.summary // "")) else tostring end | ascii_downcase | gsub("[\r\n]"; " ")' 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        # Not JSON: treat the raw text as a single article
        lines=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | tr '\r\n' '  ')
    fi

    local counts
    counts=$(printf '%s\n' "$lines" | awk -v disc="${SENTIMENT_NEGATION_DISCOUNT:-0.7}" '
        BEGIN {
            # Multi-word keywords use "_" in the list; kw_weight matches them with spaces.
            nb = split("beat:1.0 earnings_beat:1.5 upgrade:1.2 bullish:1.0 buy:0.8 gain:0.8 rise:0.7 surge:1.0 rally:0.9 strong:0.7 outperform:1.0 positive:0.8 exceeds:0.9 record:0.8 boom:1.0 growth:0.7 profit:0.8 revenue_up:1.0 market_share:0.8 acquisition:0.7 partnership:0.6 expansion:0.7 opportunity:0.6 upside:0.9 top_pick:1.0 momentum:0.8 catalyst:0.7 breakout:0.9 outperforms:1.0", BL, " ")
            nr = split("miss:1.0 earnings_miss:1.5 downgrade:1.2 bearish:1.0 sell:0.8 loss:0.8 fall:0.7 crash:1.0 decline:0.9 weak:0.7 underperform:1.0 negative:0.8 misses:1.0 misses_estimates:1.2 concern:0.7 risk:0.6 warning:0.8 threat:0.7 pressure:0.6 down:0.7 deficit:0.8 disappointing:0.9 failure:1.0 bankruptcy:1.5 lawsuit:0.9 recall:0.9 breach:0.8 downside:0.9 underperforms:1.0", BR, " ")
            nn = split("doesn'"'"'t|don'"'"'t|not |no |fails|unable|disappointing|won'"'"'t|cannot|avoid", NEG, "|")
            pos = 0; neg = 0; neu = 0; total = 0
        }
        function kw_weight(list, n, text,    i, k, w, sum, idx) {
            sum = 0
            for (i = 1; i <= n; i++) {
                idx = index(list[i], ":")
                k = substr(list[i], 1, idx - 1)
                gsub(/_/, " ", k)
                w = substr(list[i], idx + 1) + 0
                if (index(text, k) > 0) sum += w
            }
            return sum
        }
        {
            text = $0
            if (text ~ /^[[:space:]]*$/) next
            total++
            b = kw_weight(BL, nb, text); r = kw_weight(BR, nr, text)
            for (i = 1; i <= nn; i++) if (index(text, NEG[i]) > 0) { b *= disc; r *= disc; break }
            if (b > r) pos++; else if (r > b) neg++; else neu++
        }
        END { printf "%d %d %d %d\n", pos, neg, neu, total }
    ' 2>/dev/null)

    local pos neg neu total
    read -r pos neg neu total <<< "$counts"
    pos=${pos:-0}; neg=${neg:-0}; neu=${neu:-0}; total=${total:-0}

    if (( total == 0 )); then
        jq -cn '{positive_count:0, negative_count:0, neutral_count:0, articles_analyzed:0, sentiment_bias:0, sentiment_score:null, status:"unavailable"}'
        return 0
    fi
    local bias score
    bias=$(awk -v p="$pos" -v n="$neg" -v t="$total" 'BEGIN { printf "%.2f", (p - n) / t }')
    score=$(awk -v b="$bias" 'BEGIN { s = 50 + 50 * b; printf "%d", (s >= 0) ? int(s + 0.5) : -int(-s + 0.5) }')
    jq -cn --argjson p "$pos" --argjson n "$neg" --argjson u "$neu" --argjson t "$total" \
        --argjson bias "$bias" --argjson score "$score" \
        '{positive_count:$p, negative_count:$n, neutral_count:$u, articles_analyzed:$t, sentiment_bias:$bias, sentiment_score:$score, status:"ok"}'
}

# ----------------------------------------------------------------------------
# news_sentiment SYMBOL
# Description: fetch_news_articles + analyze_news_sentiment. Successful
#   results are cached for 30 min in ${SENTIMENT_CACHE_DIR:-cache/data};
#   unavailable results are never cached.
# Returns: JSON (analysis fields + symbol, source:"news", provider) or the
#   standard unavailable record.
# ----------------------------------------------------------------------------
news_sentiment() {
    local symbol="$1"
    [[ "$symbol" =~ ^[A-Za-z0-9.-]{1,10}$ ]] || { _sentiment_unavailable "$symbol" "news" "invalid symbol"; return 0; }
    local cache_dir="${SENTIMENT_CACHE_DIR:-cache/data}"
    local cache_file="${cache_dir}/${symbol}_news_sentiment.json"
    if [[ -f "$cache_file" ]]; then
        local file_age=$(( $(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || stat -c%Y "$cache_file" 2>/dev/null || echo 0) ))
        if (( file_age < 30 * 60 )) && jq -e '.status == "ok"' "$cache_file" >/dev/null 2>&1; then
            cat "$cache_file"
            return 0
        fi
    fi

    local fetched articles provider
    if ! fetched=$(fetch_news_articles "$symbol"); then
        _sentiment_unavailable "$symbol" "news" "no news source available"
        return 0
    fi
    articles=$(echo "$fetched" | sed -n 1p)
    provider=$(echo "$fetched" | sed -n 2p)

    local analysis out
    analysis=$(analyze_news_sentiment "$articles")
    out=$(echo "$analysis" | jq -c --arg symbol "$symbol" --arg provider "$provider" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {symbol:$symbol, source:"news", provider:$provider, timestamp:$ts}' 2>/dev/null)
    if [[ -z "$out" ]] || ! echo "$out" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        _sentiment_unavailable "$symbol" "news" "no articles analyzed"
        return 0
    fi
    mkdir -p "$cache_dir" 2>/dev/null && echo "$out" > "$cache_file" 2>/dev/null
    echo "$out"
}

# ============================================================================
# Aggregate All Sentiment Sources
# ============================================================================
# Args: stock_symbol
# Returns: JSON {symbol, aggregate_sentiment_score (int|null), sentiment_label,
#   confidence, available, sources:{twitter,reddit,stocktwits,news}, timestamp}
#   Only non-null source scores are averaged. With none available the score
#   is null, label "unavailable", confidence 0.
aggregate_sentiment() {
    local symbol=$1
    local twitter reddit stocktwits news
    twitter=$(parse_twitter_sentiment "$symbol")
    reddit=$(parse_reddit_sentiment "$symbol")
    stocktwits=$(parse_stocktwits_sentiment "$symbol")
    news=$(news_sentiment "$symbol")

    jq -cn --arg symbol "$symbol" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson tw "$twitter" --argjson rd "$reddit" --argjson st "$stocktwits" --argjson nw "$news" '
        def score(x): (x.sentiment_score // null) | if type == "number" then . else null end;
        {twitter: score($tw), reddit: score($rd), stocktwits: score($st), news: score($nw)} as $src
        | [$src[] | select(. != null)] as $vals
        | (if ($vals | length) > 0 then (($vals | add) / ($vals | length) | floor) else null end) as $agg
        | {
            symbol: $symbol,
            aggregate_sentiment_score: $agg,
            sentiment_label: (if $agg == null then "unavailable"
                              elif $agg >= 65 then "very_bullish"
                              elif $agg >= 55 then "bullish"
                              elif $agg <= 35 then "very_bearish"
                              elif $agg <= 45 then "bearish"
                              else "neutral" end),
            confidence: (if $agg == null then 0
                         else ([90, 30 + 6 * ($nw.articles_analyzed // 0)] | min) end),
            available: ($agg != null),
            sources: $src,
            timestamp: $ts
          }'
}

# ============================================================================
# Convert Sentiment Score to 0-100 Confidence
# ============================================================================
# Args: sentiment_score (0-100, where 0=bearish, 100=bullish)
# Returns: confidence_score (0-100), or "null" when the input is empty/null
sentiment_to_confidence() {
    local sentiment_score=$1

    if [[ -z "$sentiment_score" || "$sentiment_score" == "null" ]]; then
        echo "null"
        return 0
    fi

    local confidence=$((sentiment_score))

    if ((confidence > 100)); then confidence=100; fi
    if ((confidence < 0)); then confidence=0; fi

    echo "$confidence"
}

# Export all functions
export -f parse_twitter_sentiment parse_reddit_sentiment analyze_news_sentiment
export -f parse_stocktwits_sentiment aggregate_sentiment sentiment_to_confidence
export -f _sentiment_unavailable _sentiment_key_configured fetch_news_articles news_sentiment
