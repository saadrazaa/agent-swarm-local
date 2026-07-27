#!/usr/bin/env bash
# portfolio.sh — consolidated, read-only cross-product portfolio & risk snapshot.
# Joins: NAV rollup (all wallets), USDⓈ-M futures account + open positions with risk metrics,
# spot holdings valued at live prices, and cross-margin state. Uses the read-only `ro` key.
#
# Usage: portfolio.sh
set -euo pipefail

if ! command -v binance-cli >/dev/null 2>&1; then
  export PATH="$(npm config get prefix 2>/dev/null)/bin:$PATH"
fi

BTCPX="$(binance-cli spot ticker-price --symbol BTCUSDT 2>/dev/null || echo '{}')"
NAV="$(binance-cli wallet query-user-wallet-balance 2>/dev/null || echo '[]')"
FACC="$(binance-cli futures-usds account-information-v3 2>/dev/null || echo '{}')"
FPOS="$(binance-cli futures-usds position-information-v3 2>/dev/null || echo '[]')"
SACC="$(binance-cli spot get-account --omit-zero-balances true 2>/dev/null || echo '{}')"
FUND="$(binance-cli wallet funding-wallet 2>/dev/null || echo '[]')"
MARGX="$(binance-cli margin-trading query-cross-margin-account-details 2>/dev/null || echo '{}')"

# all-prices (large) via stdin; everything else via env.
binance-cli spot ticker-price 2>/dev/null | \
BTCPX="$BTCPX" NAV="$NAV" FACC="$FACC" FPOS="$FPOS" SACC="$SACC" FUND="$FUND" MARGX="$MARGX" node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const J=(x,f)=>{try{return JSON.parse(x)}catch(e){return f}};
  const prices=J(s,[]); const px={}; for(const p of prices) px[p.symbol]=+p.price;
  const btc=+(J(process.env.BTCPX,{}).price)||0;
  const nav=J(process.env.NAV,[]), facc=J(process.env.FACC,{}), fpos=J(process.env.FPOS,[]);
  const sacc=J(process.env.SACC,{}), fund=J(process.env.FUND,[]), margx=J(process.env.MARGX,{});
  const money=(v)=>"$"+Number(v||0).toLocaleString("en-US",{minimumFractionDigits:2,maximumFractionDigits:2});
  const n=(v,d=2)=>Number(v||0).toLocaleString("en-US",{maximumFractionDigits:d});

  // ---- NAV rollup ----
  console.log("== NET ASSET VALUE (by wallet) ==");
  let navTotal=0; const navRows=[];
  for(const w of nav){ const b=+w.balance||0; if(b<=0) continue; const usd=b*btc; navTotal+=usd; navRows.push([w.walletName,b,usd]); }
  navRows.sort((a,b)=>b[2]-a[2]);
  for(const [name,b,usd] of navRows) console.log("  "+name.padEnd(18), (n(b,8)+" BTC").padStart(20), money(usd).padStart(16));
  console.log("  "+"TOTAL NAV".padEnd(18), "".padStart(20), money(navTotal).padStart(16));

  // ---- USDⓈ-M futures ----
  const equity=+facc.totalMarginBalance||0;
  if(equity>0 || (fpos&&fpos.length)){
    console.log("\n== USDⓈ-M FUTURES ==");
    const uPnl=+facc.totalUnrealizedProfit||0, maint=+facc.totalMaintMargin||0, avail=+facc.availableBalance||0;
    let gross=0, net=0;
    const rows=fpos.map(p=>{
      const amt=+p.positionAmt, notion=Math.abs(+p.notional||0), im=+p.initialMargin||0;
      const mark=+p.markPrice, liq=+p.liquidationPrice||0;
      gross+=notion; net+=(+p.notional||0);
      const lev=im>0?notion/im:0;
      const dist=(mark>0&&liq>0)?Math.abs(mark-liq)/mark*100:null;
      return {sym:p.symbol, side:amt>=0?"LONG":"SHORT", notion, entry:+p.entryPrice, mark,
              uPnl:+p.unRealizedProfit||0, lev, liq, dist};
    }).sort((a,b)=>b.notion-a.notion);
    console.log("  equity "+money(equity)+" | uPnL "+money(uPnl)+" ("+(equity?(uPnl/equity*100).toFixed(1):"-")+"% of equity)"
      +" | avail "+money(avail)+" | margin ratio "+(equity?(maint/equity*100).toFixed(1):"-")+"%"
      +" | acct lev "+(equity?(gross/equity).toFixed(1):"-")+"x");
    console.log("  gross exposure "+money(gross)+" | net "+money(net));
    if(rows.length){
      console.log("");
      console.log("  "+"SYMBOL".padEnd(14)+"SIDE ".padEnd(6)+"NOTIONAL".padStart(13)+"  "+"ENTRY".padStart(11)+"  "+"MARK".padStart(11)+"  "+"uPnL".padStart(11)+"  "+"LEV".padStart(6)+"  "+"LIQ".padStart(11)+"  "+"DIST%".padStart(7));
      for(const r of rows)
        console.log("  "+r.sym.padEnd(14)+r.side.padEnd(6)+money(r.notion).padStart(13)+"  "+n(r.entry,4).padStart(11)+"  "+n(r.mark,4).padStart(11)+"  "+money(r.uPnl).padStart(11)+"  "+(r.lev?r.lev.toFixed(1)+"x":"-").padStart(6)+"  "+n(r.liq,4).padStart(11)+"  "+(r.dist==null?"-":r.dist.toFixed(0)+"%").padStart(7));
    }
  }

  // ---- Spot holdings ----
  const stable=new Set(["USDT","USDC","BUSD","FDUSD","TUSD","DAI"]);
  const sb=(sacc.balances||[]).map(b=>{
    const qty=+b.free+ +b.locked; if(!qty) return null;
    let usd = stable.has(b.asset)?qty : px[b.asset+"USDT"]!=null?qty*px[b.asset+"USDT"]
            : px[b.asset+"USDC"]!=null?qty*px[b.asset+"USDC"] : null;
    return {asset:b.asset, qty, usd};
  }).filter(Boolean).sort((a,b)=>(b.usd||0)-(a.usd||0));
  if(sb.length){
    console.log("\n== SPOT HOLDINGS ==");
    let tot=0;
    for(const b of sb){ if(b.usd!=null) tot+=b.usd; console.log("  "+b.asset.padEnd(10)+n(b.qty,8).padStart(20)+"  "+(b.usd==null?"(no pair)":money(b.usd)).padStart(14)); }
    console.log("  "+"TOTAL".padEnd(10)+"".padStart(20)+"  "+money(tot).padStart(14));
  }

  // ---- Funding wallet holdings ----
  const fb=(Array.isArray(fund)?fund:[]).map(b=>{
    const qty=+b.free+ +b.locked+ +(b.freeze||0); if(!qty) return null;
    let usd = stable.has(b.asset)?qty : px[b.asset+"USDT"]!=null?qty*px[b.asset+"USDT"]
            : px[b.asset+"USDC"]!=null?qty*px[b.asset+"USDC"] : null;
    return {asset:b.asset, qty, usd};
  }).filter(Boolean).sort((a,b)=>(b.usd||0)-(a.usd||0));
  if(fb.length){
    console.log("\n== FUNDING WALLET ==");
    let tot=0;
    for(const b of fb){ if(b.usd!=null) tot+=b.usd; console.log("  "+b.asset.padEnd(10)+n(b.qty,8).padStart(20)+"  "+(b.usd==null?"(no pair)":money(b.usd)).padStart(14)); }
    console.log("  "+"TOTAL".padEnd(10)+"".padStart(20)+"  "+money(tot).padStart(14));
  }

  // ---- Cross margin (only if there is a balance/liability) ----
  const mBtc=+margx.totalNetAssetOfBtc||0, mLiab=+margx.totalLiabilityOfBtc||0;
  if(mBtc*btc>=1 || mLiab>0){
    console.log("\n== CROSS MARGIN ==");
    console.log("  net asset "+money(mBtc*btc)+" | liability "+money(mLiab*btc)+" | margin level "+(margx.marginLevel||"-"));
  }

  console.log("\n(BTC ref "+money(btc)+". Read-only snapshot. Exposure-by-asset-class & allocation view: references/analysis.md)");
});'
