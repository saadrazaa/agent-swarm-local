# The instrument universe — every market Binance lists

This skill is **not crypto-only**. Binance lists five broad tradable universes, all priceable with
the same read commands. Know what exists before you analyze it.

## The map (verified counts, USDⓈ-M futures `exchange-information`, 2026-07)

`binance-cli futures-usds exchange-information` returns ~846 symbols. Every symbol has an
`underlyingType` and `contractType`; the non-crypto perps carry `contractType: TRADIFI_PERPETUAL`.

| underlyingType | contractType | ~Count | What it is / examples |
|---|---|---|---|
| `COIN` | PERPETUAL / CURRENT_QUARTER / NEXT_QUARTER | ~699 | Crypto perps & quarterlies — BTC, ETH, SOL, XRP, … |
| `EQUITY` | TRADIFI_PERPETUAL | ~125 | **US stocks & ETFs** — AAPL, MSFT, NVDA, TSLA, AMZN, GOOGL, META, MU, SNDK, COIN, MSTR, HOOD, PLTR; ETFs SPY, QQQ, IWM, SOXL/SOXS, TQQQ/SQQQ, UVXY … |
| `COMMODITY` | TRADIFI_PERPETUAL | ~8 | Gold **XAU**, silver XAG, platinum XPT, palladium XPD, copper COPPER, WTI **CL**, Brent BZ, natural gas NATGAS |
| `KR_EQUITY` | TRADIFI_PERPETUAL | ~3 | Korean equities — SKHYNIX, SAMSUNG, HYUNDAI |
| `HK_EQUITY` | TRADIFI_PERPETUAL | ~6 | Hong Kong equities — HK0700 (Tencent), HK1810 (Xiaomi), POPMART, ZHIPU, MINIMAX |
| `INDEX` | PERPETUAL | ~3 | Crypto indices — BTCDOM (BTC dominance), DEFI, ALL |
| `PREMARKET` | TRADIFI_PERPETUAL | 2 | **Pre-IPO "prediction" perps** — OPENAI, ANTHROPIC |

All TradFi perps are quoted `...USDT` (e.g. `AAPLUSDT`, `XAUUSDT`, `SKHYNIXUSDT`, `OPENAIUSDT`) and
priced with the **same commands as any crypto perp** (`mark-price`, `symbol-price-ticker`,
`ticker24hr-price-change-statistics`, `open-interest`, `order-book`, `kline-candlestick-data`).

COIN-M futures (`futures-coin`) is **100% crypto** — no TradFi symbols there.

### Discovering / filtering the universe

`exchange-information` is large — parse with `node`/`jq`. Example: list every non-crypto instrument
grouped by class:
```bash
binance-cli futures-usds exchange-information | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s), g={};
  for(const x of j.symbols){const t=x.underlyingType||"?"; if(t==="COIN")continue;(g[t]=g[t]||[]).push(x.baseAsset);}
  for(const[t,a]of Object.entries(g))console.log(t,"("+a.length+"):",[...new Set(a)].sort().join(", "));
});'
```
Each symbol also has `status` (`TRADING`/`PENDING_TRADING`/`SETTLING`), `baseAsset`, `quoteAsset`.

## TradFi perps: the session-state gotcha

A TradFi perp only tracks its underlying while that market is **open**. Outside hours it drifts on
its own order book and **funding is pinned near zero** — so a "0% funding" or a stale basis on
`AAPLUSDT` at 3am doesn't mean what it would on `BTCUSDT`. Always check the session before reading
too much into a TradFi funding/basis number:
```bash
binance-cli futures-usds trading-schedule    # PRE_MARKET / REGULAR / AFTER_MARKET / OVERNIGHT / NO_TRADING per market
```
It returns the calendar per market group (EQUITY, COMMODITY, KR_EQUITY, HK_EQUITY). For a US-equity
perp, only `REGULAR` (and to a lesser degree pre/after-market) reflects live price discovery.

## "Predictions" on Binance — what it actually is

**There is no native prediction-market / event-contract product** (no Polymarket/Kalshi-style yes/no
outcomes) anywhere in this CLI. The two real analogues:

### 1. Pre-IPO / PREMARKET perps — the de-facto prediction market
`OPENAIUSDT` and `ANTHROPICUSDT` are `underlyingType: PREMARKET`, `underlyingSubType:
["Pre-IPO","TradFi"]` — leveraged, funding-anchored bets on a **private company's valuation** ahead
of any IPO. There are **no real shares**: `markPrice ≈ indexPrice` is a synthetic per-unit valuation
proxy that Binance constructs (so `query-index-price-constituents` returns "Invalid symbol" — the
index is internal). Mechanics: USDT-margined, `maintMarginPercent 2.5%`, `requiredMarginPercent 5%`
(~20x max), 8h funding capped at ±2%. Funding is the tether to the constructed valuation.
```bash
binance-cli futures-usds mark-price          --symbol OPENAIUSDT   # markPrice/indexPrice/lastFundingRate
binance-cli futures-usds symbol-price-ticker --symbol ANTHROPICUSDT
binance-cli futures-usds open-interest       --symbol OPENAIUSDT   # crowding into the "bet"
binance-cli futures-usds get-funding-rate-history --symbol OPENAIUSDT --limit 30
```
Read a rising mark + rising OI + persistently positive funding as the market pricing a higher private
valuation with crowded long conviction — and treat these as thin, high-margin, event-driven exposure.

### 2. Options — forward-looking, crypto-only
See `references/market-data.md` (options section) — full greeks/IV, but underlyings are BTC/ETH/SOL/
BNB/XRP/DOGE only. No equity or event options are listed today.

When a user says "predictions," clarify which they mean, and default to the pre-IPO perps unless they
say otherwise.

## Binance Alpha — early-stage discovery (frontier, not a market to size into)

`alpha` surfaces ~656 on-chain / pre-listing tokens (BSC, Ethereum, …) — a **pre-listing screener**,
not a deep market. Useful to spot what's coming to a CEX; not sizable exposure (illiquid micro-caps).
```bash
binance-cli alpha token-list        # per token: symbol, alphaId (ALPHA_<n>), chain, price, marketCap,
                                     # fdv, liquidity, holders, listingCex, onlineTge, onlineAirdrop, score
binance-cli alpha ticker --symbol ALPHA_175USDT     # use the alphaId, not the ticker symbol
binance-cli alpha klines --symbol ALPHA_1011 --interval 1h
```
Screen by FDV / liquidity / holders / TGE flags to flag candidates; verify liquidity before treating
any as investable.
