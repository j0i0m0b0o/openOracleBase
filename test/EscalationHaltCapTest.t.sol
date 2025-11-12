// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./BaseTest.sol";
import "../src/OpenOracle.sol";

// Tests around escalationHalt cap and +1 behavior once at cap
contract EscalationHaltCapTest is BaseTest {
    function setUp() public override {
        BaseTest.setUp();

        // Ensure high balances for token1 needed by escalation tests
        uint256 target = 10000e18;
        uint256 bal;

        bal = token1.balanceOf(alice);
        if (bal < target) token1.transfer(alice, target - bal);

        bal = token1.balanceOf(bob);
        if (bal < target) token1.transfer(bob, target - bal);

        bal = token1.balanceOf(charlie);
        if (bal < target) token1.transfer(charlie, target - bal);
    }

    // Verifies amounts are capped at escalationHalt and then +1 applies
    function testEscalationHaltCapBehavior() public {
        // Test the new behavior where expectedAmount1 is capped at escalationHalt
        // when multiplier would push it above the halt threshold

        vm.startPrank(alice);

        uint256 initialAmount1 = 100e18;
        uint256 initialAmount2 = 100e18;
        uint256 escalationHalt = 150e18; // Set halt at 150 tokens
        uint256 multiplier = 200; // 2x multiplier (would normally double the amount)
        uint256 fee = 3000; // 3 bps
        uint256 settlementTime = 120; // 2 minutes
        uint256 disputeDelay = 0;
        uint256 protocolFee = 1000; // 1 bps

        // Create report instance with escalation halt below what multiplier would reach
        uint256 reportId = oracle.createReportInstance{
            value: 0.01 ether
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: initialAmount1,
                feePercentage: uint24(fee),
                multiplier: uint16(multiplier),
                settlementTime: uint48(settlementTime),
                escalationHalt: escalationHalt,
                disputeDelay: uint24(disputeDelay),
                protocolFee: uint24(protocolFee),
                settlerReward: 0.001 ether,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: 0,
                keepFee: true,
                protocolFeeRecipient: alice
            })
        );

        // Submit initial report
        token1.approve(address(oracle), initialAmount1);
        token2.approve(address(oracle), initialAmount2);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        oracle.submitInitialReport(reportId, initialAmount1, initialAmount2, stateHash);

        vm.stopPrank();

        // Bob disputes - with multiplier of 2x, newAmount1 would be 200e18
        // But escalationHalt is 150e18, so it should be capped at 150e18
        vm.startPrank(bob);

        uint256 expectedNewAmount1 = escalationHalt; // Should be capped at escalationHalt
        uint256 newAmount2 = 120e18; // Different price to be outside fee boundary

        // Approve tokens for dispute
        token1.approve(address(oracle), 1000e18);
        token2.approve(address(oracle), 1000e18);

        // This should succeed with newAmount1 = escalationHalt
        oracle.disputeAndSwap(reportId, address(token1), expectedNewAmount1, newAmount2, initialAmount2, stateHash);

        vm.stopPrank();

        // Charlie tries to dispute again
        // Now oldAmount1 is 150e18 (at escalationHalt)
        // With multiplier of 2x, it would be 300e18, but should still be capped at 150e18
        // Since we're already at escalationHalt, it should switch to +1 behavior
        vm.startPrank(charlie);

        uint256 expectedNewAmount1Second = escalationHalt + 1; // Should be escalationHalt + 1
        uint256 newAmount2Second = 100e18; // Different price again

        // Approve tokens for dispute
        token1.approve(address(oracle), 1000e18);
        token2.approve(address(oracle), 1000e18);

        // This should succeed with newAmount1 = escalationHalt + 1
        oracle.disputeAndSwap(
            reportId, address(token1), expectedNewAmount1Second, newAmount2Second, newAmount2, stateHash
        );

        vm.stopPrank();

        // Verify the final amounts
        (uint256 finalAmount1, uint256 finalAmount2,,,,,,, bool disputeOccurred,) = oracle.reportStatus(reportId);
        assertEq(finalAmount1, escalationHalt + 1, "Final amount1 should be escalationHalt + 1");
        assertEq(finalAmount2, newAmount2Second, "Final amount2 should match last dispute");
        assertTrue(disputeOccurred, "Dispute should have occurred");
    }

    // Ensures consistent cap behavior across multiple disputes
    function testEscalationHaltCapMultipleDisputes() public {
        // Test multiple disputes to ensure the cap works consistently

        vm.startPrank(alice);

        uint256 initialAmount1 = 10e18;
        uint256 initialAmount2 = 10e18;
        uint256 escalationHalt = 35e18; // Set halt at 35 tokens
        uint256 multiplier = 150; // 1.5x multiplier
        uint256 fee = 3000; // 3 bps
        uint256 settlementTime = 300; // 5 minutes
        uint256 disputeDelay = 0;
        uint256 protocolFee = 1000; // 1 bps

        // Create report instance
        uint256 reportId = oracle.createReportInstance{
            value: 0.01 ether
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: initialAmount1,
                feePercentage: uint24(fee),
                multiplier: uint16(multiplier),
                settlementTime: uint48(settlementTime),
                escalationHalt: escalationHalt,
                disputeDelay: uint24(disputeDelay),
                protocolFee: uint24(protocolFee),
                settlerReward: 0.001 ether,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: 0,
                keepFee: true,
                protocolFeeRecipient: alice
            })
        );

        // Submit initial report
        token1.approve(address(oracle), initialAmount1);
        token2.approve(address(oracle), initialAmount2);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        oracle.submitInitialReport(reportId, initialAmount1, initialAmount2, stateHash);

        vm.stopPrank();

        // First dispute: 10 * 1.5 = 15
        vm.startPrank(bob);
        token1.approve(address(oracle), 1000e18);
        token2.approve(address(oracle), 1000e18);
        oracle.disputeAndSwap(reportId, address(token1), 15e18, 12e18, initialAmount2, stateHash);
        vm.stopPrank();

        // Second dispute: 15 * 1.5 = 22.5
        vm.startPrank(charlie);
        token1.approve(address(oracle), 1000e18);
        token2.approve(address(oracle), 1000e18);
        oracle.disputeAndSwap(reportId, address(token1), 225e17, 20e18, 12e18, stateHash);
        vm.stopPrank();

        // Third dispute: 22.5 * 1.5 = 33.75 (still below escalationHalt)
        vm.startPrank(bob);
        oracle.disputeAndSwap(reportId, address(token1), 3375e16, 25e18, 20e18, stateHash);
        vm.stopPrank();

        // Fourth dispute: 33.75 * 1.5 = 50.625, but should be capped at 35
        vm.startPrank(charlie);
        oracle.disputeAndSwap(reportId, address(token1), escalationHalt, 30e18, 25e18, stateHash);
        vm.stopPrank();

        // Fifth dispute: Already at escalationHalt, so should only increase by 1
        vm.startPrank(bob);
        oracle.disputeAndSwap(reportId, address(token1), escalationHalt + 1, 35e18, 30e18, stateHash);
        vm.stopPrank();

        // Verify the progression worked as expected
        (uint256 finalAmount1, uint256 finalAmount2,,,,,,, bool disputeOccurred,) = oracle.reportStatus(reportId);
        assertEq(finalAmount1, escalationHalt + 1, "Final amount1 should be escalationHalt + 1");
        assertEq(finalAmount2, 35e18, "Final amount2 should match last dispute");
        assertTrue(disputeOccurred, "Dispute should have occurred");
    }

    // Reverts when disputers use incorrect escalation amounts
    function testRevertWhenIncorrectEscalationAmount() public {
        // Test that disputes revert when using incorrect escalation amounts

        vm.startPrank(alice);

        uint256 initialAmount1 = 50e18;
        uint256 initialAmount2 = 50e18;
        uint256 escalationHalt = 80e18;
        uint256 multiplier = 150; // 1.5x multiplier

        // Create and submit initial report
        uint256 reportId = oracle.createReportInstance{
            value: 0.01 ether
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: initialAmount1,
                feePercentage: 3000,
                multiplier: uint16(multiplier),
                settlementTime: uint48(300),
                escalationHalt: escalationHalt,
                disputeDelay: uint24(0),
                protocolFee: uint24(1000),
                settlerReward: 0.001 ether,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: 0,
                keepFee: true,
                protocolFeeRecipient: alice
            })
        );

        token1.approve(address(oracle), initialAmount1);
        token2.approve(address(oracle), initialAmount2);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        oracle.submitInitialReport(reportId, initialAmount1, initialAmount2, stateHash);

        vm.stopPrank();

        // Bob tries to dispute with wrong amount
        vm.startPrank(bob);
        token1.approve(address(oracle), 1000e18);
        token2.approve(address(oracle), 1000e18);

        // Expected: 50 * 1.5 = 75, but Bob tries with 76
        vm.expectRevert(abi.encodeWithSelector(OpenOracle.InvalidInput.selector, "new amount"));
        oracle.disputeAndSwap(reportId, address(token1), 76e18, 60e18, initialAmount2, stateHash);

        // Try with correct amount (75e18)
        oracle.disputeAndSwap(reportId, address(token1), 75e18, 60e18, initialAmount2, stateHash);
        vm.stopPrank();

        // Now charlie tries to dispute
        // 75 * 1.5 = 112.5, but escalationHalt is 80, so should be capped at 80
        vm.startPrank(charlie);
        token1.approve(address(oracle), 1000e18);
        token2.approve(address(oracle), 1000e18);

        // Should fail if trying with uncapped amount (112.5)
        vm.expectRevert(abi.encodeWithSelector(OpenOracle.InvalidInput.selector, "new amount"));
        oracle.disputeAndSwap(reportId, address(token1), 1125e17, 70e18, 60e18, stateHash);

        // Should succeed with capped amount (80)
        oracle.disputeAndSwap(reportId, address(token1), escalationHalt, 70e18, 60e18, stateHash);
        vm.stopPrank();
    }
}
