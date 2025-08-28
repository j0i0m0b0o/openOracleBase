// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/OpenOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }
}

contract OpenOracleTest is Test {
    OpenOracle oracle;
    MockERC20 token1;
    MockERC20 token2;

    address alice = address(0x112345);
    address bob = address(0x212345);
    address charlie = address(0x312345);
    address payable protocolFeeRecipient = payable(address(0x123456));

    uint256 constant ORACLE_FEE = 0.01 ether;
    uint256 constant SETTLER_REWARD = 0.001 ether;

    function setUp() public {
        oracle = new OpenOracle();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        // Fund accounts with tokens
        token1.transfer(alice, 100 * 10 ** 18);
        token1.transfer(bob, 100 * 10 ** 18);
        token1.transfer(charlie, 100 * 10 ** 18);
        token2.transfer(alice, 100000 * 10 ** 18);
        token2.transfer(bob, 100000 * 10 ** 18);
        token2.transfer(charlie, 100000 * 10 ** 18);

        // Give ETH
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
        vm.deal(protocolFeeRecipient, 1 ether);

        // Approve oracle for all users
        vm.prank(alice);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(alice);
        token2.approve(address(oracle), type(uint256).max);

        vm.prank(bob);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        token2.approve(address(oracle), type(uint256).max);

        vm.prank(charlie);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(charlie);
        token2.approve(address(oracle), type(uint256).max);
    }

    function testGetProtocolFees() public {
        // Create report with protocol fee recipient
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000), // 10 bps
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                keepFee: false,
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        // Get state hash
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        // Wait for dispute delay
        vm.warp(block.timestamp + 6);

        // Dispute and swap - this will generate protocol fees
        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1), // swap token1
            1.1e18, // new amount1 (1.1x)
            2100e18, // new amount2
            2000e18, // expected amount2
            stateHash
        );

        // Calculate expected protocol fee
        uint256 expectedProtocolFee = (1e18 * 1000) / 1e7; // 0.001e18

        // Check protocol fees accrued
        assertEq(oracle.protocolFees(protocolFeeRecipient, address(token1)), expectedProtocolFee, "Protocol fee incorrect");

        // Test withdrawal of protocol fees
        uint256 recipientBalanceBefore = token1.balanceOf(protocolFeeRecipient);
        
        vm.prank(protocolFeeRecipient);
        uint256 withdrawnAmount = oracle.getProtocolFees(address(token1));
        
        assertEq(withdrawnAmount, expectedProtocolFee, "Withdrawn amount incorrect");
        assertEq(token1.balanceOf(protocolFeeRecipient), recipientBalanceBefore + expectedProtocolFee, "Balance after withdrawal incorrect");
        assertEq(oracle.protocolFees(protocolFeeRecipient, address(token1)), 0, "Protocol fees not reset");

        // Wait for settlement
        vm.warp(block.timestamp + 300);

        // Settle
        vm.prank(charlie);
        oracle.settle(reportId);
    }

    function testGetETHProtocolFees() public {
        // Create report with keepFee false to accumulate ETH protocol fees on settlement
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                keepFee: false, // Important: keepFee must be false for ETH protocol fees
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        // Get state hash
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        // Wait for dispute delay
        vm.warp(block.timestamp + 6);

        // Dispute to trigger ETH fee accumulation
        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1),
            1.1e18,
            2100e18,
            2000e18,
            stateHash
        );

        // Wait for settlement
        vm.warp(block.timestamp + 300);

        // Settle - this will accumulate ETH protocol fees
        vm.prank(charlie);
        oracle.settle(reportId);

        // Calculate expected ETH fee (reporter reward when dispute occurred and keepFee is false)
        uint256 expectedETHFee = ORACLE_FEE - SETTLER_REWARD; // Oracle fee minus settler reward

        // Check ETH protocol fees accrued
        assertEq(oracle.accruedProtocolFees(protocolFeeRecipient), expectedETHFee, "ETH protocol fee incorrect");

        // Test withdrawal of ETH protocol fees
        uint256 recipientETHBefore = protocolFeeRecipient.balance;
        
        vm.prank(protocolFeeRecipient);
        uint256 withdrawnETH = oracle.getETHProtocolFees();
        
        assertEq(withdrawnETH, expectedETHFee, "Withdrawn ETH amount incorrect");
        assertEq(protocolFeeRecipient.balance, recipientETHBefore + expectedETHFee, "ETH balance after withdrawal incorrect");
        assertEq(oracle.accruedProtocolFees(protocolFeeRecipient), 0, "ETH protocol fees not reset");
    }

    function testGetProtocolFeesWithZeroBalance() public {
        // Test withdrawing when no fees have accrued
        vm.prank(protocolFeeRecipient);
        uint256 withdrawn = oracle.getProtocolFees(address(token1));
        assertEq(withdrawn, 0, "Should return 0 when no fees accrued");
    }

    function testGetETHProtocolFeesWithZeroBalance() public {
        // Test withdrawing ETH when no fees have accrued
        vm.prank(protocolFeeRecipient);
        uint256 withdrawn = oracle.getETHProtocolFees();
        assertEq(withdrawn, 0, "Should return 0 when no ETH fees accrued");
    }

    function testOnlyRecipientCanWithdrawFees() public {
        // Create report and generate protocol fees
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                keepFee: false,
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        oracle.disputeAndSwap(reportId, address(token1), 1.1e18, 2100e18, 2000e18, stateHash);

        // Try to withdraw as non-recipient (should get 0 since alice has no accrued fees)
        vm.prank(alice);
        uint256 withdrawn = oracle.getProtocolFees(address(token1));
        assertEq(withdrawn, 0, "Non-recipient should not be able to withdraw fees");

        // Verify recipient can withdraw their fees
        vm.prank(protocolFeeRecipient);
        uint256 recipientWithdrawn = oracle.getProtocolFees(address(token1));
        assertGt(recipientWithdrawn, 0, "Recipient should be able to withdraw fees");
    }
}