# Official Binance Resources & How to Consult Them

When the skill doesn't cover something — an unfamiliar read endpoint, an enum's allowed values, a
rate-limit weight — go to the source rather than guessing. Order of preference:

## 1. The CLI itself (fastest, always current for your version)

```bash
binance-cli <product> --help                 # list a product's commands
binance-cli <product> <command> --help       # exact flags for one command
binance-cli --version                         # know which version's behavior you're seeing
```

## 2. The CLI repo's example files (copy-paste commands for every endpoint)

Repo: **github.com/binance/binance-cli** — `examples/<product>.md` maps every endpoint to a ready
command, e.g. `examples/spot.md`, `examples/derivatives-trading-usds-futures.md`, `examples/wallet.md`.

```bash
# fetch an example file directly (GitHub CLI, no clone)
gh api repos/binance/binance-cli/contents/examples/spot.md --jq '.content' | base64 -d
```

## 3. Official API documentation (authoritative spec: params, enums, weights, errors)

- Developer portal: **developers.binance.com/docs**
- Spot API: developers.binance.com/docs/binance-spot-api-docs
- USDⓈ-M futures: developers.binance.com/docs/derivatives/usds-margined-futures
- COIN-M futures: developers.binance.com/docs/derivatives/coin-margined-futures
- Wallet: developers.binance.com/docs/wallet

Fetch a page when you need exact semantics (a filter's meaning, an error code, a weight).

## 4. Official SDK connectors (for read-only scripting beyond the CLI)

Binance maintains connectors (same API, programmatic): Python (`binance-connector`), Java,
JavaScript/Node, Go, Rust, TypeScript, PHP — all under github.com/binance. Use these if a task wants
a long-running reader/analytics program rather than shell commands.

## A note on scope

Read / market-data commands are always safe. This skill is configured with a read-only key, so
state-changing commands (orders, transfers, leverage, withdrawals) will fail — don't attempt them.
When unsure whether a command reads or writes, check its `--help` description ("Query" / "Get" reads;
"Send" / "Cancel" / "Change" writes).
