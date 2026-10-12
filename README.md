# Scoop (SCOOP)

A fixed-supply ERC-20 token for an IdentityMD custom-token launch on Ethereum.

| Parameter        | Value                                                        |
| ---------------- | ------------------------------------------------------------ |
| Token name       | `Scoop`                                                      |
| Symbol           | `SCOOP`                                                      |
| Decimals         | 18                                                           |
| Total supply     | 1,000,000,000 SCOOP = `1000000000000000000000000000` minor units |
| Minting          | Once, in the constructor, all of it to the deployer (`msg.sender`) |
| Solidity contract | `ScoopToken` (`src/ScoopToken.sol`)                         |
| Constructor args | none                                                         |
| Compiler         | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## Layout

```
foundry.toml          Foundry configuration (compiler pin, bytecode_hash = "none", no ffi/fs)
remappings.txt        forge-std/ -> lib/forge-std/src/
src/ScoopToken.sol    the token
script/DeployScoop.s.sol  manual deployment helper (not used by the launch)
test/ScoopToken.t.sol unit, failure, fuzz and launch-floor mirror tests
lib/forge-std/        forge-std v1.14.0, vendored as ordinary files (MIT / Apache-2.0)
```

## Behaviour

`ScoopToken` is a self-contained ERC-20 with no external dependencies and no privileged roles.

- **Fixed supply.** `totalSupply` is an immutable set once in the constructor. There is no `mint`,
  `burn`, `burnFrom`, owner, minter role, proxy or `initialize`. The supply can never change.
- **Plain transfers.** `transfer` and `transferFrom` move exactly the amount requested. There is no
  fee, tax, reflection, blocklist, pause, cooldown or maximum-wallet rule, so every launch flow
  (factory to MerkleDistributor, distributor to claimants, pool seed, swaps through the Uniswap v4
  PoolManager) arrives whole without any exemption list.
- **Allowances.** Standard `approve`, plus `increaseAllowance` / `decreaseAllowance` to avoid the
  approve race. An allowance of `type(uint256).max` is treated as unlimited and is not decremented.
- **Input validation.** Transfers to the zero address and approvals of the zero spender revert with
  `ZeroAddress()`. Over-spends revert with `InsufficientBalance(sender, balance, needed)` or
  `InsufficientAllowance(spender, allowed, needed)`.
- **No dangerous opcodes.** The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`
  (asserted in the tests), accepts no ETH, and has no fallback.
- **Events.** `Transfer` on every balance change including the constructor mint; `Approval` on
  every allowance change including the decrement performed by `transferFrom`.

## Assumptions

- The brief asks for a plain fixed-supply token: name, symbol, supply and decimals only. No burn,
  tax, vesting, governance or admin feature was requested, so none was added. Any such feature
  would be a scope change and would need its own review against the launch floor.
- "The deployer" is whoever is `msg.sender` when the constructor runs. At launch that is the
  IdentityMD `ProjectFactory`, which receives the whole supply and pays it out. In a manual
  deployment it is the broadcasting account.
- The token takes no constructor arguments. It does not need the factory, pool manager or launch
  number because it exempts nothing: with no fee or restriction there is nothing to exempt.
- The constructor calls no other contract and requires no address to have code, so it deploys on an
  empty chain exactly as the launch checks require.

## Deployment parameters (launch)

These are decided by the launch and are recorded here for the manifest step, which writes
`launch.json` after this work is accepted. **No `launch.json` is included in this repository on
purpose.**

| Item                        | Value                                                     |
| --------------------------- | --------------------------------------------------------- |
| Chain                       | Ethereum mainnet (chain id 1)                             |
| `token.contract`            | `ScoopToken`                                              |
| `token.name` / `token.symbol` | `Scoop` / `SCOOP`                                       |
| `token.decimals`            | 18                                                        |
| `token.constructorArgs`     | `[]`                                                      |
| `token.totalSupply`         | `1000000000000000000000000000`                            |
| Application contracts       | none                                                      |
| `pool.pairedCurrency`       | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| `pool.fee`                  | 12500 (1.25%)                                             |
| `pool.tickSpacing`          | 60                                                        |
| `pool.initialPrice`         | `79228162514264337593543950336` (provenance only; the deployer derives the real opening price) |
| `economics.poolBps`         | 8000                                                      |
| `economics.initialMarketCapWei` | `2500000000000000000000` (2,500 IMD for the whole supply) |
| `economics.remainderTo`     | `0xff3e8d9ba776662ca6ed1420ee366afb436d2684`              |

Supply distribution performed by the factory (nothing here reserves or pre-allocates any of it):

| Share | Recipient                                             |
| ----- | ----------------------------------------------------- |
| 10%   | The launch's MerkleDistributor (swarm share)          |
| 80%   | Single-sided Uniswap v4 pool seed, paired with IMD    |
| 10%   | `economics.remainderTo`                               |

## Manual deployment (outside the launch)

`script/DeployScoop.s.sol` exposes `deploy()`, which the tests call directly, and `run()`, which
wraps it in a broadcast. It reads no environment variables; the signer comes from the command line.

```sh
forge script script/DeployScoop.s.sol:DeployScoop --rpc-url <RPC> --account <KEYSTORE_ACCOUNT> --broadcast
```

The broadcasting account receives the entire supply. This repository does not hold keys and the
task did not authorise any transaction.

## Operational responsibilities

The token has no owner and no admin functions, so there is nothing to rotate, pause or upgrade.
What remains is for the requester / launch operator:

- **Source verification.** After the launch deploys the token, verify the source on Etherscan with
  `forge verify-contract` using the same compiler settings (0.8.26, optimizer 200 runs, cancun,
  `bytecode_hash = "none"`). Unverified tokens are indistinguishable from scams.
- **Custody of the remainder.** 10% of the supply goes to `economics.remainderTo`. Whoever controls
  that address controls those tokens; secure that key.
- **Allowance hygiene.** Holders should grant exact allowances to contracts they interact with.
  The token honours unlimited allowances as the standard allows, so a compromised spender with an
  unlimited allowance can drain a holder.
- **Irreversibility.** Tokens sent to the zero address are refused, but tokens sent to any other
  wrong address, or to a contract that cannot handle them, cannot be recovered by anyone.
- **Independent review.** Passing tests are not an audit. Anything that will hold other people's
  funds on top of this token needs a separate adversarial review before release.

## Security notes

Checked against the eth-security reference supplied with the task:

- Access control: no privileged functions exist, so none can be misconfigured.
- Pausable / censorship: none. No single key can freeze or seize a holder's balance.
- Reentrancy: the token makes no external calls.
- Integer math: balances use checked arithmetic except where an over/underflow is provably
  impossible (documented inline); allowance increase reverts on overflow.
- Input validation: zero-address recipient and spender are rejected; amounts are bounded by
  balances and allowances.
- Upgradeability, oracles, delegatecall, signatures: not used.
- Automated analysis: only Foundry's compiler, unit and fuzz tests were run (Slither / Mythril are
  not available in this environment).

## Build and test

```sh
forge build
forge test
forge fmt --check
```

All tests pass in any order and in parallel. They read no environment variables and never call
`vm.setEnv`.
