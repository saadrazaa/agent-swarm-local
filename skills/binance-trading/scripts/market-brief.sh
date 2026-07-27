#!/usr/bin/env bash
# market-brief.sh — positioning-aware futures snapshot for a basket of symbols.
# For each symbol: price, 24h %change, funding rate, open interest, and top-trader long%.
# Works across ALL asset classes (crypto, TradFi equity/commodity, pre-IPO perps) — public data.
#
# Usage:
#   market-brief.sh                                  # default crypto majors
#   market-brief.sh BTCUSDT ETHUSDT SOLUSDT
#   market-brief.sh AAPLUSDT NVDAUSDT XAUUSDT CLUSDT OPENAIUSDT
set -euo pipefail

if ! command -v binance-cli >/dev/null 2>&1; then
  export PATH="$(npm config get prefix 2>/dev/null)/bin:$PATH"
fi

SYMBOLS=("$@")
if [[ ${#SYMBOLS[@]} -eq 0 ]]; then
  SYMBOLS=(BTCUSDT ETHUSDT SOLUSDT BNBUSDT XRPUSDT)
fi

printf "%-12s %14s %8s %10s %16s %9s\n" "SYMBOL" "PRICE" "24H%" "FUNDING%" "OPEN_INT" "TOP_LONG%"
printf "%-12s %14s %8s %10s %16s %9s\n" "------" "-----" "----" "--------" "--------" "---------"

for SYM in "${SYMBOLS[@]}"; do
  T="$(binance-cli futures-usds ticker24hr-price-change-statistics --symbol "$SYM" 2>/dev/null || echo '{}')"
  M="$(binance-cli futures-usds mark-price --symbol "$SYM" 2>/dev/null || echo '{}')"
  O="$(binance-cli futures-usds open-interest --symbol "$SYM" 2>/dev/null || echo '{}')"
  L="$(binance-cli futures-usds top-trader-long-short-ratio-positions --symbol "$SYM" --period 1h --limit 1 2>/dev/null || echo '[]')"
  SYM="$SYM" T="$T" M="$M" O="$O" L="$L" node -e '
    const j=(s)=>{try{return JSON.parse(s)}catch(e){return null}};
    const t=j(process.env.T)||{}, m=j(process.env.M)||{}, o=j(process.env.O)||{};
    const larr=j(process.env.L); const l=Array.isArray(larr)&&larr.length?larr[larr.length-1]:{};
    const num=(v,d=2)=>v==null||v===""?"-":Number(v).toLocaleString("en-US",{maximumFractionDigits:d});
    const pct=(v)=>v==null||v===""?"-":Number(v).toFixed(2);
    const fund=(m.lastFundingRate==null||m.lastFundingRate==="")?"-":(Number(m.lastFundingRate)*100).toFixed(4);
    const longp=(l.longAccount==null||l.longAccount==="")?"-":(Number(l.longAccount)*100).toFixed(1);
    process.stdout.write(
      (process.env.SYM).padEnd(12)+" "+
      String(num(t.lastPrice,5)).padStart(14)+" "+
      String(pct(t.priceChangePercent)).padStart(8)+" "+
      String(fund).padStart(10)+" "+
      String(num(o.openInterest,0)).padStart(16)+" "+
      String(longp).padStart(9)+"\n");
  '
done

echo ""
echo "funding = per-8h rate (>0: longs pay shorts, crowded long) · OI in base units · TOP_LONG% = top-trader long positions"
echo "TradFi/pre-IPO perps show ~0 funding & '-' L/S when their market is closed — check: binance-cli futures-usds trading-schedule"
