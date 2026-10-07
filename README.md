# IMDOLAR (DOLAR)

An immutable ERC-20 that mints **1,000,000,000 DOLAR with 18 decimals** to its deployer, once in the constructor. Every transfer sourced from its configured launch PoolManager charges a permanent **99% buy tax**, regardless of caller or recipient. The tax is burned. There is no owner, exemption list, tax switch, later mint, pause, blacklist, confiscation, or upgrade mechanism.

## Explicit assumptions

- **Buy definition:** an ERC-20 transfer whose `from` is the immutable `poolManager`. This covers all pools and recipients using that manager, including the deployer, distributor, routers, and the token itself. `transferFrom` uses the same rule; approving a different spender does not bypass it.
- **Tax destination:** the request did not specify a treasury. This implementation burns the fee, reducing `totalSupply()`. No address receives or can withdraw the fee. The initial supply is fixed; the circulating supply subsequently decreases.
- **Rounding:** `net = floor(gross / 100)` and `fee = gross - net`, in the token's smallest units. For 100 DOLAR out, the buyer receives 1 DOLAR and 99 DOLAR are burned. Nonmultiples of 100 minor units round the tax upward by less than one minor unit. Transfers of 1–99 minor units from the manager deliver zero and burn the full amount. Splitting transfers cannot reduce tax. Zero-value transfers are allowed and do not burn anything.
- **Other flows:** wallet transfers, pool seeding, sells into the manager, factory distributions, and distributor claims arrive in full because their source is not the manager. These are distinct transfer directions, not address exemptions.

An ERC-20 sees transfers, not economic intent. It cannot universally recognize an OTC purchase, an external exchange, another PoolManager, a custodial trade, or a trade settled solely in v4 internal/ERC-6909 credits. Those operations are outside the buy definition above; withdrawal of DOLAR from the configured manager is taxed. Conversely, **every outgoing manager transfer is taxed**, including liquidity withdrawals, refunds, fee collection, and manager self-transfers. This project does not claim to enforce a tax on every possible market or off-chain trade. If that broader meaning is required, the requested behavior cannot be guaranteed by this token interface alone.

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

The launch factory's distributor transfer, single-sided seed, and remainder transfer do not pay tax. Contributor claims also arrive whole. In a conventional v4 buy settlement, the manager loses the gross DOLAR amount, while the trader receives only the net amount. A sell settles the entire incoming DOLAR amount, with no sell tax. The real-manager tests cover this cycle for ETH and ERC-20 pairs in both currency orderings.

Routers and frontends must measure recipients' **net balance changes** and express minimum received amounts in net units. A v4 exact-output amount describes gross output from the manager; it is not a promise of that many tokens in the buyer's wallet. A router that requires the gross quote to arrive will revert. Do not assume compatibility with every public router, aggregator, credit-based settlement path, or multihop route; test the chosen production route. Display the permanent 99% tax and dust rounding before users trade. This token pays no rewards or revenue to a treasury.

The deployer must verify the deployed runtime and immutable manager, publish verified source, configure and seed the intended market, and validate the chosen routing and net slippage protection. There are no ongoing administrative keys or maintenance functions for this token. Mistaken transfers to the token contract cannot be rescued.

## Verification coverage and limits

- `test/IMDOLAR.t.sol`: metadata, mint event and CREATE2 ownership, invalid construction, exact launch distributions, tax events, recipient/caller treatment, full allowance consumption and revocation, zero/dust/max values, self-transfers, rollback after a partial internal burn, privileged-call rejection, runtime opcode checks, and fuzzed conservation/rounding.
- `test/IMDOLAR.v4.t.sol`: a vendored real PoolManager, launch funding and claims, native/ERC-20 pair orderings, taxed buys and successful untaxed sells, factory/distributor recipients, exact-output semantics, taxed liquidity removal, insufficient net output rollback, and unfunded settlement failure.
- `test/IMDOLAR.invariant.t.sol`: random sequences of buys, sells, and wallet transfers with an independent burn ledger; live balances equal current supply and live supply plus burns equals initial supply.

The supplied protected test was read as the acceptance reference. It is an external harness requiring launch environment values and network-owned `LaunchLiquidity`, `PoolInitializationGuard`, and `HookFlags` contracts that are not supplied in this repository. It is not copied, modified, or represented as having run here. Local integration tests exercise its relevant token flows with stricter tax assertions; the independent verifier must still run the actual protected harness against the final manifest.

The security review considered access control, balance/allowance accounting, rounding, overflow, external calls, and administrative surface. Token transfers make no external calls, use OpenZeppelin's ERC-20 accounting, and have no callbacks or user-controlled execution. Reverts roll back both the burn and allowance spending. There is no oracle, signature flow, proxy, or randomness. Foundry tests are not an independent security audit; Slither and Mythril were not run. A separate adversarial review remains a release responsibility.

Dependency revisions, upstream licenses, and SHA-256 hashes are recorded in [`lib/VENDORED.json`](lib/VENDORED.json). Only the transitive source files needed by the token and tests are vendored. OpenZeppelin v5.1.0 supplies the ERC-20 implementation; forge-std v1.9.7 supplies test helpers. The v4 and Solmate sources are used by the local integration tests, not deployed by this project.
