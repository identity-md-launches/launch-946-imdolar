// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDOLAR} from "../src/IMDOLAR.sol";
import {PoolSource} from "./IMDOLAR.t.sol";

/// @dev Tracks an independent burn ledger across randomly ordered buys, sells, and wallet transfers.
contract TokenHandler is Test {
    IMDOLAR public immutable token;
    PoolSource public immutable pool;
    address[3] public holders = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    uint256 public burned;
    uint256 public buys;
    uint256 public sells;

    constructor(IMDOLAR token_, PoolSource pool_) {
        token = token_;
        pool = pool_;
    }

    function buy(uint256 seed, uint256 gross, bool delegated) external {
        address recipient = holders[seed % holders.length];
        gross = bound(gross, 0, token.balanceOf(address(pool)));
        uint256 before = token.balanceOf(recipient);
        uint256 expectedFee = (gross * 99 + 99) / 100;
        if (delegated) {
            pool.approve(token, address(this), gross);
            token.transferFrom(address(pool), recipient, gross);
            assertEq(token.allowance(address(pool), address(this)), 0);
        } else {
            pool.send(token, recipient, gross);
        }
        assertEq(token.balanceOf(recipient) - before, gross - expectedFee);
        burned += expectedFee;
        buys++;
    }

    function sell(uint256 seed, uint256 amount) external {
        address holder = holders[seed % holders.length];
        amount = bound(amount, 0, token.balanceOf(holder));
        uint256 before = token.balanceOf(address(pool));
        vm.prank(holder);
        token.transfer(address(pool), amount);
        assertEq(token.balanceOf(address(pool)) - before, amount);
        sells++;
    }

    function walletTransfer(uint256 seed, uint256 amount) external {
        uint256 index = seed % holders.length;
        address from = holders[index];
        address to = holders[(index + 1) % holders.length];
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 before = token.balanceOf(to);
        vm.prank(from);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) - before, amount);
    }
}

contract IMDOLARInvariantTest is Test {
    IMDOLAR internal token;
    PoolSource internal pool;
    TokenHandler internal handler;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        pool = new PoolSource();
        token = new IMDOLAR(address(pool));
        handler = new TokenHandler(token, pool);
        token.transfer(address(pool), SUPPLY / 2);
        token.transfer(handler.holders(0), SUPPLY / 2);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TokenHandler.buy.selector;
        selectors[1] = TokenHandler.sell.selector;
        selectors[2] = TokenHandler.walletTransfer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_AllBalancesPlusBurnsEqualOriginalSupply() public view {
        uint256 sum = token.balanceOf(address(pool));
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, token.totalSupply());
        assertEq(sum + handler.burned(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }
}
