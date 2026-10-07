// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDOLAR} from "../src/IMDOLAR.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";

/// @dev A v4 account that can settle a DOLAR delta every way the manager allows: as an ERC-20
/// transfer to its wallet, as an ERC-6909 claim kept inside the manager, by netting it against a
/// second swap in the same unlock, or as a liquidity position. The launch factory is one of these
/// too, so the token's supply is minted to it.
contract FlowActor is IUnlockCallback {
    enum Op {
        WalletBuy,
        WalletSell,
        ClaimBuy,
        ClaimSell,
        ClaimWithdraw,
        NettedRoundTrip,
        AddLiquidity,
        RemoveLiquidity
    }

    int24 public constant LOWER = -600;
    int24 public constant UPPER = 0;

    IPoolManager public immutable manager;
    address private immutable controller = msg.sender;
    PoolKey private key;

    constructor(IPoolManager manager_, PoolKey memory key_) {
        manager = manager_;
        key = key_;
    }

    receive() external payable {}

    modifier onlyController() {
        require(msg.sender == controller, "controller only");
        _;
    }

    function deployToken() external onlyController returns (IMDOLAR) {
        return new IMDOLAR(address(manager));
    }

    function setKey(PoolKey memory key_) external onlyController {
        key = key_;
    }

    function move(IMDOLAR token, address to, uint256 amount) external onlyController {
        require(token.transfer(to, amount));
    }

    /// @return delta The combined pool delta the operation produced for this actor.
    function run(Op op, uint256 amount) external onlyController returns (BalanceDelta delta) {
        return abi.decode(manager.unlock(abi.encode(op, amount)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (Op op, uint256 amount) = abi.decode(data, (Op, uint256));
        uint256 id = key.currency1.toId();
        BalanceDelta d;
        if (op == Op.WalletBuy) {
            d = _swap(true, amount);
            _payEth(d.amount0());
            _take(key.currency1, d.amount1());
        } else if (op == Op.WalletSell) {
            d = _swap(false, amount);
            _payDolar(d.amount1());
            _take(key.currency0, d.amount0());
        } else if (op == Op.ClaimBuy) {
            d = _swap(true, amount);
            _payEth(d.amount0());
            if (d.amount1() > 0) manager.mint(address(this), id, uint256(uint128(d.amount1())));
        } else if (op == Op.ClaimSell) {
            manager.burn(address(this), id, amount);
            d = _swap(false, amount);
            // A partial fill leaves part of the burned claim as a positive delta: keep it a claim.
            int256 leftover = int256(amount) + int256(d.amount1());
            if (leftover > 0) manager.mint(address(this), id, uint256(leftover));
            _take(key.currency0, d.amount0());
        } else if (op == Op.ClaimWithdraw) {
            manager.burn(address(this), id, amount);
            manager.take(key.currency1, address(this), amount);
        } else if (op == Op.NettedRoundTrip) {
            BalanceDelta buy = _swap(true, amount);
            BalanceDelta sell = _swap(false, uint256(uint128(buy.amount1())));
            d = buy + sell;
            if (d.amount0() < 0) _payEth(d.amount0());
            else _take(key.currency0, d.amount0());
            if (d.amount1() > 0) manager.mint(address(this), id, uint256(uint128(d.amount1())));
        } else {
            // Fees accrued to the position are netted into the delta, so either side can carry
            // either sign whichever way the liquidity moves.
            int256 liquidityDelta = op == Op.AddLiquidity ? int256(amount) : -int256(amount);
            (d,) = manager.modifyLiquidity(
                key, ModifyLiquidityParams(LOWER, UPPER, liquidityDelta, bytes32(0)), ""
            );
            _payEth(d.amount0());
            _take(key.currency0, d.amount0());
            _payDolar(d.amount1());
            _take(key.currency1, d.amount1());
        }
        return abi.encode(d);
    }

    /// @dev Sells stop at the top of the launch range: above it there is no liquidity, and a sell
    /// that starts there has nothing to sell into and is a zero fill rather than a failure.
    function _swap(bool zeroForOne, uint256 exactIn) private returns (BalanceDelta) {
        if (exactIn == 0) return BalanceDelta.wrap(0);
        uint160 limit =
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.getSqrtPriceAtTick(UPPER);
        try manager.swap(key, SwapParams(zeroForOne, -int256(exactIn), limit), "") returns (
            BalanceDelta d
        ) {
            return d;
        } catch (bytes memory reason) {
            if (bytes4(reason) != Pool.PriceLimitAlreadyExceeded.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            return BalanceDelta.wrap(0);
        }
    }

    function _take(Currency currency, int128 delta) private {
        if (delta > 0) manager.take(currency, address(this), uint256(uint128(delta)));
    }

    function _payEth(int128 delta) private {
        if (delta < 0) manager.settle{value: uint256(-int256(delta))}();
    }

    function _payDolar(int128 delta) private {
        if (delta < 0) {
            manager.sync(key.currency1);
            require(
                IMDOLAR(Currency.unwrap(key.currency1))
                    .transfer(address(manager), uint256(-int256(delta)))
            );
            manager.settle();
        }
    }
}

/// @dev Random v4 flows against a real PoolManager, beyond plain wallet-settled swaps: third-party
/// liquidity in and out, ERC-6909 claim buys, sells and withdrawals, and round trips netted inside
/// one unlock. Keeps a ledger of the manager's DOLAR built from pool deltas, of outstanding claims,
/// and of what left the manager as ERC-20 against what arrived, so the invariants compare the token
/// against a model rather than against itself.
contract V4FlowsHandler is Test {
    IMDOLAR public immutable token;
    PoolManager public immutable manager;
    PoolKey internal key;
    FlowActor[3] public actors;

    uint256 public ghostManagerDolar; // model of the manager's ERC-20 DOLAR balance
    uint256 public ghostClaims; // DOLAR owed to actors as ERC-6909 claims
    uint256 public ghostBurned; // what left the manager as ERC-20 minus what arrived
    uint256 public ghostWalletGross; // gross DOLAR of wallet-settled buys
    uint256 public ghostWalletNet; // what those buyers were credited
    mapping(address => uint256) public liquidity;
    uint256 public lastSupply;

    constructor(IMDOLAR token_, PoolManager manager_, PoolKey memory key_) {
        token = token_;
        manager = manager_;
        key = key_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = new FlowActor(manager_, key_);
        }
    }

    function snapshot() external {
        ghostManagerDolar = token.balanceOf(address(manager));
        lastSupply = token.totalSupply();
    }

    modifier supplyNeverGrows() {
        _;
        uint256 now_ = token.totalSupply();
        assertLe(now_, lastSupply, "total supply grew");
        lastSupply = now_;
    }

    /// @dev ETH in, DOLAR out to the buyer's wallet: the ordinary taxed buy.
    function walletBuy(uint256 seed, uint256 ethIn) external supplyNeverGrows {
        FlowActor actor = _actor(seed);
        if (address(actor).balance == 0) return;
        ethIn = bound(ethIn, 1, address(actor).balance);
        uint256 before = token.balanceOf(address(actor));
        BalanceDelta d = actor.run(FlowActor.Op.WalletBuy, ethIn);
        uint256 gross = _positive(d.amount1());
        uint256 delivered = token.balanceOf(address(actor)) - before;
        assertLe(delivered * 100, gross, "a wallet buyer kept more than one percent");
        ghostManagerDolar -= gross;
        ghostBurned += gross - delivered;
        ghostWalletGross += gross;
        ghostWalletNet += delivered;
    }

    /// @dev DOLAR in from the wallet, ETH out. Sells are not buys and must arrive whole.
    function walletSell(uint256 seed, uint256 amount) external supplyNeverGrows {
        FlowActor actor = _actor(seed);
        uint256 held = token.balanceOf(address(actor));
        if (held == 0) return;
        amount = bound(amount, 1, held);
        uint256 managerBefore = token.balanceOf(address(manager));
        BalanceDelta d = actor.run(FlowActor.Op.WalletSell, amount);
        uint256 sold = _negative(d.amount1());
        assertLe(sold, amount, "the swap took more DOLAR than specified");
        assertEq(held - token.balanceOf(address(actor)), sold, "seller lost != sold");
        assertEq(token.balanceOf(address(manager)) - managerBefore, sold, "a sell arrived short");
        ghostManagerDolar += sold;
    }

    /// @dev ETH in, DOLAR kept as an ERC-6909 claim inside the manager. The ledger records what
    /// the manager now owes; whether this buy is taxed is reported separately, not asserted here.
    function claimBuy(uint256 seed, uint256 ethIn) external supplyNeverGrows {
        FlowActor actor = _actor(seed);
        if (address(actor).balance == 0) return;
        ethIn = bound(ethIn, 1, address(actor).balance);
        uint256 claimsBefore = manager.balanceOf(address(actor), key.currency1.toId());
        BalanceDelta d = actor.run(FlowActor.Op.ClaimBuy, ethIn);
        uint256 gross = _positive(d.amount1());
        assertEq(
            manager.balanceOf(address(actor), key.currency1.toId()) - claimsBefore,
            gross,
            "the claim does not match the swap output"
        );
        ghostClaims += gross;
    }

    /// @dev Burn part of a claim and sell it for ETH inside the manager.
    function claimSell(uint256 seed, uint256 amount) external supplyNeverGrows {
        FlowActor actor = _actor(seed);
        uint256 claims = manager.balanceOf(address(actor), key.currency1.toId());
        if (claims == 0) return;
        amount = bound(amount, 1, claims);
        uint256 managerBefore = token.balanceOf(address(manager));
        BalanceDelta d = actor.run(FlowActor.Op.ClaimSell, amount);
        uint256 sold = _negative(d.amount1());
        assertLe(sold, amount, "the swap took more than the burned claim");
        assertEq(
            claims - manager.balanceOf(address(actor), key.currency1.toId()),
            sold,
            "claims burned != DOLAR sold"
        );
        assertEq(token.balanceOf(address(manager)), managerBefore, "a claim sell moved ERC-20");
        ghostClaims -= sold;
    }

    /// @dev Burn a claim and take the DOLAR out as ERC-20: a manager outflow.
    function claimWithdraw(uint256 seed, uint256 amount) external supplyNeverGrows {
        FlowActor actor = _actor(seed);
        uint256 claims = manager.balanceOf(address(actor), key.currency1.toId());
        if (claims == 0) return;
        amount = bound(amount, 1, claims);
        uint256 before = token.balanceOf(address(actor));
        uint256 managerBefore = token.balanceOf(address(manager));
        actor.run(FlowActor.Op.ClaimWithdraw, amount);
        uint256 delivered = token.balanceOf(address(actor)) - before;
        assertEq(managerBefore - token.balanceOf(address(manager)), amount, "manager lost != claim");
        assertLe(delivered, amount, "a withdrawal delivered more than the claim");
        ghostClaims -= amount;
        ghostManagerDolar -= amount;
        ghostBurned += amount - delivered;
    }

    /// @dev Buy and sell back inside one unlock. Only ETH and claims can change hands.
    function nettedRoundTrip(uint256 seed, uint256 ethIn) external supplyNeverGrows {
        FlowActor actor = _actor(seed);
        if (address(actor).balance == 0) return;
        ethIn = bound(ethIn, 1, address(actor).balance);
        uint256 dolarBefore = token.balanceOf(address(actor));
        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 claimsBefore = manager.balanceOf(address(actor), key.currency1.toId());
        BalanceDelta d = actor.run(FlowActor.Op.NettedRoundTrip, ethIn);
        uint256 leftover = _positive(d.amount1());
        assertEq(token.balanceOf(address(actor)), dolarBefore, "a netted trip moved wallet DOLAR");
        assertEq(token.balanceOf(address(manager)), managerBefore, "a netted trip moved ERC-20");
        assertEq(
            manager.balanceOf(address(actor), key.currency1.toId()) - claimsBefore,
            leftover,
            "the unsold remainder was not kept as a claim"
        );
        ghostClaims += leftover;
    }

    /// @dev A third party deposits DOLAR and ETH into the launch range. Deposits arrive whole;
    /// fees already earned by the position are netted into the delta and may make it an outflow.
    function addLiquidity(uint256 seed, uint256 amount) external supplyNeverGrows {
        FlowActor actor = _actor(seed);
        uint256 dolar = token.balanceOf(address(actor));
        uint256 eth = address(actor).balance;
        if (dolar == 0 || eth == 0) return;
        // In [-600, 0] a unit of liquidity needs under 0.0305 of each asset at any in-range price.
        uint256 cap = (dolar < eth ? dolar : eth) * 30;
        amount = bound(amount, 1, cap);
        uint256 managerBefore = token.balanceOf(address(manager));
        BalanceDelta d = actor.run(FlowActor.Op.AddLiquidity, amount);
        _recordDolarDelta(actor, d.amount1(), dolar, managerBefore);
        liquidity[address(actor)] += amount;
    }

    /// @dev The same third party withdraws. The pool pays principal plus fees out through `take`;
    /// the ledger records what left the manager and what arrived.
    function removeLiquidity(uint256 seed, uint256 amount) external supplyNeverGrows {
        FlowActor actor = _actor(seed);
        uint256 held = liquidity[address(actor)];
        if (held == 0) return;
        amount = bound(amount, 1, held);
        uint256 before = token.balanceOf(address(actor));
        uint256 managerBefore = token.balanceOf(address(manager));
        BalanceDelta d = actor.run(FlowActor.Op.RemoveLiquidity, amount);
        _recordDolarDelta(actor, d.amount1(), before, managerBefore);
        liquidity[address(actor)] -= amount;
    }

    /// @dev Checks a DOLAR pool delta against the real ERC-20 movements and records it: an inflow
    /// must arrive whole, an outflow leaves the manager at its gross and arrives at whatever the
    /// token delivered.
    function _recordDolarDelta(
        FlowActor actor,
        int128 delta,
        uint256 actorBefore,
        uint256 managerBefore
    ) private {
        uint256 actorNow = token.balanceOf(address(actor));
        uint256 managerNow = token.balanceOf(address(manager));
        if (delta < 0) {
            uint256 paid = _negative(delta);
            assertEq(actorBefore - actorNow, paid, "LP paid != owed");
            assertEq(managerNow - managerBefore, paid, "a deposit arrived short");
            ghostManagerDolar += paid;
        } else {
            uint256 gross = _positive(delta);
            uint256 delivered = actorNow - actorBefore;
            assertEq(managerBefore - managerNow, gross, "manager lost != owed");
            assertLe(delivered, gross, "an outflow delivered more than the pool owed");
            ghostManagerDolar -= gross;
            ghostBurned += gross - delivered;
        }
    }

    /// @dev Wallet-to-wallet moves between actors are untaxed and exact.
    function walletTransfer(uint256 seed, uint256 amount) external supplyNeverGrows {
        FlowActor from = _actor(seed);
        address to = address(_actor(seed / actors.length));
        amount = bound(amount, 0, token.balanceOf(address(from)));
        uint256 toBefore = token.balanceOf(to);
        from.move(token, to, amount);
        if (address(from) != to) {
            assertEq(token.balanceOf(to) - toBefore, amount, "a wallet transfer arrived short");
        }
    }

    function claimsOutstanding() external view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += manager.balanceOf(address(actors[i]), key.currency1.toId());
        }
    }

    function _actor(uint256 seed) private view returns (FlowActor) {
        return actors[seed % actors.length];
    }

    function _positive(int128 delta) private pure returns (uint256) {
        return delta > 0 ? uint256(uint128(delta)) : 0;
    }

    function _negative(int128 delta) private pure returns (uint256) {
        return delta < 0 ? uint256(-int256(delta)) : 0;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 40
contract IMDOLARV4FlowsInvariantTest is Test {
    PoolManager internal manager;
    FlowActor internal factory;
    IMDOLAR internal token;
    V4FlowsHandler internal handler;
    PoolKey internal key;
    address internal constant DISTRIBUTOR = address(0xD157);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new FlowActor(manager, key);
        token = factory.deployToken();
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0))
        );
        factory.setKey(key);
        handler = new V4FlowsHandler(token, manager, key);

        // Launch flows: swarm share out, single-sided seed at the opening price, remainder split
        // among the actors so that every flow has DOLAR to work with.
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        manager.initialize(key, uint160(1 << 96));
        BalanceDelta seed = factory.run(FlowActor.Op.AddLiquidity, 100_000_000 ether);
        assertEq(seed.amount0(), 0, "the seed must be single sided");
        uint256 remainder = token.balanceOf(address(factory));
        for (uint256 i; i < 3; ++i) {
            factory.move(token, address(handler.actors(i)), remainder / 3);
            vm.deal(address(handler.actors(i)), 50 ether);
        }
        factory.move(token, address(handler.actors(0)), token.balanceOf(address(factory)));
        handler.snapshot();

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = V4FlowsHandler.walletBuy.selector;
        selectors[1] = V4FlowsHandler.walletSell.selector;
        selectors[2] = V4FlowsHandler.claimBuy.selector;
        selectors[3] = V4FlowsHandler.claimSell.selector;
        selectors[4] = V4FlowsHandler.claimWithdraw.selector;
        selectors[5] = V4FlowsHandler.nettedRoundTrip.selector;
        selectors[6] = V4FlowsHandler.addLiquidity.selector;
        selectors[7] = V4FlowsHandler.removeLiquidity.selector;
        selectors[8] = V4FlowsHandler.walletTransfer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev Every DOLAR is in the manager, an actor's wallet, or the untouched swarm share.
    function invariant_DolarIsConserved() public view {
        uint256 sum = token.balanceOf(address(manager)) + token.balanceOf(DISTRIBUTOR);
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(address(handler.actors(i)));
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10, "the swarm share moved");
    }

    /// @dev The supply never exceeds the mint, and the only thing that ever leaves it is the gap
    /// between what left the manager as ERC-20 and what arrived.
    function invariant_SupplyIsMintMinusManagerOutflowGap() public view {
        assertLe(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply() + handler.ghostBurned(), SUPPLY);
    }

    /// @dev The manager's ERC-20 DOLAR equals the ledger built from pool deltas: sells and
    /// deposits in full, swap output, withdrawals and claim exits at their gross amount.
    function invariant_ManagerDolarMatchesDeltaLedger() public view {
        assertEq(token.balanceOf(address(manager)), handler.ghostManagerDolar());
    }

    /// @dev Every ERC-6909 DOLAR claim is backed by ERC-20 DOLAR the manager actually holds, and
    /// the claims outstanding are exactly those the ledger issued.
    function invariant_ClaimsAreBackedAndAccounted() public view {
        uint256 claims = handler.claimsOutstanding();
        assertEq(claims, handler.ghostClaims(), "claims outstanding != ledger");
        assertLe(claims, token.balanceOf(address(manager)), "claims exceed manager DOLAR");
    }

    /// @dev Across every wallet-settled buy, buyers kept at most 1% of what the pool paid out.
    function invariant_WalletBuyersKeepAtMostOnePercent() public view {
        assertLe(handler.ghostWalletNet() * 100, handler.ghostWalletGross());
    }

    /// @dev No sequence of calls changes the taxed source or the metadata.
    function invariant_ConfigurationIsFixed() public view {
        assertEq(token.poolManager(), address(manager));
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }
}
