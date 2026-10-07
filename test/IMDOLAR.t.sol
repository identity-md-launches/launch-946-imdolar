// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDOLAR} from "../src/IMDOLAR.sol";

contract PoolSource {
    function send(IMDOLAR token, address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }

    function approve(IMDOLAR token, address spender, uint256 amount) external {
        require(token.approve(spender, amount));
    }
}

contract DeploymentFactory {
    function deploy(address manager, bytes32 salt) external returns (IMDOLAR) {
        return new IMDOLAR{salt: salt}(manager);
    }
}

contract IMDOLARTest is Test {
    IMDOLAR internal token;
    PoolSource internal pool;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant DISTRIBUTOR = address(0xD157);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function setUp() public {
        pool = new PoolSource();
        token = new IMDOLAR(address(pool));
    }

    function test_MetadataAndEntireSupplyMintedOnce() public view {
        assertEq(token.name(), "IMDOLAR");
        assertEq(token.symbol(), "DOLAR");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.poolManager(), address(pool));
        assertEq(token.BUY_TAX_BPS(), 9_900);
    }

    function test_FactoryCreate2ReceivesAllSupply() public {
        DeploymentFactory factory = new DeploymentFactory();
        bytes32 salt = keccak256("launch");
        bytes32 codeHash =
            keccak256(abi.encodePacked(type(IMDOLAR).creationCode, abi.encode(address(pool))));
        address predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))
            )
        );
        vm.expectEmit(true, true, false, true, predicted);
        emit Transfer(address(0), address(factory), SUPPLY);
        IMDOLAR deployed = factory.deploy(address(pool), salt);
        assertEq(address(deployed), predicted);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
        vm.expectRevert();
        factory.deploy(address(pool), salt);
    }

    function test_RejectsInvalidManagerConfiguration() public {
        _rejectManager(address(0));
        _rejectManager(ALICE);
        _rejectManager(address(this));
    }

    function test_LaunchDistributionClaimsAndRemainderArriveWhole() public {
        assertTrue(token.transfer(DISTRIBUTOR, SUPPLY / 10));
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, SUPPLY / 10));
        assertTrue(token.transfer(address(pool), SUPPLY * 8 / 10));
        assertTrue(token.transfer(BOB, SUPPLY / 10));
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY / 10);
        assertEq(token.balanceOf(address(pool)), SUPPLY * 8 / 10);
        assertEq(token.balanceOf(BOB), SUPPLY / 10);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_BuyBurns99PercentAndEmitsBothTransfers() public {
        token.transfer(address(pool), 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(pool), address(0), 99 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(pool), ALICE, 1 ether);
        pool.send(token, ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY - 99 ether);
    }

    function test_NoRecipientExemptionsIncludingDeployerDistributorAndToken() public {
        token.transfer(address(pool), 400 ether);
        address[4] memory recipients = [address(this), DISTRIBUTOR, address(token), ALICE];
        for (uint256 i; i < recipients.length; ++i) {
            uint256 before = token.balanceOf(recipients[i]);
            pool.send(token, recipients[i], 100 ether);
            assertEq(token.balanceOf(recipients[i]) - before, 1 ether);
        }
        assertEq(token.totalSupply(), SUPPLY - 396 ether);
    }

    function test_PoolSelfTransferStillBurnsTax() public {
        token.transfer(address(pool), 100 ether);
        pool.send(token, address(pool), 100 ether);
        assertEq(token.balanceOf(address(pool)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 99 ether);
    }

    function test_TransferFromTaxesSourceAndConsumesGrossAllowance() public {
        token.transfer(address(pool), 100 ether);
        pool.approve(token, address(this), 100 ether);
        assertTrue(token.transferFrom(address(pool), ALICE, 100 ether));
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.allowance(address(pool), address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY - 99 ether);
    }

    function test_MaxAllowanceRetainsStandardERC20Semantics() public {
        token.transfer(address(pool), 200 ether);
        pool.approve(token, ALICE, type(uint256).max);
        vm.startPrank(ALICE);
        token.transferFrom(address(pool), BOB, 100 ether);
        token.transferFrom(address(pool), ALICE, 100 ether);
        vm.stopPrank();
        assertEq(token.allowance(address(pool), ALICE), type(uint256).max);
        assertEq(token.balanceOf(ALICE), 1 ether);
        assertEq(token.balanceOf(BOB), 1 ether);
        assertEq(token.totalSupply(), SUPPLY - 198 ether);
    }

    function test_WalletTransfersAndSellsAreUntaxedIncludingTransferFrom() public {
        token.transfer(ALICE, 100 ether);
        vm.startPrank(ALICE);
        token.transfer(BOB, 10 ether);
        token.transfer(address(pool), 20 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, address(this), 70 ether);
        token.approve(address(this), 70 ether);
        vm.stopPrank();
        token.transferFrom(ALICE, address(pool), 70 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 10 ether);
        assertEq(token.balanceOf(address(pool)), 90 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_DustRoundingNeverCreatesAnUntaxedPositiveBuy() public {
        uint256[7] memory gross = [uint256(1), 2, 99, 100, 101, 199, 200];
        uint256[7] memory expectedNet = [uint256(0), 0, 0, 1, 1, 1, 2];
        uint256 burned;
        for (uint256 i; i < gross.length; ++i) {
            token.transfer(address(pool), gross[i]);
            uint256 before = token.balanceOf(ALICE);
            pool.send(token, ALICE, gross[i]);
            assertEq(token.balanceOf(ALICE) - before, expectedNet[i]);
            burned += gross[i] - expectedNet[i];
        }
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.totalSupply(), SUPPLY - burned);
    }

    function test_ZeroAndOrdinarySelfTransfers() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(pool), ALICE, 0);
        pool.send(token, ALICE, 0);
        token.transfer(address(this), SUPPLY);
        vm.prank(ALICE);
        token.transferFrom(BOB, ALICE, 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InsufficientBalanceRevertsAndRollsBackPartialBurnAndAllowance() public {
        token.transfer(address(pool), 99 ether);
        pool.approve(token, address(this), 100 ether);
        // Burning 99 succeeds internally, but delivering the remaining 1 must revert everything.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(pool), 0, 1 ether
            )
        );
        token.transferFrom(address(pool), ALICE, 100 ether);
        assertEq(token.allowance(address(pool), address(this)), 100 ether);
        assertEq(token.balanceOf(address(pool)), 99 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_AllowanceMustCoverGrossNotNetAndRevocationWorks() public {
        token.transfer(address(pool), 100 ether);
        pool.approve(token, address(this), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 1 ether, 100 ether
            )
        );
        token.transferFrom(address(pool), ALICE, 100 ether);
        pool.approve(token, address(this), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1
            )
        );
        token.transferFrom(address(pool), ALICE, 1);
        assertEq(token.balanceOf(address(pool)), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RejectsZeroReceiverSenderAndSpender() public {
        token.transfer(address(pool), 100 ether);
        pool.approve(token, address(this), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        token.transferFrom(address(pool), address(0), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
        token.transfer(address(0), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0))
        );
        token.transferFrom(address(0), ALICE, 0);
        vm.prank(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0))
        );
        token.transfer(ALICE, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
        token.approve(address(0), 1);
        assertEq(token.balanceOf(address(pool)), 100 ether);
        assertEq(token.allowance(address(pool), address(this)), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_HugeTransferRevertsWithoutArithmeticPanic() public {
        token.transfer(address(pool), SUPPLY);
        uint256 fee = type(uint256).max - type(uint256).max / 100;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(pool), SUPPLY, fee
            )
        );
        pool.send(token, ALICE, type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_NoAdministrativeMintFreezeSeizeOrTaxBypass() public {
        token.transfer(ALICE, 1 ether);
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", BOB, 1 ether);
        calls[1] = abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 1 ether);
        calls[2] = abi.encodeWithSignature("pause()");
        calls[3] = abi.encodeWithSignature("blacklist(address)", ALICE);
        calls[4] = abi.encodeWithSignature("freeze(address)", ALICE);
        calls[5] = abi.encodeWithSignature("seize(address)", ALICE);
        calls[6] = abi.encodeWithSignature("setTax(uint256)", 0);
        calls[7] = abi.encodeWithSignature("setPoolManager(address)", BOB);
        calls[8] = abi.encodeWithSignature("setFeeExempt(address,bool)", ALICE, true);
        calls[9] = abi.encodeWithSignature("upgradeTo(address)", BOB);
        calls[10] = abi.encodeWithSignature("initialize(address)", BOB);
        calls[11] = abi.encodeWithSignature("transferOwnership(address)", BOB);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
            vm.prank(BOB);
            (ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1
            )
        );
        token.transferFrom(ALICE, address(this), 1);
        vm.prank(ALICE);
        token.transfer(BOB, 1 ether);
        assertEq(token.balanceOf(BOB), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RuntimeHasNoDangerousOpcodes() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFuzz_BuyConservesBalancesAndBurns(uint256 gross, bool delegated) public {
        gross = bound(gross, 1, SUPPLY);
        token.transfer(address(pool), gross);
        if (delegated) {
            pool.approve(token, address(this), gross);
            token.transferFrom(address(pool), ALICE, gross);
            assertEq(token.allowance(address(pool), address(this)), 0);
        } else {
            pool.send(token, ALICE, gross);
        }
        // Independent rate calculation is safe here because gross is bounded by the initial supply.
        uint256 fee = (gross * 9_900 + 9_999) / 10_000;
        assertGt(fee, 0);
        assertEq(token.balanceOf(ALICE), gross - fee);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.totalSupply(), SUPPLY - fee);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(ALICE), token.totalSupply());
    }

    function testFuzz_SplittingBuysCannotReduceTax(uint256 gross, uint256 first) public {
        gross = bound(gross, 1, SUPPLY);
        first = bound(first, 0, gross);
        token.transfer(address(pool), gross);
        pool.send(token, ALICE, first);
        pool.send(token, ALICE, gross - first);
        assertLe(token.balanceOf(ALICE), gross / 100);
        assertEq(token.totalSupply(), SUPPLY - gross + token.balanceOf(ALICE));
    }

    function _rejectManager(address manager) private {
        vm.expectRevert(abi.encodeWithSelector(IMDOLAR.InvalidPoolManager.selector, manager));
        new IMDOLAR(manager);
    }
}
