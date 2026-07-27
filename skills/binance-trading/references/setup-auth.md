# Setup, the read-only profile & key security

## Install / update

```bash
npm install -g @binance/binance-cli    # requires Node.js (v18+; tested on 26)
binance-cli --version                  # e.g. 1.3.0
```
If the shell can't find `binance-cli` after install, the npm global bin dir isn't on PATH:
```bash
export PATH="$(npm config get prefix)/bin:$PATH"
```
(Add that line to `~/.zshrc` / `~/.bashrc` to persist.)

## The read-only profile (`ro`)

This skill runs against a single profile — `ro` — backed by an **Ed25519 API key with only the
"Reading" permission, IP-restricted**. Confirm what's active and that the key really is read-only:
```bash
binance-cli profile view                    # expect: ro (prod)
binance-cli profile list                     # '*' marks the active profile
binance-cli wallet get-api-key-permission    # verify capabilities (see below)
```
`get-api-key-permission` should show `enableReading: true`, `ipRestrict: true`, and
`enableSpotAndMarginTrading` / `enableFutures` / `enableMargin` / `enableWithdrawals` all `false`.
If any trading flag is true, it's not the read-only key this skill expects — stop and check.

**Important — these flags are *trading* scopes, not read scopes.** `enableFutures: false` /
`enableMargin: false` do **not** block reading futures positions or margin state; `enableReading:
true` gates all reads, so the whole account is readable (spot, futures, margin, earn, income, NAV).
For the authoritative *account-capability* view (what products the account itself has enabled), use
`binance-cli wallet account-info` (`isFutureEnabled`, `isMarginEnabled`,
`isPortfolioMarginRetailEnabled`, `isOptionsEnabled`). See `references/portfolio.md`.

## Why Ed25519, and how the profile stores it

You generate the keypair locally and register only the **public** key with Binance; the private
key never leaves your machine and can't be exposed by a Binance-side breach. The profile stores the
**path** to the private key, so the key stays in its own file and is never copied into the config
store:
```bash
# one-time — generate locally, lock down perms, derive the public key
mkdir -p ~/.binance/keys && chmod 700 ~/.binance ~/.binance/keys
openssl genpkey -algorithm ed25519 -out ~/.binance/keys/ro-ed25519.pem
chmod 600 ~/.binance/keys/ro-ed25519.pem
openssl pkey -in ~/.binance/keys/ro-ed25519.pem -pubout -out ~/.binance/keys/ro-ed25519.pub

# register ro-ed25519.pub on Binance (API Management -> Create API -> Self-generated;
# permissions: Reading only; Restrict access to trusted IPs). Binance returns an API-key
# identifier — there is NO secret to copy, because you hold the private key.

# point the profile at the private-key FILE (stores the path, not the contents)
binance-cli profile create --name ro --env prod \
  --api-key "<API_KEY_IDENTIFIER>" \
  --api-secret "$HOME/.binance/keys/ro-ed25519.pem" \
  --select --force
```
### Auth from environment variables (how the containerized swarm authenticates)

The CLI also authenticates entirely from the environment, with **no profile configured** — this is
how the swarm's agents get the read-only key (it is injected as env from the swarm's global config,
so there is no interactive `profile create` step and no file on disk to point at):

- `BINANCE_API_KEY` — the API-key **identifier** (the public half registered on Binance).
- `BINANCE_SECRET_KEY` — accepts **any one** of three forms:
  1. **the PEM contents themselves** — the full Ed25519 private key as a string, including the
     `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----` lines and their line breaks. Use
     this in the swarm, where the key lives in config, not in a file.
  2. **a path to a `.pem` file** — e.g. `/run/secrets/binance-ro.pem`, when the key is mounted.
  3. **an HMAC secret string** — for the classic HMAC-SHA256 key type (not the Ed25519 flow this
     skill uses).
- `BINANCE_API_ENV` — `prod` | `testnet` (use `prod`).

**Env vars override the active profile.** Locally you may prefer the `ro` profile above; in the
swarm the agent relies on these env vars. Either way the key stays read-only (`enableReading` only),
so it can price and read the account but never trade or withdraw.

## Security rules

- **Never print, echo, paste, or read secret values** — not the Ed25519 private key, not an HMAC
  secret. Enter secrets only via `read -rs` or a file path. The private key is shared with no one and
  pasted nowhere; you register only the `.pub`.
- Lock down the config directory, and keep it out of cloud sync / Time Machine:
  ```bash
  chmod 700 ~/.binance ~/.binance/keys
  find ~/.binance -type f -exec chmod 600 {} \;
  ```
- **Back up the private key** encrypted/offline. Lose it and it can't be recovered (Binance holds
  only the public half) — you'd regenerate and re-register.
- **Keep the key IP-restricted.** A read-only key that leaks can, at worst, read balances *and only
  from the whitelisted IP* — never trade or withdraw. IP restriction also prevents Binance's 90-day
  auto-deletion of unrestricted keys.
- Don't build a redactor around an environment variable that might be empty — an empty pattern makes
  tools like `sed` error out or match everything, giving false confidence. The reliable rule is to
  keep secrets out of argv and out of command output in the first place.

## Product groups

`spot`, `futures-usds` (USDⓈ-M), `futures-coin` (COIN-M), `derivatives-options`, `margin-trading`,
`wallet`, `convert`, `simple-earn`, `staking`, `sub-account`, `fiat`, ... — full list via
`binance-cli --help`. Each has a `<group>-streams` counterpart for **WebSocket** market streams.
This skill uses only the **read/query** commands of these groups.

## Known bug — the plural `--symbols` flag (v1.3.0)

`--symbols '["BTCUSDT","ETHUSDT"]'` fails client-side validation
(`Illegal characters found in parameter 'symbols'`) because a Java-style regex misfires under Node.
The singular `--symbol` flag is fine. Two workarounds:
```bash
# 1) loop single-symbol calls
for s in BTCUSDT ETHUSDT BNBUSDT; do binance-cli spot ticker-price --symbol "$s"; done
# 2) raw passthrough skips the broken validation
binance-cli request GET https://api.binance.com/api/v3/ticker/price --symbols '["BTCUSDT","ETHUSDT"]'
```

## Raw passthrough & piped input (read-only)

```bash
# any read endpoint, wrapped or not; add --signed for authenticated reads
binance-cli request GET https://api.binance.com/api/v3/trades  --symbol BNBUSDT --limit 5
binance-cli request GET https://api.binance.com/api/v3/account --signed        # signed read via the ro key

# pipe JSON params instead of flags
echo '{"symbol":"BNBUSDT","interval":"1h","limit":3}' | binance-cli spot klines
```
