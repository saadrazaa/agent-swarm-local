---
name: binance-trading
description: Read-only markets & portfolio intelligence via the official Binance CLI (@binance/binance-cli). Use this whenever a task touches Binance markets OR a Binance account — across EVERY asset class Binance lists, not just crypto — spot, USDⓈ-M / COIN-M perpetuals, options, and TradFi perps on US/KR/HK equities, ETFs, commodities (gold, oil, copper…), crypto indices, and pre-IPO "prediction" perps (OPENAI, ANTHROPIC). Trigger it for a price / % change / volume / order book; funding rate, open interest, long/short ratio, basis, or options implied-vol; a symbol like BTCUSDT / AAPLUSDT / XAUUSDT / OPENAIUSDT; reading account state — spot balances, futures positions, margin, earn/staking, PnL, leverage, liquidation risk; building a consolidated portfolio / NAV view; or any market or portfolio ANALYSIS to support allocation decisions. Trigger it even when the user doesn't say "binance" explicitly but clearly wants to price, monitor, or analyze a market or a Binance portfolio. READ-ONLY by design — placing/canceling orders, margin, leverage changes, transfers, and withdrawals are out of scope and fail server-side.
---

# Binance markets & portfolio intelligence (read-only, via the official `binance-cli`)

This skill drives the **official** Binance command-line tool — `@binance/binance-cli`
(`github.com/binance/binance-cli`, MIT) — using only its **read** surface. It answers two
kinds of question for a markets professional:

1. **What is the market doing?** — prices, funding, open interest, positioning, basis, and
   options vol across crypto, TradFi (equities/ETFs/commodities/indices), pre-IPO perps, and options.
2. **What do I own and what is my risk?** — a consolidated view of spot, futures, margin, and
   earn positions with PnL, leverage, liquidation distance, and exposure by asset class.

The goal is decision support: give a portfolio manager the market read and the portfolio read
they need to reason about **allocation**. Everything is one binary:
`binance-cli <product> <command> [--flags]`.

## Read-only by design — the one thing that matters

The active profile (`ro`) uses an **Ed25519 API key with the "Reading" permission**, IP-restricted.
The safety model is enforced by Binance, not by prompt discipline: placing/canceling orders,
changing margin or leverage, transfers, and withdrawals **fail server-side** (`...invalid API-key,
IP, or permissions...`) even if attempted. Never try to place, test, or simulate an order, transfer,
or any state change. If a user asks to trade, tell them this skill is read-only and stop.

**What "read-only" does *not* mean:** it does not mean "spot only." The key reads the *whole
account* — futures positions, margin, earn, income history, and a cross-product NAV rollup are all
available. See `references/portfolio.md` for the full readable surface. (A note for anyone who read
an older version of this skill: futures/margin position reads DO work — `enableReading` gates reads;
the `enableFutures`/`enableMargin` flags on `get-api-key-permission` are *trading* scopes and being
`false` does not block reads.)

## 1. Setup check (once per session)

```bash
export PATH="$(npm config get prefix)/bin:$PATH"   # if binance-cli isn't found
binance-cli --version          # confirm installed (npm install -g @binance/binance-cli)
binance-cli profile view       # local: expect ro (prod). In the swarm there is no profile —
                               # auth comes from BINANCE_API_KEY / BINANCE_SECRET_KEY env; if
                               # `binance-cli wallet get-api-key-permission` returns your key,
                               # you're authed. Either way it's read-only.
```
Auth (the read-only Ed25519 profile *or* env-var auth) and key security: **read
`references/setup-auth.md`**.

## 2. The two headline workflows

Most requests are a variant of one of these. Lead with the numbers, then the interpretation — a PM
wants the read and the "so what," not raw JSON.

### A. Market Brief — "what's the market doing today?"

A cross-asset positioning-aware snapshot. Use the bundled script, then layer analytics:
```bash
bash scripts/market-brief.sh BTCUSDT ETHUSDT SOLUSDT      # price, 24h%, funding, OI, top-trader L/S
bash scripts/market-brief.sh AAPLUSDT NVDAUSDT XAUUSDT CLUSDT OPENAIUSDT   # any asset class
```
For depth on any line, pull the specific analytic (basis, OI trend, options IV/skew, term structure)
from `references/market-data.md`, and check `references/analysis.md` for how to read them together.
**Interpret, don't dump:** funding = crowd positioning skew; OI = notional at risk / conviction;
top-trader long% vs price = smart-money divergence; basis = carry & stress. For TradFi perps, note
the session state (`trading-schedule`) — funding/basis are only meaningful when the underlying market
is open.

### B. Portfolio Brief — "what do I hold and what's my risk?"

A consolidated cross-product view with risk metrics. Use the bundled script:
```bash
bash scripts/portfolio.sh          # NAV rollup + futures positions w/ risk + spot holdings + margin/earn
```
It joins `wallet query-user-wallet-balance` (per-wallet NAV), `futures-usds` account + positions
(entry/mark/uPnL/leverage/liquidation distance), spot balances valued at live prices, and margin/earn
accounts. Then reason about it for the PM: net & gross exposure, exposure **by asset class**
(crypto vs equity vs commodity vs pre-IPO), concentration, the pain trade, margin headroom, and
distance to liquidation. `references/analysis.md` has the exposure/risk/allocation recipes;
`references/portfolio.md` documents every readable account surface and what each field means.

## 3. Pick the right area (routing)

| The task is about… | Go to |
|---|---|
| Prices, funding, OI, long/short, basis, klines, options IV/greeks, market analytics | `references/market-data.md` |
| The instrument universe — crypto, TradFi stocks/ETFs/commodities/indices, KR/HK, pre-IPO "prediction" perps, options, Alpha | `references/asset-classes.md` |
| Reading the portfolio — spot, futures positions, margin, earn/staking, income, NAV rollup | `references/portfolio.md` |
| Analysis recipes for a PM — exposure by class, portfolio risk, funding carry, positioning, allocation | `references/analysis.md` |
| Install, the read-only profile, key security, the `--symbols` bug, raw passthrough | `references/setup-auth.md` |
| Anything not wrapped, or you need the authoritative spec | `references/official-resources.md` |

Scripts live in `scripts/` (paths above are relative to this skill directory):
`market-brief.sh` (positioning snapshot), `market-snapshot.sh` (plain price table),
`portfolio.sh` (consolidated portfolio + risk).

## 4. When you need more than the skill knows

The CLI mirrors the REST API 1:1 and self-documents:
- `binance-cli <product> --help` and `binance-cli <product> <command> --help` — exact flags.
- The repo's `examples/<product>.md` files map every endpoint to a ready command.
- Raw passthrough for anything unwrapped (**read-only** use only):
  `binance-cli request GET <url> [--param v] [--signed]`.
- For enums/limits/weights/errors, consult the official docs — see `references/official-resources.md`.

Do not invent flags or symbols — verify with `--help`, `exchange-info(rmation)`, or the docs.
