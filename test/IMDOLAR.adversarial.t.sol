// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDOLAR} from "../src/IMDOLAR.sol";
import {PoolSource} from "./IMDOLAR.t.sol";
import {V4Actor} from "./IMDOLAR.v4.t.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev A v4 integrator that settles its DOLAR as ERC-6909 claims and later withdraws them.
/// Used to show that the tax is charged at the moment DOLAR leaves the manager as ERC-20.
contract ClaimExitActor is IUnlockCallback {
    enum Mode {
        BuyToClaims,
        ExitClaims
    }

    IPoolManager public immutable manager;
    address private immutable controller = msg.sender;
    PoolKey private key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function run(PoolKey memory key_, Mode mode, uint256 amount) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        key = key_;
        return abi.decode(manager.unlock(abi.encode(mode, amount)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (Mode mode, uint256 amount) = abi.decode(data, (Mode, uint256));
        uint256 dolarId = key.currency1.toId();
        BalanceDelta delta;
        if (mode == Mode.BuyToClaims) {
            delta = manager.swap(
                key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), ""
            );
            manager.settle{value: uint256(uint128(-delta.amount0()))}();
            manager.mint(address(this), dolarId, uint256(uint128(delta.amount1())));
        } else {
            manager.burn(address(this), dolarId, amount);
            manager.take(key.currency1, address(this), amount);
        }
        return abi.encode(delta);
    }
}

/// @notice Adversarial inputs the implementer's suite did not pin: arbitrary callers and
/// recipients, algebraic bounds on the tax instead of its own formula, pinned extremes, calls the
/// token must refuse, and the v4 claim exit path.
/// forge-config: default.fuzz.runs = 1000
contract IMDOLARAdversarialTest is Test {
    IMDOLAR internal token;
    PoolSource internal pool;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        pool = new PoolSource();
        token = new IMDOLAR(address(pool));
    }

    // ------------------------------------------------------------------ refused interactions

    function test_TokenRefusesEtherAndUnknownSelectors() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok, "token accepted ether through a receive path");
        (ok,) = address(token).call{value: 1}(abi.encodeWithSignature("deposit()"));
        assertFalse(ok, "token accepted ether through a fallback path");
        (ok,) = address(token).call(abi.encodeWithSignature("collectTax()"));
        assertFalse(ok, "token answered an unknown selector");
        (ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "token exposes an owner");
        assertEq(address(token).balance, 0);
    }

    function test_PrecompileAndFreshContractAddressesAreNotValidManagers() public {
        // Precompiles and not-yet-deployed CREATE addresses have no code; both must be refused.
        _rejectManager(address(0x1));
        _rejectManager(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5));
    }

    function test_ConstructorWithoutMatchingArgumentsReverts() public {
        // A factory that forgets the manager argument must fail loudly, not deploy an untaxed token.
        (bool ok,) = address(this).call(abi.encodeWithSelector(this.deployWithNoArgs.selector));
        assertFalse(ok, "token deployed without a manager argument");
    }

    function deployWithNoArgs() external {
        bytes memory code = type(IMDOLAR).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "constructor reverted");
    }

    // ------------------------------------------------------------------ pinned extremes

    function test_EntireSupplyBoughtInOneTransferLeavesExactlyOnePercent() public {
        token.transfer(address(pool), SUPPLY);
        pool.send(token, ALICE, SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY / 100);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.totalSupply(), SUPPLY / 100);
        assertEq(token.totalSupply(), token.balanceOf(ALICE));
    }

    function test_SmallestTaxableBuyIsOneHundredMinorUnits() public {
        token.transfer(address(pool), 199);
        pool.send(token, ALICE, 99);
        assertEq(token.balanceOf(ALICE), 0, "99 minor units must deliver nothing");
        pool.send(token, ALICE, 100);
        assertEq(token.balanceOf(ALICE), 1, "100 minor units deliver exactly one");
        assertEq(token.totalSupply(), SUPPLY - 198);
    }

    function test_PoolHoldingExactlyTheFeeCannotDeliverTheNet() public {
        token.transfer(address(pool), 99);
        // The fee (99) is burnable, the net (1) is not: the whole transfer must roll back.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(pool), 0, 1
            )
        );
        pool.send(token, ALICE, 100);
        assertEq(token.balanceOf(address(pool)), 99);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FeeLargerThanPoolBalanceRevertsOnTheBurn() public {
        token.transfer(address(pool), 50);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(pool), 50, 99
            )
        );
        pool.send(token, ALICE, 100);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_BuyToDeadAddressStillTaxedAndCountedAsHeld() public {
        token.transfer(address(pool), 100 ether);
        address dead = address(0xdead);
        pool.send(token, dead, 100 ether);
        assertEq(token.balanceOf(dead), 1 ether);
        // Only the fee is burned; tokens sent to 0xdead stay in totalSupply.
        assertEq(token.totalSupply(), SUPPLY - 99 ether);
    }

    // ------------------------------------------------------------------ fuzzed properties

    /// @dev Any sender that is not the manager moves exactly what it says, to anyone, including
    /// itself, the token contract, and the manager.
    function testFuzz_NonManagerTransfersAreExact(uint256 fromSeed, uint256 toSeed, uint256 amount)
        public
    {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(from, amount);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore);
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The spender's identity never changes the tax; only the source does.
    function testFuzz_AnySpenderMovingFromTheManagerIsTaxed(uint256 spenderSeed, uint256 gross)
        public
    {
        address spender = _actor(spenderSeed);
        gross = bound(gross, 1, SUPPLY);
        token.transfer(address(pool), gross);
        pool.approve(token, spender, gross);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(pool), BOB, gross));
        assertEq(token.allowance(address(pool), spender), 0);
        uint256 net = token.balanceOf(BOB);
        // Spec bounds, not the implementation's formula: the buyer keeps at most 1%.
        assertLe(net * 100, gross);
        assertGe((gross - net) * 100, gross * 99);
        assertEq(token.totalSupply(), SUPPLY - (gross - net));
    }

    /// @dev Bigger buys never deliver less: the conversion is monotone.
    function testFuzz_NetDeliveredIsMonotoneInGross(uint256 a, uint256 b) public {
        a = bound(a, 1, SUPPLY / 2);
        b = bound(b, a, SUPPLY / 2);
        token.transfer(address(pool), a + b);
        pool.send(token, ALICE, a);
        pool.send(token, BOB, b);
        assertLe(token.balanceOf(ALICE), token.balanceOf(BOB));
        assertLe(token.balanceOf(BOB) - token.balanceOf(ALICE), (b - a) / 100 + 1);
    }

    /// @dev Repeated small cycles cannot extract more than 1% in total (dust extraction).
    function testFuzz_ManyDustBuysCannotBeatOnePercent(uint256 size, uint8 cycles) public {
        size = bound(size, 1, 1_000);
        uint256 n = bound(cycles, 1, 64);
        token.transfer(address(pool), size * n);
        for (uint256 i; i < n; ++i) {
            pool.send(token, ALICE, size);
        }
        assertLe(token.balanceOf(ALICE) * 100, size * n);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.totalSupply(), SUPPLY - size * n + token.balanceOf(ALICE));
    }

    /// @dev A failed buy must leave no trace: no partial burn, no allowance consumed.
    function testFuzz_FailedBuyIsAtomic(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - held);
        token.transfer(address(pool), held);
        pool.approve(token, address(this), type(uint256).max);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        token.transferFrom(address(pool), ALICE, held + excess);
        assertEq(token.balanceOf(address(pool)), held);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(address(pool), address(this)), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------ real manager paths

    /// @dev DOLAR settled as an ERC-6909 claim is taxed when the claim is withdrawn as ERC-20.
    /// What happens while it stays a claim is reported separately as a finding.
    function test_ClaimWithdrawalThroughTakeIsTaxedAtExit() public {
        PoolManager manager = new PoolManager(address(this));
        V4Actor factory = new V4Actor(manager);
        IMDOLAR launched = factory.deployToken();
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(launched)),
            3000,
            60,
            IHooks(address(0))
        );
        manager.initialize(key, uint160(1 << 96));
        factory.seed(key, -600, 0, 100_000_000 ether);

        ClaimExitActor actor = new ClaimExitActor(manager);
        vm.deal(address(actor), 1 ether);
        BalanceDelta buy = actor.run(key, ClaimExitActor.Mode.BuyToClaims, 0.5 ether);
        uint256 gross = uint256(uint128(buy.amount1()));
        assertGt(gross, 0);
        assertEq(launched.balanceOf(address(actor)), 0);
        uint256 managerBefore = launched.balanceOf(address(manager));

        actor.run(key, ClaimExitActor.Mode.ExitClaims, gross);
        assertEq(launched.balanceOf(address(actor)), gross / 100, "claim exit was not taxed");
        assertEq(launched.balanceOf(address(manager)), managerBefore - gross);
        assertEq(launched.totalSupply(), SUPPLY - (gross - gross / 100));
    }

    /// @dev Buying then selling everything back never leaves the trader with more ETH than it
    /// started with, and leaves it with no DOLAR: no round-trip profit through the taxed pool.
    function test_BuyThenSellBackLosesEthAndHoldsNoDolar() public {
        PoolManager manager = new PoolManager(address(this));
        V4Actor factory = new V4Actor(manager);
        V4Actor trader = new V4Actor(manager);
        IMDOLAR launched = factory.deployToken();
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(launched)),
            3000,
            60,
            IHooks(address(0))
        );
        manager.initialize(key, uint160(1 << 96));
        factory.seed(key, -600, 0, 100_000_000 ether);
        vm.deal(address(trader), 2 ether);

        uint256 ethBefore = address(trader).balance;
        trader.swap(key, true, -1 ether, address(trader), 1);
        uint256 bought = launched.balanceOf(address(trader));
        assertGt(bought, 0);
        trader.swap(key, false, -int256(bought), address(trader), 1);
        assertEq(launched.balanceOf(address(trader)), 0);
        // 99% of the DOLAR leg was burned, so well under 2% of the ETH can come back.
        assertLt(address(trader).balance, ethBefore - 0.98 ether);
        assertLt(launched.totalSupply(), SUPPLY);
    }

    // ------------------------------------------------------------------ helpers

    function _actor(uint256 seed) private view returns (address a) {
        a = address(uint160(bound(seed, 1, type(uint160).max)));
        if (a == address(pool) || a == address(token) || a == address(this) || a == BOB) {
            a = address(uint160(a) ^ 0x1234);
        }
        // Precompiles are fine as EOAs for balances; the only exclusion is the taxed source.
        if (a == address(pool)) a = ALICE;
    }

    function _recipient(uint256 seed) private view returns (address a) {
        a = address(uint160(bound(seed, 1, type(uint160).max)));
        // The manager and the token itself are legitimate recipients of untaxed transfers.
        if (seed % 7 == 0) a = address(pool);
        if (seed % 7 == 1) a = address(token);
    }

    function _rejectManager(address manager) private {
        vm.expectRevert(abi.encodeWithSelector(IMDOLAR.InvalidPoolManager.selector, manager));
        new IMDOLAR(manager);
    }
}
