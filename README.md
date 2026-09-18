# stockmine (working name)

Round game on Robinhood Chain in the style of ORE, with one change: the rewards are not a freshly minted
token, they are **tokenized stocks** bought on Uniswap with real revenue.

## How it works

1. **Rounds.** Every round (60 s by default) players put ETH on the squares of a 5x5 grid (`deploy(mask)`).
2. **Draw.** When the round is over anyone calls `close(round)`, which fixes an L2 block ~1 s in the future,
   then `settle(round)`, which reads that block's hash from ArbSys and picks the winning square.
   The hash is only readable for ~25 s (256 L2 blocks); if nobody settles in time, `close` can be called
   again and the round is drawn on a new block.
3. **ETH payout.** Players on the winning square get their stake back plus the ETH of the other squares,
   pro rata, minus a cut (7 % by default, 15 % hard cap). If nobody is on the winning square the ETH rolls
   over to the next round that has winners.
4. **The pot.** The cut of every round and the **Pons creator fees** of the project token accumulate as ETH
   in `potEth`. Any ETH sent to the contract joins the pot. See "Fee phases" for who collects the Pons fees.
5. **Epochs.** The keeper calls `closeEpoch(stock, poolFee, minOut)`: the whole pot is swapped for one
   allowed stock (NVDA, TSLA, SPY, AAPL, ...) through SwapRouter02 and split between
   - the **miners** of the epoch, in proportion to their winning stakes (`claimStock`), and
   - the **stakers** of the project token, in proportion to their stake (`claimStaking`).
   The split is 50/50 by default (20–80 % bounds). With no stakers everything goes to miners and vice versa.

The project token is a plain fixed-supply Pons token: nothing is ever minted as a reward, which is why the
design fits a Pons launch. `setToken` binds the token to the contract once, after the launch.

## Fee phases

Launch parameters decided so far: creator tax 1 % (`creatorTaxBps = 100`, immutable after launch), so the
creator side earns 1.7 % of every trade in ETH (0.7 % from the base fee plus the 1 % tax).

**Phase one: dev wallet is the Pons fee recipient.** The token is launched with the dev wallet as
`creatorFeeRecipient`. The dev claims the fees on Pons and forwards ETH to the contract, as much and as often
as they choose (this is also how the fees get spread over time instead of landing in one epoch). This phase
relies on trust: the transfers are public, but nothing in code forces them.

```bash
# claim what Pons owes the dev wallet (or use the Pons site)
cast send 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e "claim()" --rpc-url robinhood --private-key $PRIVATE_KEY
# send part of it to the pot
cast send $STOCKMINE --value 0.5ether --rpc-url robinhood --private-key $PRIVATE_KEY
```

**Phase two: the contract is the recipient.** Once the game has run cleanly, the dev wallet hands the fee
stream to the contract with one transaction on the Pons factory. From then on `harvest()` (open to anyone,
and called by every `closeEpoch`) pulls the fees straight into the pot, and the owner keeps `migrateFees` as
the emergency exit. Try this on a fork before doing it for real: it has not been exercised yet.

```bash
cast send 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e "transferCreatorFeeRecipient(address,address)" \
  $TOKEN $STOCKMINE --rpc-url robinhood --private-key $PRIVATE_KEY
```

## Trust model

- Player ETH is accounted separately from the pot. No role can move it.
- The owner can: allow/disallow stocks (max 16), set cut / split / unstake delay within hard bounds, pause
  **new deployments only** (closing, settling and all claims always work), set the keeper, bind the token
  once, and redirect the Pons creator fees to a new recipient (`migrateFees`, for a future version).
- The keeper chooses which allowed stock an epoch buys and the minimum amount out.
- Randomness is the hash of a future L2 block. Players and the keeper cannot predict it; the sequencer could.
  `close` and `settle` are permissionless, so a keeper bot should run them every round; if only an
  adversary were watching, they could let unfavourable draws expire and re-close.
- Staking has an unstake delay (3 days by default) that restarts on every new stake.

## Verified on chain (2026-09-19)

| What | Address |
| --- | --- |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Pons factory v2 | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` |
| Pons fee escrow | `0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e` |
| Pons launch + buy router | `0xe33E9E479dF8802cb0866d5d05258bEc4cF62948` |

Pons: launch fee 0.0005 ETH, curve fee 1 % (30 % protocol, rest to the creator), optional creator tax up to
10 % set at launch and immutable, fees paid in ETH and pulled with `claim()` by the recipient, which may be
a contract. Stock pools used in the fork test: NVDA/WETH 0.05 %, TSLA/WETH 0.3 %, SPY/WETH 0.05 %,
AAPL/WETH 0.05 %.

## Tests

```bash
forge test                      # unit tests, mocks only
FORK=1 forge test -vv           # adds the fork tests: real router, real stocks, real Pons escrow
```

## Not built yet

Keeper bot (close/settle every round, closeEpoch), web app, deploy script, Pons launch script for the token.
