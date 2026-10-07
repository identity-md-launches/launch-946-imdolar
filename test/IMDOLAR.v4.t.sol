// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
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

/// @dev Test-only paired asset; never deployed as part of the project.
contract TestPairToken is ERC20 {
    constructor() ERC20("Test pair", "PAIR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Test-only factory/trader. Settles real v4 deltas, without forks or environment configuration.
contract V4Actor is IUnlockCallback {
    IPoolManager public immutable manager;
    address private immutable controller = msg.sender;
    PoolKey private key;

    modifier onlyController() {
        require(msg.sender == controller, "controller only");
        _;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function deployToken() external onlyController returns (IMDOLAR) {
        return new IMDOLAR(address(manager));
    }

    function move(IMDOLAR token, address to, uint256 amount) external onlyController {
        require(token.transfer(to, amount));
    }

    function seed(PoolKey memory key_, int24 lower, int24 upper, int256 liquidity)
        external
        onlyController
        returns (BalanceDelta)
    {
        key = key_;
        bytes memory result = manager.unlock(
            abi.encode(
                false, abi.encode(ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)))
            )
        );
        return abi.decode(result, (BalanceDelta));
    }

    function swap(
        PoolKey memory key_,
        bool zeroForOne,
        int256 amount,
        address recipient,
        uint256 minNet
    ) external onlyController returns (BalanceDelta) {
        key = key_;
        bytes memory result =
            manager.unlock(abi.encode(true, abi.encode(zeroForOne, amount, recipient, minNet)));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool isSwap, bytes memory params) = abi.decode(data, (bool, bytes));
        BalanceDelta delta;
        if (isSwap) {
            (bool zeroForOne, int256 amount, address recipient, uint256 minNet) =
                abi.decode(params, (bool, int256, address, uint256));
            Currency output = zeroForOne ? key.currency1 : key.currency0;
            uint256 before = output.balanceOf(recipient);
            delta = manager.swap(
                key,
                SwapParams(
                    zeroForOne,
                    amount,
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
            _settle(key.currency0, delta.amount0(), recipient);
            _settle(key.currency1, delta.amount1(), recipient);
            require(output.balanceOf(recipient) - before >= minNet, "insufficient net output");
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
            _settle(key.currency0, delta.amount0(), address(this));
            _settle(key.currency1, delta.amount1(), address(this));
        }
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address recipient) private {
        if (delta > 0) {
            manager.take(currency, recipient, uint256(uint128(delta)));
        } else if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                require(manager.settle{value: owed}() == owed, "native settlement short");
            } else {
                manager.sync(currency);
                require(ERC20(Currency.unwrap(currency)).transfer(address(manager), owed));
                require(manager.settle() == owed, "token settlement short");
            }
        }
    }
}

/// @dev Test-only trader that settles the DOLAR side of a swap inside the manager: a buy is kept as
/// an ERC-6909 claim, a sell is paid by burning that claim, and a withdrawal is the only step that
/// moves DOLAR out of the manager as an ERC-20 transfer. Pins the scope limit of a transfer tax.
contract ClaimActor is IUnlockCallback {
    enum Action {
        ClaimBuy,
        ClaimSell,
        Withdraw,
        NettedRoundTrip
    }

    IPoolManager public immutable manager;
    address private immutable controller = msg.sender;
    PoolKey private key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function act(PoolKey memory key_, Action action, uint256 amount) external returns (uint256) {
        require(msg.sender == controller, "controller only");
        key = key_;
        return abi.decode(manager.unlock(abi.encode(action, amount)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (Action action, uint256 amount) = abi.decode(data, (Action, uint256));
        uint256 id = key.currency1.toId();
        uint256 result;
        if (action == Action.ClaimBuy) {
            BalanceDelta d = manager.swap(
                key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), ""
            );
            manager.settle{value: uint256(uint128(-d.amount0()))}();
            result = uint256(uint128(d.amount1()));
            manager.mint(address(this), id, result);
        } else if (action == Action.ClaimSell) {
            manager.burn(address(this), id, amount);
            BalanceDelta d = manager.swap(
                key, SwapParams(false, -int256(amount), TickMath.MAX_SQRT_PRICE - 1), ""
            );
            result = uint256(uint128(d.amount0()));
            manager.take(key.currency0, address(this), result);
        } else if (action == Action.Withdraw) {
            manager.burn(address(this), id, amount);
            manager.take(key.currency1, address(this), amount);
            result = amount;
        } else {
            // Buy, then sell the whole gross output inside the same unlock. The DOLAR delta nets
            // to zero, so only the ETH difference is settled and the token is never called.
            BalanceDelta bought = manager.swap(
                key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), ""
            );
            result = uint256(uint128(bought.amount1()));
            BalanceDelta sold = manager.swap(
                key, SwapParams(false, -int256(result), TickMath.MAX_SQRT_PRICE - 1), ""
            );
            int256 ethDelta = int256(bought.amount0()) + int256(sold.amount0());
            if (ethDelta < 0) manager.settle{value: uint256(-ethDelta)}();
            else if (ethDelta > 0) manager.take(key.currency0, address(this), uint256(ethDelta));
        }
        return abi.encode(result);
    }
}

contract IMDOLARV4Test is Test {
    PoolManager internal manager;
    V4Actor internal factory;
    V4Actor internal trader;
    IMDOLAR internal token;
    PoolKey internal key;
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant REQUESTER = address(0x1234);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    int256 internal constant LIQUIDITY = 100_000_000 ether;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new V4Actor(manager);
        trader = new V4Actor(manager);
        token = factory.deployToken();
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0))
        );
        vm.deal(address(trader), 10 ether);
    }

    function test_NativeLaunchClaimSeedBuyAndSell() public {
        _launchAndRoundTrip(address(0));
    }

    function test_ERC20PairLowerThanTokenLaunchBuyAndSell() public {
        _launchAndRoundTrip(address(0x100));
    }

    function test_ERC20PairHigherThanTokenLaunchBuyAndSell() public {
        _launchAndRoundTrip(address(type(uint160).max - 1));
    }

    function test_RealSwapsToFactoryAndDistributorStillPayTax() public {
        _seed();
        address[2] memory recipients = [address(factory), DISTRIBUTOR];
        uint256 burned;
        for (uint256 i; i < recipients.length; ++i) {
            uint256 before = token.balanceOf(recipients[i]);
            BalanceDelta delta = trader.swap(key, true, -0.01 ether, recipients[i], 1);
            uint256 gross = uint256(uint128(delta.amount1()));
            assertGt(gross, 0);
            assertEq(token.balanceOf(recipients[i]) - before, gross / 100);
            burned += gross - gross / 100;
        }
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function test_GrossMinimumOutputRevertsSwapAndBurnAtomically() public {
        _seed();
        uint256 poolBefore = token.balanceOf(address(manager));
        uint256 ethBefore = address(trader).balance;
        // A router expecting almost the entire gross quote must fail against a 99% tax.
        vm.expectRevert(bytes("insufficient net output"));
        trader.swap(key, true, -0.01 ether, address(trader), 0.009 ether);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(manager)), poolBefore);
        assertEq(address(trader).balance, ethBefore);
        // Prove manager accounting/lock was rolled back and a properly quoted swap still works.
        trader.swap(key, true, -0.01 ether, address(trader), 1);
        assertGt(token.balanceOf(address(trader)), 0);
    }

    function test_ExactOutputIsGrossAndStillTaxed() public {
        _seed();
        BalanceDelta delta = trader.swap(key, true, 0.01 ether, address(trader), 0.0001 ether);
        assertEq(delta.amount1(), int128(0.01 ether));
        assertEq(token.balanceOf(address(trader)), 0.0001 ether);
        assertEq(token.totalSupply(), SUPPLY - 0.0099 ether);
    }

    function test_LiquidityWithdrawalAlsoPaysTax() public {
        _seed();
        uint256 before = token.balanceOf(address(factory));
        BalanceDelta delta = factory.seed(key, -600, 0, -LIQUIDITY);
        uint256 gross = uint256(uint128(delta.amount1()));
        assertGt(gross, 0);
        assertEq(token.balanceOf(address(factory)) - before, gross / 100);
        assertEq(token.totalSupply(), SUPPLY - (gross - gross / 100));
    }

    /// @dev Scope limit, pinned on purpose: a buy whose DOLAR output stays inside the manager as an
    /// ERC-6909 claim never calls the token, so a transfer-source tax cannot see it. The tax is
    /// charged when the claim is withdrawn as an ERC-20 transfer; a claim sold back inside the
    /// manager is never taxed. Closing this needs a taxing hook on the pool key, which the launch
    /// pool does not carry. See README, "Scope limits that need requester sign-off".
    function test_ClaimSettledBuyIsOutsideTheTransferTaxUntilWithdrawn() public {
        _seed();
        ClaimActor claimant = new ClaimActor(manager);
        vm.deal(address(claimant), 1 ether);
        uint256 id = key.currency1.toId();

        uint256 gross = claimant.act(key, ClaimActor.Action.ClaimBuy, 0.01 ether);
        assertGt(gross, 0);
        assertEq(manager.balanceOf(address(claimant), id), gross, "claim is the untaxed gross");
        assertEq(token.balanceOf(address(claimant)), 0);
        assertEq(token.totalSupply(), SUPPLY, "the token was never called");

        // Selling part of the claim back inside the manager is untaxed: still no token call.
        uint256 sold = gross / 2;
        uint256 ethBefore = address(claimant).balance;
        claimant.act(key, ClaimActor.Action.ClaimSell, sold);
        assertGt(address(claimant).balance, ethBefore);
        assertEq(token.totalSupply(), SUPPLY);

        // Withdrawing the rest as ERC-20 is a manager outflow and pays the 99% there.
        uint256 rest = gross - sold;
        claimant.act(key, ClaimActor.Action.Withdraw, rest);
        assertEq(manager.balanceOf(address(claimant), id), 0);
        assertEq(token.balanceOf(address(claimant)), rest / 100);
        assertEq(token.totalSupply(), SUPPLY - (rest - rest / 100));
    }

    /// @dev Scope limit, pinned on purpose: a buy and a sell of the full gross output inside one
    /// unlock net the DOLAR delta to zero. No DOLAR leaves the manager, the token is never called,
    /// and the round trip costs only the pool's LP fee. See README, "Scope limits".
    function test_NettedRoundTripInsideOneUnlockIsOutsideTheTransferTax() public {
        _seed();
        ClaimActor claimant = new ClaimActor(manager);
        vm.deal(address(claimant), 1 ether);
        uint256 managerBefore = token.balanceOf(address(manager));

        uint256 gross = claimant.act(key, ClaimActor.Action.NettedRoundTrip, 0.01 ether);
        assertGt(gross, 0);

        assertEq(token.balanceOf(address(claimant)), 0);
        assertEq(manager.balanceOf(address(claimant), key.currency1.toId()), 0);
        assertEq(token.balanceOf(address(manager)), managerBefore, "no DOLAR left the manager");
        assertEq(token.totalSupply(), SUPPLY, "the token was never called");
        // Two 0.3% LP fees on 0.01 ETH: the round trip is nearly free instead of losing 99%.
        uint256 cost = 1 ether - address(claimant).balance;
        assertLt(cost, 0.0001 ether, "round trip cost more than the LP fees");
    }

    /// @dev Scope limit, pinned on purpose: Uniswap protocol-fee collection is a manager outflow,
    /// so the fee recipient receives 1% of the DOLAR accrued and 99% is burned, while the manager
    /// clears the full accrued amount. See README, "Scope limits".
    function test_ProtocolFeeCollectionIsTaxedAsAManagerOutflow() public {
        _seed();
        // This test contract owns the local manager; the real controller is Uniswap governance.
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1_000) | (uint24(1_000) << 12));

        // A buy, then a sell of the net output: the sell's input is DOLAR, so DOLAR fees accrue.
        trader.swap(key, true, -0.01 ether, address(trader), 1);
        uint256 bought = token.balanceOf(address(trader));
        trader.swap(key, false, -int256(bought), address(trader), 1);
        uint256 accrued = manager.protocolFeesAccrued(key.currency1);
        assertGt(accrued, 100, "no DOLAR protocol fee accrued");

        address recipient = address(0xFEE);
        uint256 supplyBefore = token.totalSupply();
        uint256 collected = manager.collectProtocolFees(recipient, key.currency1, 0);
        assertEq(collected, accrued, "the manager clears the full accrued amount");
        assertEq(manager.protocolFeesAccrued(key.currency1), 0);
        assertEq(token.balanceOf(recipient), accrued / 100, "recipient receives 1%");
        assertEq(token.totalSupply(), supplyBefore - (accrued - accrued / 100), "99% burned");
    }

    /// @dev Scope limit, pinned on purpose: the rule is "from == poolManager", so a third party's
    /// liquidity withdrawal is taxed like a buy even with no swap in between, and the 99% is
    /// burned. DOLAR liquidity on the launch pool is one-way for every LP, the factory's seed
    /// position included (test_LiquidityWithdrawalAlsoPaysTax). See README, "Scope limits".
    function test_ThirdPartyLiquidityWithdrawalIsTaxedAsAManagerOutflow() public {
        _seed();
        V4Actor lp = new V4Actor(manager);
        factory.move(token, address(lp), 1_000 ether);
        vm.deal(address(lp), 10 ether);

        BalanceDelta added = lp.seed(key, -600, 600, 10 ether);
        uint256 deposited = uint256(-int256(added.amount1()));
        assertGt(deposited, 0);
        assertEq(token.balanceOf(address(lp)), 1_000 ether - deposited, "deposit arrived short");
        assertEq(token.totalSupply(), SUPPLY);

        BalanceDelta removed = lp.seed(key, -600, 600, -10 ether);
        uint256 owed = uint256(uint128(removed.amount1()));
        assertGe(owed + 1, deposited, "the pool owes the principal back");
        assertEq(token.balanceOf(address(lp)), 1_000 ether - deposited + owed / 100);
        assertEq(token.totalSupply(), SUPPLY - (owed - owed / 100));
    }

    function test_UnfundedSellFailsWithoutChangingSupply() public {
        _seed();
        // Move into the liquidity range and fund the paired reserve. Send the bought tokens to
        // another account so the trader still cannot pay the token debt of its subsequent sell.
        trader.swap(key, true, -0.01 ether, REQUESTER, 1);
        assertEq(token.balanceOf(address(trader)), 0);
        uint256 supplyBefore = token.totalSupply();
        uint256 poolBefore = token.balanceOf(address(manager));
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        trader.swap(key, false, -1 ether, address(trader), 0);
        assertEq(token.balanceOf(address(manager)), poolBefore);
        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_CallbackRejectsUntrustedCaller() public {
        vm.expectRevert(bytes("manager only"));
        trader.unlockCallback("");
    }

    function _launchAndRoundTrip(address paired) private {
        if (paired != address(0)) {
            // Deterministic test addresses exercise both currency orderings. No live chain is used.
            vm.etch(paired, address(new TestPairToken()).code);
            TestPairToken(paired).mint(address(trader), 10 ether);
        }
        bool pairIsZero = paired < address(token);
        key = PoolKey(
            Currency.wrap(pairIsZero ? paired : address(token)),
            Currency.wrap(pairIsZero ? address(token) : paired),
            3000,
            60,
            IHooks(address(0))
        );

        assertEq(token.balanceOf(address(factory)), SUPPLY);
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT, SUPPLY / 10);
        assertEq(token.balanceOf(CLAIMANT), SUPPLY / 10);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);

        manager.initialize(key, uint160(1 << 96));
        uint256 beforeSeed = token.balanceOf(address(factory));
        factory.seed(
            key, pairIsZero ? int24(-600) : int24(0), pairIsZero ? int24(0) : int24(600), LIQUIDITY
        );
        uint256 seeded = beforeSeed - token.balanceOf(address(factory));
        assertGt(seeded, 0);
        assertLe(seeded, SUPPLY * 8 / 10);
        assertEq(token.balanceOf(address(manager)), seeded);
        factory.move(token, REQUESTER, token.balanceOf(address(factory)));
        assertEq(token.balanceOf(REQUESTER), SUPPLY * 9 / 10 - seeded);
        assertEq(token.totalSupply(), SUPPLY);

        BalanceDelta buy = trader.swap(key, pairIsZero, -0.01 ether, address(trader), 1);
        int128 tokenOut = pairIsZero ? buy.amount1() : buy.amount0();
        assertGt(int256(tokenOut), 0);
        uint256 gross = uint256(uint128(tokenOut));
        uint256 bought = token.balanceOf(address(trader));
        assertEq(bought, gross / 100);
        assertGt(bought, 0);
        assertEq(token.balanceOf(address(manager)), seeded - gross);
        uint256 afterBuySupply = token.totalSupply();
        assertEq(afterBuySupply, SUPPLY - gross + bought);

        Currency pairCurrency = Currency.wrap(paired);
        uint256 pairBefore = pairCurrency.balanceOf(address(trader));
        trader.swap(key, !pairIsZero, -int256(bought), address(trader), 1);
        assertGt(pairCurrency.balanceOf(address(trader)), pairBefore);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(manager)), seeded - gross + bought);
        assertEq(token.totalSupply(), afterBuySupply);
        assertEq(
            token.balanceOf(CLAIMANT) + token.balanceOf(REQUESTER)
                + token.balanceOf(address(manager)),
            token.totalSupply()
        );
    }

    function _seed() private {
        manager.initialize(key, uint160(1 << 96));
        factory.seed(key, -600, 0, LIQUIDITY);
    }
}
