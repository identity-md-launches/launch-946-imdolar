# IMDOLAR (DOLAR)

An immutable ERC-20 that mints **1,000,000,000 DOLAR with 18 decimals** to its deployer, once in the constructor. Every transfer sourced from its configured launch PoolManager charges a permanent **99% buy tax**, regardless of caller or recipient. The tax is burned. There is no owner, exemption list, tax switch, later mint, pause, blacklist, confiscation, or upgrade mechanism.

## Explicit assumptions

- **Buy definition:** an ERC-20 transfer whose `from` is the immutable `poolManager`. This covers all pools and recipients using that manager, including the deployer, distributor, routers, and the token itself. `transferFrom` uses the same rule; approving a different spender does not bypass it.
- **Tax destination:** the request did not specify a treasury. This implementation burns the fee, reducing `totalSupply()`. No address receives or can withdraw the fee. The initial supply is fixed; the circulating supply subsequently decreases.
- **Rounding:** `net = floor(gross / 100)` and `fee = gross - net`, in the token's smallest units. For 100 DOLAR out, the buyer receives 1 DOLAR and 99 DOLAR are burned. Nonmultiples of 100 minor units round the tax upward by less than one minor unit. Transfers of 1–99 minor units from the manager deliver zero and burn the full amount. Splitting transfers cannot reduce tax. Zero-value transfers are allowed and do not burn anything.
- **Other flows:** wallet transfers, pool seeding, sells into the manager, factory distributions, and distributor claims arrive in full because their source is not the manager. These are distinct transfer directions, not address exemptions.

An ERC-20 sees transfers, not economic intent. It cannot universally recognize an OTC purchase, an external exchange, another PoolManager, a custodial trade, or a trade settled solely in v4 internal/ERC-6909 credits. Those operations are outside the buy definition above; withdrawal of DOLAR from the configured manager is taxed. Conversely, **every outgoing manager transfer is taxed**, including liquidity withdrawals, refunds, fee collection, and manager self-transfers. This project does not claim to enforce a tax on every possible market or off-chain trade. If that broader meaning is required, the requested behavior cannot be guaranteed by this token interface alone.

## Scope limits that need requester sign-off

**Status: OPEN. Nothing in this repository evidences the requester's acceptance.** Two independent review rounds reproduced the two consequences below against the vendored v4 PoolManager and confirmed that no change confined to this repository can remove them: both are inherent to a tax applied at the ERC-20 transfer layer, and the token is immutable. This launch must not deploy until one of the following is recorded outside this repository by whoever admits the launch:

- the requester's explicit, written acceptance of the narrower tax definition exactly as stated in the "Manifest notes" paragraph below; or
- the network's agreement to the hook-based alternative at the end of this section, in which case this token's `_update` override must be dropped and the manifest changed before deployment.

Nothing here is hidden: each limit is pinned by a passing test in `test/IMDOLAR.v4.t.sol` so that the shipped behaviour is exactly what the tests show.

1. **A v4 buy whose DOLAR stays inside the PoolManager is not taxed at the time of the swap.** Uniswap v4 lets a swapper settle a positive DOLAR delta without an ERC-20 transfer: by minting an ERC-6909 claim (`PoolManager.mint`), by selling again inside the same `unlock` so the delta nets to zero, or by routing through DOLAR in a multi-hop swap. In all of these the token is never called, so the buyer holds the gross output as a claim and nothing burns. The 99% is charged only when DOLAR is withdrawn from the manager as an ERC-20 transfer (`take`); a claim that is sold back inside the manager is never taxed, and a buy-then-sell inside one unlock costs only the pool's LP fee. Any unprivileged router can use these settlement shapes, permanently, so on the launch venue the brief's "99% on all buys, no exceptions" is delivered only for buys that are withdrawn as ERC-20 transfers. Tests: `test_ClaimSettledBuyIsOutsideTheTransferTaxUntilWithdrawn`, `test_NettedRoundTripInsideOneUnlockIsOutsideTheTransferTax`.
2. **Every DOLAR outflow from the PoolManager pays the 99%, not only swap outputs.** Removing liquidity, collecting DOLAR LP fees, and collecting protocol fees all leave the manager through `take` or `collectProtocolFees`, which the token sees as a transfer from the manager. A liquidity provider who deposits DOLAR into the launch pool and withdraws it, with no trade in between, receives 1% and burns 99% of the principal. This applies to third-party LPs, to the factory's seeded position if it is ever unwound or migrated, and to the Uniswap protocol-fee recipient. DOLAR liquidity on the configured manager is one-way. Tests: `test_ThirdPartyLiquidityWithdrawalIsTaxedAsAManagerOutflow`, `test_LiquidityWithdrawalAlsoPaysTax`, `test_ProtocolFeeCollectionIsTaxedAsAManagerOutflow`.

Three further points were raised as information and are restated here for the same sign-off:

- The 99% is **burned**. No treasury, deployer, or requester receives it, and no recipient can be added later.
- The rate is a **floor**: the buyer's share is `gross / 100` rounded down, so an outflow below 100 minor units burns entirely. `BUY_TAX_BPS = 9900` is exact only for multiples of 100 minor units.
- Only the one immutable `poolManager` is a taxed source. A DOLAR market on any other contract (another PoolManager, a v2/v3 pair, an aggregator's inventory, a CEX, an OTC escrow) pays out untaxed, and no source can be added later.

**The alternative that closes limits 1 and 2** is to enforce the tax where the swap happens: a Uniswap v4 hook with `afterSwap` and `afterSwapReturnDelta` permissions that takes 99% of the DOLAR output from the swapper's delta and burns it, with no `_update` override in the token. That hook must be part of the pool key. The custom-token launch manifest carries no hook field, and the launch pool's hook is the network's initialization guard, so this path requires the network's agreement and a manifest change before it can be used. It is not delivered here because it cannot be attached to the launch pool as the launch is currently defined. If the requester wants claim-settled buys taxed, that agreement is a prerequisite and this token's `_update` override should then be dropped so hooked buys are not taxed twice.

### Manifest notes (copy verbatim)

> DOLAR charges a permanent, immutable 99% tax, burned, on every ERC-20 transfer whose source is the configured PoolManager. This is the only tax mechanism. (1) A v4 swap whose DOLAR output is settled as an ERC-6909 claim or netted inside one unlock is NOT taxed at swap time; the 99% is charged only when DOLAR is withdrawn from the manager as an ERC-20 transfer, and a claim sold back inside the manager is never taxed. (2) EVERY DOLAR outflow from the manager is taxed, including liquidity removal, LP fee collection and protocol fee collection: DOLAR liquidity on this pool is one-way and any LP loses 99% of DOLAR principal on withdrawal. (3) The buyer's share is gross/100 rounded down; outflows under 100 minor units burn entirely. (4) No other venue is taxed and none can be added. (5) The tax is burned; no address receives it. Routers must quote net amounts. Deployment requires the requester's explicit acceptance of these terms.

The paragraph above states what the token does. It does not state that the requester has accepted it, because nothing in this repository can evidence that. Whoever collects the acceptance records it with the launch, not here; the manifest notes should not claim acceptance until it is true.

## Build and test offline

Foundry and the pinned Solidity **0.8.26** compiler must already be installed. All imported Solidity dependencies are ordinary files under `lib/`; there are no submodules, runtime downloads, forks, environment-variable requirements, FFI, or filesystem cheatcode permissions.

```sh
forge build
forge test
forge fmt --check
```

The configuration uses Cancun (needed by the v4 test manager), optimization with 200 runs, IR compilation, and `bytecode_hash = "none"`. The default suite includes 512 runs per fuzz test and 128 invariant campaigns of 64 calls. Tests create fresh local state and can run in parallel or in any order.

## Deployment parameters

Deployable artifact: **`src/IMDOLAR.sol:IMDOLAR`**.

```solidity
constructor(address poolManager_)
```

| Parameter/property | Value or responsibility |
| --- | --- |
| `poolManager_` | The correct, already deployed PoolManager on the target chain. Unspecified in the assignment; the deployer must resolve and verify it. Immutable after construction. |
| Constructor value | 0 ETH; the constructor is nonpayable. |
| Name / symbol / decimals | `IMDOLAR` / `DOLAR` / `18` |
| Initial supply in minor units | `1000000000000000000000000000` (`10^27`) |
| Initial supply holder | The immediate constructor caller (`msg.sender`). For `ProjectFactory.launchCustom`, this is the factory, not the transaction sender. |
| Factory manifest constructor arguments | `["$poolManager"]` in that order. No factory or launch-number argument is needed. |
| Additional application contracts | None. Contracts under `test/` are fixtures only. |
| Postdeployment initialization | None. The tax applies immediately and never expires. |

The constructor rejects zero, an address without deployed code, itself, and its deployer as the manager. A code-length check does **not** authenticate a PoolManager; the operator must verify the chain and bytecode independently. Supplying a wrong contract permanently taxes the wrong source, and cannot be repaired in place.

No deployment script broadcasts transactions or accesses wallet keys. The factory can use the compiled creation bytecode followed by `abi.encode(poolManager_)`; its entire initial allocation is available immediately. The tests exercise both direct construction and CREATE2 factory construction.

The launch operator must supply the chain, factory, paired currency, LP fee, tick spacing, initial price/capitalization, pool allocation, and remainder recipient from the actual launch job. None were supplied here, so no addresses or economic parameters are invented for a production manifest. The integration tests' prices, ranges, and allocations are local fixtures. The network's separate manifest step must use the initial supply above and the actual job's economics.

## Operation and integration responsibilities

The launch factory's distributor transfer, single-sided seed, and remainder transfer do not pay tax. Contributor claims also arrive whole. In a conventional v4 buy settlement (`take` to the buyer), the manager loses the gross DOLAR amount, while the trader receives only the net amount. A sell settles the entire incoming DOLAR amount, with no sell tax. The real-manager tests cover this cycle for ETH and ERC-20 pairs in both currency orderings. A buy settled as an ERC-6909 claim is taxed only on withdrawal, and a liquidity withdrawal is taxed like a buy; see "Scope limits that need requester sign-off".

Routers and frontends must measure recipients' **net balance changes** and express minimum received amounts in net units. A v4 exact-output amount describes gross output from the manager; it is not a promise of that many tokens in the buyer's wallet. A router that requires the gross quote to arrive will revert. Do not assume compatibility with every public router, aggregator, credit-based settlement path, or multihop route; test the chosen production route. Display the permanent 99% tax and dust rounding before users trade. This token pays no rewards or revenue to a treasury.

The deployer must verify the deployed runtime and immutable manager, publish verified source, configure and seed the intended market, and validate the chosen routing and net slippage protection. There are no ongoing administrative keys or maintenance functions for this token. Mistaken transfers to the token contract cannot be rescued.

## Verification coverage and limits

- `test/IMDOLAR.t.sol`: metadata, mint event and CREATE2 ownership, invalid construction, exact launch distributions, tax events, recipient/caller treatment, full allowance consumption and revocation, zero/dust/max values, self-transfers, rollback after a partial internal burn, privileged-call rejection, runtime opcode checks, and fuzzed conservation/rounding.
- `test/IMDOLAR.v4.t.sol`: a vendored real PoolManager, launch funding and claims, native/ERC-20 pair orderings, taxed buys and successful untaxed sells, factory/distributor recipients, exact-output semantics, taxed liquidity removal (factory seed and third-party LP), taxed protocol-fee collection, ERC-6909 claim-settled buys (untaxed until withdrawn), a buy-then-sell netted inside one unlock (untaxed), insufficient net output rollback, and unfunded settlement failure.
- `test/IMDOLAR.invariant.t.sol`: random sequences of buys, sells, and wallet transfers with an independent burn ledger; live balances equal current supply and live supply plus burns equals initial supply.

The supplied protected test was read as the acceptance reference. It is an external harness requiring launch environment values and network-owned `LaunchLiquidity`, `PoolInitializationGuard`, and `HookFlags` contracts that are not supplied in this repository. It is not copied, modified, or represented as having run here. Local integration tests exercise its relevant token flows with stricter tax assertions; the independent verifier must still run the actual protected harness against the final manifest.

The security review considered access control, balance/allowance accounting, rounding, overflow, external calls, and administrative surface. Token transfers make no external calls, use OpenZeppelin's ERC-20 accounting, and have no callbacks or user-controlled execution. Reverts roll back both the burn and allowance spending. There is no oracle, signature flow, proxy, or randomness. Foundry tests are not an independent security audit; Slither and Mythril were not run. A separate adversarial review remains a release responsibility.

Dependency revisions, upstream licenses, and SHA-256 hashes are recorded in [`lib/VENDORED.json`](lib/VENDORED.json). Only the transitive source files needed by the token and tests are vendored. OpenZeppelin v5.1.0 supplies the ERC-20 implementation; forge-std v1.9.7 supplies test helpers. The v4 and Solmate sources are used by the local integration tests, not deployed by this project.
