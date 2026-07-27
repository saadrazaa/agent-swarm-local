# Market data & analytics commands

All market-data endpoints are **public — no API key needed**. Symbols are uppercase (`BTCUSDT`,
`AAPLUSDT`, `XAUUSDT`, `OPENAIUSDT`). The **same commands work across every asset class** — a crypto
perp, a US-equity perp, a commodity perp, and a pre-IPO perp all respond to `mark-price`,
`ticker24hr-price-change-statistics`, `open-interest`, etc. For the instrument universe and how to
discover symbols, see `references/asset-classes.md`. For how to *interpret* these together, see
`references/analysis.md`. For multiple symbols use a loop or raw passthrough, not the `--symbols`
flag (see the `--symbols` bug in `setup-auth.md`).

## Spot (host: api.binance.com)

```bash
binance-cli spot ticker-price        --symbol BTCUSDT              # latest price
binance-cli spot ticker-book-ticker  --symbol BTCUSDT              # best bid/ask + sizes
binance-cli spot ticker24hr          --symbol ETHUSDT --type FULL  # + priceChange, priceChangePercent, weightedAvgPrice
binance-cli spot ticker              --symbol BTCUSDT --window-size 1d   # rolling-window stats (1m..7d)
binance-cli spot avg-price           --symbol BTCUSDT              # current 5-min average
binance-cli spot depth               --symbol BTCUSDT --limit 20   # order book
binance-cli spot klines              --symbol BTCUSDT --interval 1h --limit 100   # candlesticks
binance-cli spot agg-trades          --symbol BTCUSDT --limit 20
binance-cli spot exchange-info       --symbol BTCUSDT              # filters: tick size, step size, minNotional
```
`--type FULL` adds `priceChange`, `priceChangePercent`, `weightedAvgPrice`, bid/ask — use it when the
user wants **% change**.

## USDⓈ-M Futures (host: fapi.binance.com) — the richest surface

Price / reference:
```bash
binance-cli futures-usds symbol-price-ticker                 --symbol BTCUSDT   # perp last price
binance-cli futures-usds mark-price                          --symbol BTCUSDT   # markPrice, indexPrice, lastFundingRate, nextFundingTime
binance-cli futures-usds ticker24hr-price-change-statistics  --symbol BTCUSDT   # 24h %change, volume, quoteVolume, high/low
binance-cli futures-usds order-book                          --symbol BTCUSDT --limit 20
binance-cli futures-usds kline-candlestick-data              --symbol BTCUSDT --interval 1h --limit 100
# also: index-price-kline-candlestick-data, mark-price-kline-candlestick-data,
#       premium-index-kline-data, continuous-contract-kline-candlestick-data
```
Positioning / analytics (all public — the meat for a market read):
```bash
binance-cli futures-usds get-funding-rate-history            --symbol BTCUSDT --limit 30   # funding series
binance-cli futures-usds get-funding-rate-info                                             # caps/floors/interval per symbol
binance-cli futures-usds open-interest                       --symbol BTCUSDT              # current OI (base units)
binance-cli futures-usds open-interest-statistics            --symbol BTCUSDT --period 1h  # OI trend + USD value
binance-cli futures-usds long-short-ratio                    --symbol BTCUSDT --period 1h
binance-cli futures-usds top-trader-long-short-ratio-positions --symbol BTCUSDT --period 1h  # smart-money skew
binance-cli futures-usds top-trader-long-short-ratio-accounts  --symbol BTCUSDT --period 1h
binance-cli futures-usds taker-buy-sell-volume               --symbol BTCUSDT --period 1h  # aggressive flow imbalance
binance-cli futures-usds basis --pair BTCUSDT --contract-type PERPETUAL --period 1h        # perp vs index (carry/stress)
binance-cli futures-usds composite-index-symbol-information   --symbol BTCDOMUSDT          # index basket weights (INDEX symbols only)
binance-cli futures-usds adl-risk                            --symbol BTCUSDT              # LOW/MEDIUM/HIGH ADL rating
binance-cli futures-usds trading-schedule                                                  # TradFi session state (see asset-classes.md)
```
COIN-M is parallel under `futures-coin`, crypto-only, with slightly different names
(`index-price-and-mark-price`, `get-funding-rate-history-of-perpetual-futures`).

## Options (host: eapi.binance.com) — forward-looking, crypto only

Underlyings listed today: BTC, ETH, SOL, BNB, XRP, DOGE (European, cash-settled, USDT-quoted). Symbol
format `BTC-260925-145000-C` = underlying-expiry-strike-side.
```bash
binance-cli derivatives-options exchange-information                                    # all optionSymbols: strike/side/expiry/margins
binance-cli derivatives-options index-price       --underlying BTCUSDT                  # spot index for the underlying
binance-cli derivatives-options option-mark-price  --symbol BTC-260925-145000-C         # markPrice + full greeks: markIV, delta, gamma, theta, vega
binance-cli derivatives-options open-interest      --underlying-asset BTC --expiration 260925   # OI per strike + USD
binance-cli derivatives-options ticker24hr-price-change-statistics
binance-cli derivatives-options order-book         --symbol <sym> --limit 100           # --limit must be 10/100/500/1000
binance-cli derivatives-options kline-candlestick-data --symbol <sym> --interval 1h
binance-cli derivatives-options historical-exercise-records --underlying BTCUSDT        # past expiries: exercised vs OTM
```

## klines / candlestick output shape

Each candle is an **array**, not an object:
```
[ openTime, open, high, low, close, volume, closeTime,
  quoteAssetVolume, numberOfTrades, takerBuyBaseVolume, takerBuyQuoteVolume, ignore ]
```
Index 1=open, 2=high, 3=low, 4=close, 5=base volume, 7=quote volume.

## Quick multi-symbol tables (bundled scripts)

```bash
bash scripts/market-snapshot.sh spot    BTCUSDT ETHUSDT SOLUSDT   # price, 24h%, high, low, quote-vol
bash scripts/market-snapshot.sh futures BTCUSDT AAPLUSDT XAUUSDT
bash scripts/market-brief.sh BTCUSDT ETHUSDT OPENAIUSDT           # + funding, OI, top-trader long% (positioning)
```

## Live streaming

For real-time updates instead of polling, use the WebSocket stream groups: `spot-streams`,
`futures-usds-streams`, `futures-coin-streams`, `derivatives-options-streams`. Run
`binance-cli <group>-streams --help` for available streams (trades, klines, bookTicker, markPrice,
depth). Analytics recipes (positioning, exposure, risk, carry) live in `references/analysis.md`.
