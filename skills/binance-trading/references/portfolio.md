# Reading the portfolio (read-only, whole-account)

The `ro` key's **Reading** permission reads the *entire* account, not just spot. This was verified
empirically across products (2026-07): spot, USDⓈ-M futures (incl. open positions), COIN-M futures,
cross & isolated margin, earn/staking/dual-investment, crypto-loan, convert history, and a
cross-product NAV rollup are all queryable. Only two things are out of reach, and neither is a
key-scope limit:

- **Portfolio Margin** (`derivatives-portfolio-margin`) → `Invalid API-key, IP, or permissions`.
  This tracks the *account's* `isPortfolioMarginRetailEnabled: false` (never enrolled), not the key.
  If the account enrolls, the same key should read it.
- **Sub-accounts** → `Sub-account function is not enabled` (none provisioned).

> Why the confusion: `wallet get-api-key-permission` shows `enableFutures/enableMargin: false`. Those
> are **trading** scopes. `enableReading: true` is what gates the reads. The authoritative
> *account-capability* flags are in `wallet account-info` (`isFutureEnabled`, `isMarginEnabled`,
> `isPortfolioMarginRetailEnabled`, …).

Fastest way to build the consolidated view: run `scripts/portfolio.sh`. This reference documents the
underlying commands and field meanings so you can go deeper or explain a number.

## Top-level NAV rollup (one call)

```bash
binance-cli wallet query-user-wallet-balance     # per-wallet balance in BTC, across ALL products
```
Returns `[{walletName, balance, activate}]` for Spot, Funding, Cross Margin, Isolated Margin,
USDⓈ-M Futures, COIN-M Futures, Earn, Options, Trading Bots, Copy Trading. `balance` is BTC-valued —
multiply by the BTC price (`spot ticker-price --symbol BTCUSDT`) for USD. This is the single best
"where is my money" anchor; drill into each non-zero wallet below.

## Spot & wallet

```bash
binance-cli spot get-account --omit-zero-balances true   # balances[]{asset,free,locked} + commissions + canTrade
binance-cli wallet user-asset                            # non-zero spot balances + btcValuation per asset
binance-cli wallet funding-wallet                        # Funding-wallet balances (separate from Spot)
binance-cli wallet daily-account-snapshot --type SPOT    # daily totalAssetOfBtc history (track NAV over time)
binance-cli wallet asset-dividend-record                 # airdrops / distributions received
binance-cli wallet dustlog                               # small-balance conversions
binance-cli wallet deposit-history / withdraw-history    # cash flows (read-only history)
binance-cli spot my-trades   --symbol BTCUSDT --limit 20 # your fills (needs --symbol)
binance-cli spot all-orders  --symbol BTCUSDT --limit 20 # order history (needs --symbol)
```

## USDⓈ-M futures (positions, PnL, risk) — the core of the book

```bash
binance-cli futures-usds account-information-v3    # totals: walletBalance, marginBalance, unrealizedProfit,
                                                   # availableBalance, maintMargin, initialMargin, assets[]
binance-cli futures-usds position-information-v3   # OPEN positions only: symbol, positionAmt, entryPrice,
                                                   # markPrice, unRealizedProfit, liquidationPrice, notional,
                                                   # initialMargin, maintMargin, adl
binance-cli futures-usds futures-account-balance-v3        # per-asset balance / crossUnPnl / availableBalance
binance-cli futures-usds get-current-position-mode         # one-way vs hedge
binance-cli futures-usds futures-account-configuration     # feeTier, multiAssetsMargin, dualSidePosition
binance-cli futures-usds notional-and-leverage-brackets    # per-symbol max leverage & maint-margin tiers
binance-cli futures-usds position-adl-quantile-estimation  # ADL queue risk per open position
binance-cli futures-usds get-income-history --limit 50     # realized flows: FUNDING_FEE, COMMISSION, REALIZED_PNL
```
**Derived risk metrics** (compute locally — see `references/analysis.md`):
- side = `positionAmt` > 0 → LONG, < 0 → SHORT.
- position leverage ≈ `|notional| / initialMargin`.
- distance to liquidation = `|markPrice − liquidationPrice| / markPrice` (bigger = safer).
- account margin ratio = `totalMaintMargin / totalMarginBalance` (rising toward 1 = danger).
- funding cost run-rate: sum `FUNDING_FEE` from `get-income-history` over a window.

## COIN-M futures

Same shape under `futures-coin`: `account-information`, `position-information`,
`futures-account-balance`, `get-income-history`. Commands work even when empty (returns zeros).

## Margin (cross & isolated)

```bash
binance-cli margin-trading query-cross-margin-account-details   # marginLevel, totalAssetOfBtc, totalLiabilityOfBtc, userAssets[]
binance-cli margin-trading query-isolated-margin-account-info   # per-pair: borrowed/free/netAsset, marginLevel, liquidatePrice
binance-cli margin-trading get-interest-history                 # borrow interest paid (a cost of carry)
binance-cli margin-trading get-summary-of-margin-account        # normalBar / marginCallBar / forceLiquidationBar thresholds
binance-cli margin-trading query-max-borrow --asset USDT        # available borrow headroom
```
`marginLevel` falling toward the `marginCallBar`/`forceLiquidationBar` is the risk signal.

## Earn, staking, structured products (yield sleeve)

All read fine; return empty when there are no holdings.
```bash
binance-cli simple-earn simple-account                     # total earn value (BTC & USDT)
binance-cli simple-earn get-flexible-product-position      # flexible positions
binance-cli simple-earn get-locked-product-position        # locked positions
binance-cli staking eth-staking-account / sol-staking-account / on-chain-yields-account
binance-cli dual-investment get-dual-investment-positions  # structured yield positions
binance-cli crypto-loan get-flexible-loan-ongoing-orders   # outstanding borrows (a liability)
```

## Convert history

```bash
binance-cli convert get-convert-trade-history --start-time <ms> --end-time <ms>   # 30-day window required
```

## Trading Bots & Copy Trading — mostly closed to a read key

Both appear as wallets in `query-user-wallet-balance`, but their detail endpoints are largely
unavailable to the read-only key:
- **Trading Bots** map to the `algo` group (TWAP/VP execution algos). Even the *query* commands
  (`algo query-current-algo-open-orders-*`, `algo query-historical-algo-orders-*`) return
  **"You are not authorized to execute this request"** — the algo API requires trading authorization
  to query, so there is no bot data to read here. The wallet BTC balance in the NAV rollup is the
  only visible figure.
- **Copy Trading** exposes only `copy-trading get-futures-lead-trader-status` (→ `isLeadTrader`) and
  `get-futures-lead-trading-symbol-whitelist` (reference data). There is **no follower-portfolio /
  copied-positions read endpoint** in the CLI. Again, the NAV-rollup balance is all you get.

So for these two, report the wallet's NAV value and note that position-level detail isn't readable
with this key — don't burn calls retrying the blocked endpoints.

## Putting it together

A complete book = NAV rollup (where the money is) + spot holdings (valued) + futures positions (with
risk metrics) + margin (leverage/liability) + earn/loan (yield & liabilities). `scripts/portfolio.sh`
assembles this; `references/analysis.md` turns it into exposure-by-class, concentration, and risk
readouts a PM can act on.
