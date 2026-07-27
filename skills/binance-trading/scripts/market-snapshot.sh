#!/usr/bin/env bash
# market-snapshot.sh — quick multi-symbol table: price, 24h %change, high, low, volume.
# Public data, no API key needed. Works around the broken plural --symbols flag by looping.
#
# Usage:
#   market-snapshot.sh spot    BTCUSDT ETHUSDT SOLUSDT
#   market-snapshot.sh futures BTCUSDT SNDKUSDT
set -euo pipefail

MARKET="${1:-}"; shift || true
if [[ -z "$MARKET" || $# -eq 0 ]]; then
  echo "usage: market-snapshot.sh <spot|futures> SYMBOL [SYMBOL ...]" >&2; exit 1
fi

# make sure the CLI is reachable even if npm's global bin isn't on PATH
if ! command -v binance-cli >/dev/null 2>&1; then
  export PATH="$(npm config get prefix 2>/dev/null)/bin:$PATH"
fi

case "$MARKET" in
  spot)    CMD=(binance-cli spot ticker24hr --type FULL --symbol) ;;
  futures) CMD=(binance-cli futures-usds ticker24hr-price-change-statistics --symbol) ;;
  *) echo "market must be 'spot' or 'futures', got '$MARKET'" >&2; exit 1 ;;
esac

printf "%-12s %14s %9s %14s %14s %16s\n" "SYMBOL" "PRICE" "24H%" "HIGH" "LOW" "QUOTE_VOL"
printf "%-12s %14s %9s %14s %14s %16s\n" "------" "-----" "----" "----" "---" "---------"

for SYM in "$@"; do
  OUT="$("${CMD[@]}" "$SYM" 2>&1)" || { printf "%-12s  %s\n" "$SYM" "ERROR: $OUT"; continue; }
  echo "$OUT" | SYM="$SYM" node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      try{
        const t=JSON.parse(s);
        const f=(v,d=2)=>v==null||v===""?"-":Number(v).toLocaleString("en-US",{maximumFractionDigits:d});
        process.stdout.write(
          (process.env.SYM).padEnd(12)+" "+
          String(f(t.lastPrice,5)).padStart(14)+" "+
          String(t.priceChangePercent==null?"-":Number(t.priceChangePercent).toFixed(2)).padStart(9)+" "+
          String(f(t.highPrice,5)).padStart(14)+" "+
          String(f(t.lowPrice,5)).padStart(14)+" "+
          String(f(t.quoteVolume,0)).padStart(16)+"\n");
      }catch(e){ process.stdout.write((process.env.SYM).padEnd(12)+"  parse error: "+s.slice(0,80)+"\n"); }
    });'
done
