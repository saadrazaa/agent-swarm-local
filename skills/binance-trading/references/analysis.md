# Analysis recipes for a portfolio manager

The CLI emits JSON — pipe to `node`/`jq`/`python3` and do plain arithmetic. The point of this file is
not more commands; it's turning raw reads into the handful of numbers a PM actually uses to size and
de-risk positions. Lead outputs with the decision-relevant figure, then the supporting detail.

Two lenses run through everything: **the market read** (is this asset class rich/cheap, crowded,
carrying, stressed?) and **the portfolio read** (what am I exposed to, where's the concentration,
where's the risk, how much dry powder?).

## Market read

### Positioning & sentiment (per symbol or basket)
Combine four public futures signals; divergences are the signal, not any one level:
- **Funding** (`mark-price` → `lastFundingRate`, or `get-funding-rate-history`): positive = longs pay
  shorts = crowded long. Extreme/persistent funding often precedes squeezes.
- **Open interest** (`open-interest`, `open-interest-statistics`): rising OI + rising price =
  conviction; rising OI + falling price = new shorts; falling OI = position unwind.
- **Top-trader long/short** (`top-trader-long-short-ratio-positions --period 1h`): "smart money"
  skew. Compare to price direction for divergence.
- **Basis** (`basis --pair <PAIR> --contract-type PERPETUAL`): perp vs index. Rich (contango) =
  bullish carry demand; backwardation / sharp negative = stress or deleveraging.

`scripts/market-brief.sh` prints price / 24h% / funding / OI / top-trader-long% for any basket in one
table — start there, then pull the specific series for anything that stands out.

### Trend / value on a name
```bash
binance-cli futures-usds kline-candlestick-data --symbol BTCUSDT --interval 1d --limit 30 | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const k=JSON.parse(s), c=k.map(x=>+x[4]);
  const sma=n=>c.slice(-n).reduce((a,b)=>a+b,0)/n;
  console.log("last",c.at(-1).toFixed(2),"| SMA7",sma(7).toFixed(2),"| SMA30",sma(30).toFixed(2),
    "| 30d range",Math.min(...c).toFixed(2),"-",Math.max(...c).toFixed(2));
});'
```
Candle array indices: 1=open 2=high 3=low 4=close 5=baseVol 7=quoteVol.

### Options: implied vol & skew (crypto only)
```bash
binance-cli derivatives-options option-mark-price --symbol BTC-260925-145000-C   # markIV, delta, gamma, theta, vega
binance-cli derivatives-options open-interest --underlying-asset BTC --expiration 260925   # OI by strike (max-pain, walls)
```
Read markIV term structure (near vs far expiry) for event pricing; compare call vs put IV at
equidistant strikes for skew (fear vs greed).

## Portfolio read

Run `scripts/portfolio.sh` first — it computes most of the below. These recipes explain the metrics
and let you go further.

### Exposure by asset class (the allocation view)
Classify each futures position by `underlyingType` (crypto / equity / commodity / index / premarket)
via `exchange-information`, then sum signed and absolute notional per class:
- **Net exposure** per class = Σ signed notional (directional bet).
- **Gross exposure** per class = Σ |notional| (capital at work / risk footprint).
- **Concentration** = largest position notional ÷ gross. Flag single-name > ~30% of gross.
This is the core allocation readout: "X% net long equity via a memory-chip cluster, Y% commodity,
Z% pre-IPO — is that the intended tilt?"

### Portfolio PnL & leverage
From `account-information-v3`:
- unrealized PnL = `totalUnrealizedProfit`; as % of equity = `/ totalMarginBalance`.
- account leverage = `Σ|notional| / totalMarginBalance`.
- **margin ratio** = `totalMaintMargin / totalMarginBalance` — the single most important risk number;
  rising toward 1.0 means approaching liquidation. Dry powder = `availableBalance`.

### Liquidation risk (per position)
distance to liq = `|markPrice − liquidationPrice| / markPrice`. Rank positions by smallest distance;
those are what a market move takes out first. Cross-check `position-adl-quantile-estimation` for
ADL-queue risk on profitable crowded names.

### Cost of carry
Sum `FUNDING_FEE` from `futures-usds get-income-history` over a window for the funding run-rate on the
book; add `margin-trading get-interest-history` for borrow interest. Net these against the position
thesis — a long paying heavy funding needs the move to outrun the carry.

### Allocation-decision checklist
When the PM asks "how should I adjust?", assemble: (1) exposure by class vs intended tilt,
(2) concentration flags, (3) positions nearest liquidation, (4) carry drag vs thesis, (5) market read
per class (rich/cheap, crowded, stressed), (6) dry powder. Present the tensions (e.g. "concentrated
long into rising funding with thin liq cushion on the biggest name") and let the PM decide — this
skill informs allocation, it does not execute it.

## Multi-symbol value join (spot holdings)
Value spot balances at live prices — one `get-account` + one all-prices call, joined locally:
```bash
ACC=$(binance-cli spot get-account --omit-zero-balances true)
binance-cli spot ticker-price | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const prices=JSON.parse(s), acc=JSON.parse(process.argv[1]);
  const px={}; for(const p of prices) px[p.symbol]=+p.price;
  const stable=new Set(["USDT","USDC","BUSD","FDUSD","TUSD","DAI"]);
  let total=0; const rows=[];
  for(const b of acc.balances){
    const qty=+b.free+ +b.locked; if(!qty) continue;
    let usd = stable.has(b.asset)?qty : px[b.asset+"USDT"]!=null?qty*px[b.asset+"USDT"]
            : px[b.asset+"USDC"]!=null?qty*px[b.asset+"USDC"] : null;
    if(usd!=null) total+=usd; rows.push([b.asset,qty,usd]);
  }
  rows.sort((a,b)=>(b[2]||0)-(a[2]||0));
  for(const[a,q,u]of rows) console.log(a.padEnd(8),String(q).padStart(20),u==null?"(no pair)":("$"+u.toFixed(2)).padStart(14));
  console.log("".padEnd(8),"TOTAL".padStart(20),("$"+total.toFixed(2)).padStart(14));
})' "$ACC"
```
(`scripts/portfolio.sh` does this and the futures/NAV joins together.)
