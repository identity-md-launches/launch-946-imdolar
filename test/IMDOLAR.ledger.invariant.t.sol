// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDOLAR} from "../src/IMDOLAR.sol";
import {PoolSource} from "./IMDOLAR.t.sol";

/// @dev Drives the token with five actors, a manager stand-in, exact and unlimited allowances,
/// third-party spenders, transfers into the token contract, and calls that must fail. Keeps an
/// independent per-account ledger so the invariants compare the token against a model, not against
/// itself.
contract LedgerHandler is Test {
    IMDOLAR public immutable token;
    PoolSource public immutable pool;
    address[5] public actors =
        [address(0xA11CE), address(0xB0B), address(0xCAFE), address(0xDADA), address(0xE11E)];

    // Independent model of what each account should hold.
    mapping(address => uint256) public expectedBalance;
    uint256 public ghostBurned;
    uint256 public ghostGrossOut; // gross DOLAR that left the manager through taxed transfers
    uint256 public ghostNetOut; // what buyers were credited for it
    uint256 public lastSupply;

    constructor(IMDOLAR token_, PoolSource pool_) {
        token = token_;
        pool = pool_;
    }

    /// @dev Called once by the test after funding so the model starts from the real balances.
    function snapshot() external {
        expectedBalance[address(pool)] = token.balanceOf(address(pool));
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = token.balanceOf(actors[i]);
        }
        lastSupply = token.totalSupply();
    }

    modifier supplyNeverGrows() {
        _;
        uint256 now_ = token.totalSupply();
        assertLe(now_, lastSupply, "total supply grew");
        lastSupply = now_;
    }

    function buyDirect(uint256 seed, uint256 gross) external supplyNeverGrows {
        address to = actors[seed % actors.length];
        gross = bound(gross, 0, token.balanceOf(address(pool)));
        uint256 before = token.balanceOf(to);
        pool.send(token, to, gross);
        _recordBuy(to, gross, token.balanceOf(to) - before);
    }

    function buyDelegated(uint256 seed, uint256 gross, bool unlimited) external supplyNeverGrows {
        address spender = actors[seed % actors.length];
        address to = actors[(seed / actors.length) % actors.length];
        gross = bound(gross, 0, token.balanceOf(address(pool)));
        uint256 approved = unlimited ? type(uint256).max : gross;
        pool.approve(token, spender, approved);
        uint256 before = token.balanceOf(to);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(pool), to, gross));
        assertEq(
            token.allowance(address(pool), spender),
            unlimited ? type(uint256).max : 0,
            "allowance did not track the gross amount"
        );
        _recordBuy(to, gross, token.balanceOf(to) - before);
        pool.approve(token, spender, 0);
    }

    function sell(uint256 seed, uint256 amount) external supplyNeverGrows {
        address from = actors[seed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(address(pool), amount));
        expectedBalance[from] -= amount;
        expectedBalance[address(pool)] += amount;
    }

    function walletTransfer(uint256 seed, uint256 amount) external supplyNeverGrows {
        address from = actors[seed % actors.length];
        address to = actors[(seed / actors.length) % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function walletTransferFrom(uint256 seed, uint256 amount) external supplyNeverGrows {
        address owner = actors[seed % actors.length];
        address spender = actors[(seed / actors.length) % actors.length];
        address to = actors[(seed / (actors.length * actors.length)) % actors.length];
        amount = bound(amount, 0, token.balanceOf(owner));
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        assertEq(token.allowance(owner, spender), 0);
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
    }

    /// @dev Tokens sent to the token contract are stranded but still part of the supply.
    function strandInToken(uint256 seed, uint256 amount) external supplyNeverGrows {
        address from = actors[seed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from) / 1_000);
        vm.prank(from);
        assertTrue(token.transfer(address(token), amount));
        expectedBalance[from] -= amount;
        expectedBalance[address(token)] += amount;
    }

    /// @dev A buy larger than the manager holds must fail completely, whatever the excess.
    function rejectedOverdraw(uint256 seed, uint256 excess) external supplyNeverGrows {
        address to = actors[seed % actors.length];
        uint256 held = token.balanceOf(address(pool));
        excess = bound(excess, 1, type(uint256).max - held);
        try pool.send(token, to, held + excess) {
            assertTrue(false, "manager overdraw succeeded");
        } catch {}
        assertEq(token.balanceOf(address(pool)), held, "failed buy changed the manager balance");
    }

    /// @dev A spender whose allowance covers only the net must still be refused the gross.
    function rejectedShortAllowance(uint256 seed, uint256 gross) external supplyNeverGrows {
        address spender = actors[seed % actors.length];
        gross = bound(gross, 1, token.balanceOf(address(pool)) + 1);
        pool.approve(token, spender, gross - 1);
        vm.prank(spender);
        try token.transferFrom(address(pool), spender, gross) {
            assertTrue(false, "transferFrom beyond allowance succeeded");
        } catch {}
        assertEq(token.allowance(address(pool), spender), gross - 1, "failed spend used allowance");
        pool.approve(token, spender, 0);
    }

    function zeroValueMoves(uint256 seed) external supplyNeverGrows {
        address who = actors[seed % actors.length];
        uint256 poolBefore = token.balanceOf(address(pool));
        pool.send(token, who, 0);
        vm.prank(who);
        assertTrue(token.transfer(address(pool), 0));
        assertEq(token.balanceOf(address(pool)), poolBefore);
    }

    function _recordBuy(address to, uint256 gross, uint256 delivered) private {
        // Spec bound, independent of the implementation's rounding: at most 1% arrives.
        assertLe(delivered * 100, gross, "buyer received more than one percent");
        if (gross >= 100) assertGt(delivered, 0, "a taxable buy delivered nothing");
        expectedBalance[address(pool)] -= gross;
        expectedBalance[to] += delivered;
        ghostBurned += gross - delivered;
        ghostGrossOut += gross;
        ghostNetOut += delivered;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract IMDOLARLedgerInvariantTest is Test {
    IMDOLAR internal token;
    PoolSource internal pool;
    LedgerHandler internal handler;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        pool = new PoolSource();
        token = new IMDOLAR(address(pool));
        handler = new LedgerHandler(token, pool);
        // Launch-like split: 60% in the manager, the rest spread over the actors, nothing left here.
        token.transfer(address(pool), SUPPLY * 60 / 100);
        token.transfer(handler.actors(0), SUPPLY * 20 / 100);
        token.transfer(handler.actors(1), SUPPLY * 10 / 100);
        token.transfer(handler.actors(2), SUPPLY * 10 / 100);
        handler.snapshot();

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = LedgerHandler.buyDirect.selector;
        selectors[1] = LedgerHandler.buyDelegated.selector;
        selectors[2] = LedgerHandler.sell.selector;
        selectors[3] = LedgerHandler.walletTransfer.selector;
        selectors[4] = LedgerHandler.walletTransferFrom.selector;
        selectors[5] = LedgerHandler.strandInToken.selector;
        selectors[6] = LedgerHandler.rejectedOverdraw.selector;
        selectors[7] = LedgerHandler.rejectedShortAllowance.selector;
        selectors[8] = LedgerHandler.zeroValueMoves.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev Every account the sequence can touch, summed, is the supply. Nothing leaks anywhere else.
    function invariant_SumOfAllBalancesIsTotalSupply() public view {
        uint256 sum = token.balanceOf(address(pool)) + token.balanceOf(address(token));
        for (uint256 i; i < 5; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev The only thing that ever leaves the supply is the tax the model recorded.
    function invariant_SupplyIsInitialMinusModelledBurns() public view {
        assertEq(token.totalSupply() + handler.ghostBurned(), SUPPLY);
        assertLe(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    /// @dev Each account holds exactly what the independent ledger says it should.
    function invariant_EveryAccountMatchesTheLedger() public view {
        assertEq(token.balanceOf(address(pool)), handler.expectedBalance(address(pool)), "manager");
        assertEq(token.balanceOf(address(token)), handler.expectedBalance(address(token)), "token");
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "actor");
        }
    }

    /// @dev Across the whole history, buyers kept at most 1% of what left the manager and at least
    /// 99% of it was burned. Splitting, delegating, or rerouting buys never beats the rate.
    function invariant_CumulativeTaxIsAtLeast99Percent() public view {
        uint256 gross = handler.ghostGrossOut();
        assertLe(handler.ghostNetOut() * 100, gross);
        assertGe(handler.ghostBurned() * 100, gross * 99);
        assertEq(handler.ghostNetOut() + handler.ghostBurned(), gross);
    }

    /// @dev The taxed source cannot be changed by any sequence of calls.
    function invariant_ManagerIsFixed() public view {
        assertEq(token.poolManager(), address(pool));
    }
}
