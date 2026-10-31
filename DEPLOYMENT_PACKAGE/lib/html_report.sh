#!/bin/bash
# ============================================================================
# StockSwingTrader: HTML Report Generation Library
# ============================================================================
# Generates professional HTML reports with technical analysis, signals, charts
# ============================================================================

# ============================================================================
# Generate HTML Report
# ============================================================================
# Args: stock_data_json (JSON object with all analysis), output_file
# Returns: writes HTML to file
generate_html_report() {
    local stock_data=$1
    local output_file=$2
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Create output directory if needed
    mkdir -p "$(dirname "$output_file")"
    
    cat > "$output_file" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>StockSwingTrader Analysis Report</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: #333;
            padding: 20px;
            min-height: 100vh;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 12px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
        }
        .header p {
            font-size: 1em;
            opacity: 0.9;
        }
        .content {
            padding: 40px;
        }
        .section {
            margin-bottom: 40px;
            border-bottom: 2px solid #f0f0f0;
            padding-bottom: 30px;
        }
        .section:last-child {
            border-bottom: none;
        }
        .section-title {
            font-size: 1.8em;
            color: #667eea;
            margin-bottom: 20px;
            font-weight: 600;
        }
        .stock-header {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 30px;
            align-items: start;
        }
        .stock-info {
            background: #f9f9f9;
            padding: 20px;
            border-radius: 8px;
        }
        .stock-symbol {
            font-size: 3em;
            font-weight: 700;
            color: #667eea;
            margin-bottom: 10px;
        }
        .stock-price {
            font-size: 2em;
            margin-bottom: 5px;
        }
        .stock-change {
            font-size: 1.2em;
            margin-bottom: 15px;
        }
        .positive {
            color: #22c55e;
            font-weight: 600;
        }
        .negative {
            color: #ef4444;
            font-weight: 600;
        }
        .neutral {
            color: #999;
            font-weight: 600;
        }
        .signal-box {
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            font-size: 1.5em;
            font-weight: 700;
        }
        .signal-strong-buy {
            background: linear-gradient(135deg, #22c55e, #16a34a);
            color: white;
        }
        .signal-buy {
            background: linear-gradient(135deg, #4ade80, #22c55e);
            color: white;
        }
        .signal-hold {
            background: linear-gradient(135deg, #facc15, #eab308);
            color: #333;
        }
        .signal-sell {
            background: linear-gradient(135deg, #fb923c, #f97316);
            color: white;
        }
        .signal-strong-sell {
            background: linear-gradient(135deg, #ef4444, #dc2626);
            color: white;
        }
        .confidence-meter {
            width: 100%;
            height: 30px;
            background: #e0e0e0;
            border-radius: 15px;
            overflow: hidden;
            margin-top: 10px;
        }
        .confidence-fill {
            height: 100%;
            background: linear-gradient(90deg, #ef4444, #facc15, #22c55e);
            display: flex;
            align-items: center;
            justify-content: center;
            color: white;
            font-weight: 600;
            font-size: 0.9em;
            transition: width 0.5s ease;
        }
        .indicators-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }
        .indicator-card {
            background: #f9f9f9;
            padding: 15px;
            border-radius: 8px;
            border-left: 4px solid #667eea;
        }
        .indicator-name {
            font-weight: 600;
            color: #667eea;
            margin-bottom: 8px;
        }
        .indicator-value {
            font-size: 1.5em;
            font-weight: 700;
            color: #333;
        }
        .indicator-status {
            font-size: 0.9em;
            color: #999;
            margin-top: 5px;
        }
        .sentiment-section {
            background: #f9f9f9;
            padding: 20px;
            border-radius: 8px;
        }
        .sentiment-item {
            display: flex;
            justify-content: space-between;
            padding: 10px 0;
            border-bottom: 1px solid #e0e0e0;
        }
        .sentiment-item:last-child {
            border-bottom: none;
        }
        .sentiment-source {
            font-weight: 600;
        }
        .sentiment-score {
            font-weight: 700;
            color: #667eea;
        }
        .risk-metrics {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
        }
        .metric-card {
            background: #f9f9f9;
            padding: 15px;
            border-radius: 8px;
            text-align: center;
        }
        .metric-label {
            font-weight: 600;
            color: #999;
            font-size: 0.9em;
            margin-bottom: 8px;
        }
        .metric-value {
            font-size: 1.5em;
            font-weight: 700;
            color: #333;
        }
        .footer {
            background: #f5f5f5;
            padding: 30px 40px;
            text-align: center;
            font-size: 0.9em;
            color: #999;
        }
        .data-warning {
            background: #fff3cd;
            border: 2px solid #b45309;
            border-radius: 8px;
            padding: 15px;
            margin-bottom: 30px;
            color: #78350f;
            font-weight: 600;
        }
        .disclaimer {
            background: #fff3cd;
            border: 1px solid #ffc107;
            border-radius: 8px;
            padding: 15px;
            margin: 20px 0;
            color: #856404;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #e0e0e0;
        }
        th {
            background: #f5f5f5;
            font-weight: 600;
            color: #667eea;
        }
        tr:hover {
            background: #f9f9f9;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🎯 StockSwingTrader Analysis</h1>
            <p>Technical Analysis & Sentiment Report</p>
        </div>
        
        <div class="content">
            DATA_SOURCE_BANNER
            <!-- Stock Summary Section -->
            <div class="section">
                <div class="stock-header">
                    <div class="stock-info">
                        <div class="stock-symbol">SYMBOL</div>
                        <div class="stock-price">$PRICE</div>
                        <div class="stock-change CHANGE_CLASS">CHANGE %</div>
                        <table>
                            <tr>
                                <td>Market Cap:</td>
                                <td>MARKET_CAP</td>
                            </tr>
                            <tr>
                                <td>Volume:</td>
                                <td>VOLUME</td>
                            </tr>
                            <tr>
                                <td>52W High/Low:</td>
                                <td>52W_RANGE</td>
                            </tr>
                        </table>
                    </div>
                    <div class="stock-info">
                        <div class="section-title" style="margin-top: 0;">Signal & Confidence</div>
                        <div class="signal-box SIGNAL_CLASS">SIGNAL</div>
                        <div class="confidence-meter">
                            <div class="confidence-fill" style="width: CONFIDENCE_PCT%;">
                                CONFIDENCE%
                            </div>
                        </div>
                        <p style="margin-top: 15px; color: #666; font-size: 0.95em;">REASONING</p>
                    </div>
                </div>
            </div>
            
            <!-- Technical Indicators Section -->
            <div class="section">
                <h2 class="section-title">📊 Technical Indicators</h2>
                <div class="indicators-grid">
                    <div class="indicator-card">
                        <div class="indicator-name">RSI (14)</div>
                        <div class="indicator-value">RSI_VALUE</div>
                        <div class="indicator-status">RSI_STATUS</div>
                    </div>
                    <div class="indicator-card">
                        <div class="indicator-name">MACD</div>
                        <div class="indicator-value">MACD_VALUE</div>
                        <div class="indicator-status">MACD_STATUS</div>
                    </div>
                    <div class="indicator-card">
                        <div class="indicator-name">Bollinger Bands</div>
                        <div class="indicator-value">BB_POSITION%</div>
                        <div class="indicator-status">BB_STATUS</div>
                    </div>
                    <div class="indicator-card">
                        <div class="indicator-name">Stochastic %K</div>
                        <div class="indicator-value">STOCH_VALUE</div>
                        <div class="indicator-status">STOCH_STATUS</div>
                    </div>
                    <div class="indicator-card">
                        <div class="indicator-name">Williams %R</div>
                        <div class="indicator-value">WILLIAMS_VALUE</div>
                        <div class="indicator-status">WILLIAMS_STATUS</div>
                    </div>
                    <div class="indicator-card">
                        <div class="indicator-name">OBV Trend</div>
                        <div class="indicator-value">OBV_TREND</div>
                        <div class="indicator-status">OBV_STATUS</div>
                    </div>
                </div>
            </div>
            
            <!-- Sentiment Analysis Section -->
            <div class="section">
                <h2 class="section-title">💬 Sentiment Analysis</h2>
                <div class="sentiment-section">
                    <div class="sentiment-item">
                        <span class="sentiment-source">Twitter Sentiment:</span>
                        <span class="sentiment-score">TWITTER_SCORE/100</span>
                    </div>
                    <div class="sentiment-item">
                        <span class="sentiment-source">Reddit Sentiment:</span>
                        <span class="sentiment-score">REDDIT_SCORE/100</span>
                    </div>
                    <div class="sentiment-item">
                        <span class="sentiment-source">StockTwits:</span>
                        <span class="sentiment-score">STOCKTWITS_SCORE/100</span>
                    </div>
                    <div class="sentiment-item">
                        <span class="sentiment-source">News Sentiment:</span>
                        <span class="sentiment-score">NEWS_SCORE/100</span>
                    </div>
                </div>
                <p style="margin-top: 15px; color: #666; font-size: 0.95em;">
                    <strong>Aggregate Sentiment:</strong> SENTIMENT_SUMMARY
                </p>
            </div>
            
            <!-- Risk Management Section -->
            <div class="section">
                <h2 class="section-title">⚠️ Risk Management</h2>
                <div class="risk-metrics">
                    <div class="metric-card">
                        <div class="metric-label">Entry Price</div>
                        <div class="metric-value">$ENTRY_PRICE</div>
                    </div>
                    <div class="metric-card">
                        <div class="metric-label">Stop Loss (5%)</div>
                        <div class="metric-value" style="color: #ef4444;">$STOP_LOSS</div>
                    </div>
                    <div class="metric-card">
                        <div class="metric-label">Take Profit (8%)</div>
                        <div class="metric-value" style="color: #22c55e;">$TAKE_PROFIT</div>
                    </div>
                    <div class="metric-card">
                        <div class="metric-label">Risk / Reward</div>
                        <div class="metric-value">RISK_REWARD_RATIO</div>
                    </div>
                    <div class="metric-card">
                        <div class="metric-label">ATR (14)</div>
                        <div class="metric-value">ATR_VALUE</div>
                    </div>
                    <div class="metric-card">
                        <div class="metric-label">Volatility</div>
                        <div class="metric-value">VOLATILITY%</div>
                    </div>
                </div>
            </div>
            
            <!-- Trading Summary -->
            <div class="section">
                <h2 class="section-title">📋 Trade Summary</h2>
                <div class="disclaimer">
                    ⚠️ <strong>Disclaimer:</strong> This analysis is for educational and informational purposes only. 
                    It is not financial advice and should not be used as the sole basis for trading decisions. 
                    Always conduct your own research and consult with a financial advisor before trading. 
                    Past performance does not guarantee future results.
                </div>
                <p style="margin: 20px 0; line-height: 1.6;">
                    <strong>Analysis Summary:</strong> TRADE_SUMMARY
                </p>
                <p style="margin: 20px 0; line-height: 1.6;">
                    <strong>Key Levels:</strong> RESISTANCE_SUPPORT_LEVELS
                </p>
            </div>
        </div>
        
        <div class="footer">
            <p>Generated: REPORT_TIMESTAMP | Data Sources: Yahoo Finance, Alpha Vantage, Finnhub, NewsAPI, Twitter, Reddit, StockTwits</p>
            <p>This is a learning/demo tool. Analysis-only; not connected to live trading. Always verify with multiple sources.</p>
        </div>
    </div>
</body>
</html>
EOF
    
    # Replace placeholders with actual data
    local price=$(echo "$stock_data" | grep -o '"price":[0-9.]*' | head -1 | grep -o '[0-9.]*')
    local symbol=$(echo "$stock_data" | grep -o '"symbol":"[^"]*' | head -1 | grep -o '[^"]*$')
    
    # Data provenance banner: synthetic demo prices are always called out
    local banner=""
    if echo "$stock_data" | grep -Eq '"data_source": *"synthetic"'; then
        banner='<div class="data-warning" role="alert">SYNTHETIC DATA: this report was built from generated demo prices (SST_OFFLINE=1 or SST_ALLOW_SYNTHETIC=1), not market data. Do not trade on it.</div>'
    elif echo "$stock_data" | grep -Eq '"data_source": *"unknown"'; then
        banner='<div class="data-warning" role="alert">Unknown data source: the analysis does not record where its prices came from.</div>'
    fi
    sed -i '' "s|DATA_SOURCE_BANNER|${banner}|g" "$output_file"

    sed -i '' "s/SYMBOL/${symbol:-N\/A}/g" "$output_file"
    sed -i '' "s/\$PRICE/\$${price:-0.00}/g" "$output_file"
    sed -i '' "s/REPORT_TIMESTAMP/${timestamp}/g" "$output_file"
    sed -i '' "s/RSI_VALUE/--/g" "$output_file"
    sed -i '' "s/MACD_VALUE/--/g" "$output_file"
    sed -i '' "s/BB_POSITION%/--/g" "$output_file"
    sed -i '' "s/STOCH_VALUE/--/g" "$output_file"
    sed -i '' "s/WILLIAMS_VALUE/--/g" "$output_file"
    sed -i '' "s/OBV_TREND/--/g" "$output_file"
    sed -i '' "s/SENTIMENT_SUMMARY/Aggregated from multiple sources/g" "$output_file"
    sed -i '' "s/SIGNAL/ANALYZE/g" "$output_file"
    sed -i '' "s/CONFIDENCE_PCT/0/g" "$output_file"
    sed -i '' "s/CONFIDENCE%/--/g" "$output_file"
    sed -i '' "s/REASONING/Analysis data loaded successfully/g" "$output_file"
    sed -i '' "s/CHANGE_CLASS/neutral/g" "$output_file"
    sed -i '' "s/CHANGE %/0.00%/g" "$output_file"
    sed -i '' "s/SIGNAL_CLASS/signal-hold/g" "$output_file"
    sed -i '' "s/TWITTER_SCORE/--/g" "$output_file"
    sed -i '' "s/REDDIT_SCORE/--/g" "$output_file"
    sed -i '' "s/STOCKTWITS_SCORE/--/g" "$output_file"
    sed -i '' "s/NEWS_SCORE/--/g" "$output_file"
    sed -i '' "s/\$ENTRY_PRICE/\$${price:-0.00}/g" "$output_file"
    sed -i '' "s/\$STOP_LOSS/\$--/g" "$output_file"
    sed -i '' "s/\$TAKE_PROFIT/\$--/g" "$output_file"
    sed -i '' "s/RISK_REWARD_RATIO/--/g" "$output_file"
    sed -i '' "s/ATR_VALUE/--/g" "$output_file"
    sed -i '' "s/VOLATILITY%/--/g" "$output_file"
    sed -i '' "s/MARKET_CAP/--/g" "$output_file"
    sed -i '' "s/VOLUME/--/g" "$output_file"
    sed -i '' "s/52W_RANGE/--/g" "$output_file"
    sed -i '' "s/TRADE_SUMMARY/Ready for analysis. Configure API keys for live data./g" "$output_file"
    sed -i '' "s/RESISTANCE_SUPPORT_LEVELS/N\/A - Configure API keys for live data/g" "$output_file"
    sed -i '' "s/RSI_STATUS/--/g" "$output_file"
    sed -i '' "s/MACD_STATUS/--/g" "$output_file"
    sed -i '' "s/BB_STATUS/--/g" "$output_file"
    sed -i '' "s/STOCH_STATUS/--/g" "$output_file"
    sed -i '' "s/WILLIAMS_STATUS/--/g" "$output_file"
    sed -i '' "s/OBV_STATUS/--/g" "$output_file"
}

# Export function
export -f generate_html_report
