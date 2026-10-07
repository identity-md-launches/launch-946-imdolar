// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDOLAR} from "../src/IMDOLAR.sol";
import {V4Actor} from "./IMDOLAR.v4.t.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";

/// @dev Random buys, sells and wallet moves against a real Uniswap v4 PoolManager, with an
/// independent ledger of what the manager and every trader should hold in DOLAR and ETH.
contract V4Handler is Test {
    IMDOLAR public immutable token;
    PoolManager public immutable manager;
    PoolKey internal key;
    V4Actor[4] public traders;

    uint256 public ghostBurned;
    uint256 public ghostGrossOut; // DOLAR that left the manager through swaps
    uint256 public ghostNetOut; // DOLAR buyers were credited for it
    uint256 public ghostManagerDolar; // model of the manager's DOLAR balance
    uint256 public ghostManagerEth; // model of the manager's ETH balance
    mapping(address => uint256) public expectedDolar;
    uint256 public lastSupply;
    uint256 public limitHits; // sells refused because the price already sat at the limit

    constructor(IMDOLAR token_, PoolManager manager_, PoolKey memory key_) {
        token = token_;
        manager = manager_;
        key = key_;
        for (uint256 i; i < traders.length; ++i) {
            traders[i] = new V4Actor(manager_);
        }
    }

    function snapshot() external {
        ghostManagerDolar = token.balanceOf(address(manager));
        ghostManagerEth = address(manager).balance;
        for (uint256 i; i < traders.length; ++i) {
            expectedDolar[address(traders[i])] = token.balanceOf(address(traders[i]));
        }
        lastSupply = token.totalSupply();
    }

    modifier supplyNeverGrows() {
        _;
        uint256 now_ = token.totalSupply();
        assertLe(now_, lastSupply, "total supply grew");
        lastSupply = now_;
    }

    /// @dev ETH in, DOLAR out to a recipient who may differ from the payer.
    function buy(uint256 seed, uint256 ethIn) external supplyNeverGrows {
        V4Actor trader = traders[seed % traders.length];
        address recipient = address(traders[(seed / traders.length) % traders.length]);
        uint256 funds = address(trader).balance;
        if (funds == 0) return;
        ethIn = bound(ethIn, 1, funds);

        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 managerBefore = token.balanceOf(address(manager));
        BalanceDelta delta = trader.swap(key, true, -int256(ethIn), recipient, 0);
        uint256 gross = uint256(uint128(delta.amount1()));
        uint256 paid = uint256(uint128(-delta.amount0()));
        uint256 delivered = token.balanceOf(recipient) - recipientBefore;

        assertLe(paid, ethIn, "swap took more ETH than specified");
        assertEq(managerBefore - token.balanceOf(address(manager)), gross, "manager lost != gross");
        assertEq(delivered, gross / 100, "buyer did not receive exactly one percent");
        assertLe(delivered * 100, gross, "buyer received more than one percent");

        ghostBurned += gross - delivered;
        ghostGrossOut += gross;
        ghostNetOut += delivered;
        ghostManagerDolar -= gross;
        ghostManagerEth += paid;
        expectedDolar[recipient] += delivered;
    }

    /// @dev DOLAR in, ETH out. The pool can run out of ETH-side range; that one revert is expected
    /// and counted, anything else fails the campaign.
    function sell(uint256 seed, uint256 amount) external supplyNeverGrows {
        V4Actor trader = traders[seed % traders.length];
        uint256 held = token.balanceOf(address(trader));
        if (held == 0) return;
        amount = bound(amount, 1, held);

        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 ethBefore = address(trader).balance;
        try trader.swap(key, false, -int256(amount), address(trader), 0) returns (
            BalanceDelta delta
        ) {
            uint256 sold = uint256(uint128(-delta.amount1()));
            uint256 received = uint256(uint128(delta.amount0()));
            assertLe(sold, amount, "swap took more DOLAR than specified");
            assertEq(held - token.balanceOf(address(trader)), sold, "seller lost != sold");
            assertEq(token.balanceOf(address(manager)) - managerBefore, sold, "sell arrived short");
            assertEq(address(trader).balance - ethBefore, received, "ETH out mismatch");
            ghostManagerDolar += sold;
            ghostManagerEth -= received;
            expectedDolar[address(trader)] -= sold;
        } catch (bytes memory reason) {
            assertEq(
                bytes4(reason), Pool.PriceLimitAlreadyExceeded.selector, "unexpected sell revert"
            );
            assertEq(token.balanceOf(address(trader)), held, "failed sell moved DOLAR");
            assertEq(token.balanceOf(address(manager)), managerBefore, "failed sell moved pool");
            limitHits++;
        }
    }

    /// @dev Wallet-to-wallet moves are untaxed and exact.
    function walletTransfer(uint256 seed, uint256 amount) external supplyNeverGrows {
        V4Actor from = traders[seed % traders.length];
        address to = address(traders[(seed / traders.length) % traders.length]);
        amount = bound(amount, 0, token.balanceOf(address(from)));
        uint256 toBefore = token.balanceOf(to);
        from.move(token, to, amount);
        if (address(from) != to) {
            assertEq(token.balanceOf(to) - toBefore, amount, "wallet transfer arrived short");
            expectedDolar[address(from)] -= amount;
            expectedDolar[to] += amount;
        }
    }

    /// @dev A router that insists on the gross quote arriving must fail, and fail atomically.
    function rejectedGrossQuote(uint256 seed, uint256 ethIn) external supplyNeverGrows {
        V4Actor trader = traders[seed % traders.length];
        uint256 funds = address(trader).balance;
        if (funds < 1_000) return;
        ethIn = bound(ethIn, 1_000, funds);
        uint256 managerBefore = token.balanceOf(address(manager));
        uint256 supplyBefore = token.totalSupply();
        // At a price near 1:1 the gross output is close to ethIn; demanding 5% of it is already
        // five times what the tax lets through.
        try trader.swap(key, true, -int256(ethIn), address(trader), ethIn / 20) {
            assertTrue(false, "a swap demanding more than one percent of gross succeeded");
        } catch (bytes memory reason) {
            if (bytes4(reason) == Pool.PriceLimitAlreadyExceeded.selector) {
                limitHits++;
            } else {
                assertEq(
                    reason, abi.encodeWithSignature("Error(string)", "insufficient net output")
                );
            }
        }
        assertEq(token.balanceOf(address(manager)), managerBefore, "failed buy moved pool DOLAR");
        assertEq(token.totalSupply(), supplyBefore, "failed buy burned supply");
        assertEq(address(trader).balance, funds, "failed buy kept ETH");
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
contract IMDOLARV4InvariantTest is Test {
    PoolManager internal manager;
    V4Actor internal factory;
    IMDOLAR internal token;
    V4Handler internal handler;
    PoolKey internal key;
    address internal constant DISTRIBUTOR = address(0xD157);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal seeded;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new V4Actor(manager);
        token = factory.deployToken();
        key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0))
        );
        handler = new V4Handler(token, manager, key);

        // Launch flows: swarm share out, pool seeded single-sided, remainder to the requester,
        // who is one of the traders so that large sells are possible.
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        manager.initialize(key, uint160(1 << 96));
        factory.seed(key, -600, 0, 100_000_000 ether);
        seeded = token.balanceOf(address(manager));
        factory.move(token, address(handler.traders(0)), token.balanceOf(address(factory)));
        for (uint256 i; i < 4; ++i) {
            vm.deal(address(handler.traders(i)), 50 ether);
        }
        handler.snapshot();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = V4Handler.buy.selector;
        selectors[1] = V4Handler.sell.selector;
        selectors[2] = V4Handler.walletTransfer.selector;
        selectors[3] = V4Handler.rejectedGrossQuote.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev DOLAR is conserved across the manager, the traders and the untouched launch accounts.
    function invariant_DolarIsConserved() public view {
        uint256 sum = token.balanceOf(address(manager)) + token.balanceOf(DISTRIBUTOR);
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(address(handler.traders(i)));
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10, "the swarm share moved");
    }

    /// @dev Only the modelled tax leaves the supply, and the supply never exceeds the mint.
    function invariant_SupplyIsInitialMinusTax() public view {
        assertEq(token.totalSupply() + handler.ghostBurned(), SUPPLY);
        assertLe(token.totalSupply(), SUPPLY);
    }

    /// @dev The manager's real balances match the ledger built from swap deltas: the tax never
    /// leaves the pool short on either side of the pair.
    function invariant_ManagerBalancesMatchSwapLedger() public view {
        assertEq(token.balanceOf(address(manager)), handler.ghostManagerDolar(), "DOLAR");
        assertEq(address(manager).balance, handler.ghostManagerEth(), "ETH");
    }

    /// @dev Every trader holds exactly what buys, sells and wallet moves say it should.
    function invariant_TradersMatchLedger() public view {
        for (uint256 i; i < 4; ++i) {
            address trader = address(handler.traders(i));
            assertEq(token.balanceOf(trader), handler.expectedDolar(trader));
        }
    }

    /// @dev Over any history of real swaps, buyers kept at most 1% of what the pool paid out.
    function invariant_CumulativeBuyTaxIsAtLeast99Percent() public view {
        uint256 gross = handler.ghostGrossOut();
        assertLe(handler.ghostNetOut() * 100, gross);
        assertGe(handler.ghostBurned() * 100, gross * 99);
        assertEq(handler.ghostNetOut() + handler.ghostBurned(), gross);
    }
}
