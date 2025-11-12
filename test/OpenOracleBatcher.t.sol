// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./BaseTest.sol";
import "../src/OpenOracle.sol";
import "../src/OpenOracleBatcher.sol";

contract OpenOracleBatcherTest is BaseTest {
    openOracleBatcher batcher;

    function setUp() public override {
        BaseTest.setUp();

        // Deploy batcher after oracle exists
        batcher = new openOracleBatcher(address(oracle));

        // Approve batcher for both alice and bob for convenience
        vm.startPrank(alice);
        token1.approve(address(batcher), type(uint256).max);
        token2.approve(address(batcher), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token1.approve(address(batcher), type(uint256).max);
        token2.approve(address(batcher), type(uint256).max);
        vm.stopPrank();
    }

    // Submits an initial report using the batcher and validates lifecycle
    function testBatcherInitialReport() public {
        console.log("=== Testing Batcher Initial Report ===");

        // 1. Create report directly through oracle
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: 0.01 ether
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: 3000,
                multiplier: 110,
                settlementTime: 300,
                escalationHalt: 10e18,
                disputeDelay: 5,
                protocolFee: 1000,
                settlerReward: 0.001 ether,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: 0,
                keepFee: false,
                protocolFeeRecipient: address(0)
            })
        );

        console.log("Created report ID:", reportId);

        // 2. Get stateHash
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        console.log("StateHash obtained");

        // 3. Submit initial report using batcher (by bob)
        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0].reportId = reportId;
        reports[0].amount1 = 1e18;
        reports[0].amount2 = 2000e18;
        reports[0].stateHash = stateHash;

        vm.prank(bob);
        batcher.submitInitialReports(reports, 1e18, 2000e18); // Pass batch amounts
        console.log("Initial report submitted through batcher");

        // 4. Wait and dispute
        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1),
            1.1e18, // 1.1x multiplier
            2100e18,
            2000e18, // amt2Expected
            stateHash
        );
        console.log("Dispute submitted");

        // 5. Settle
        vm.warp(block.timestamp + 300);
        (uint256 finalPrice, uint256 settlementTime) = oracle.settle(reportId);
        console.log("Settled at price:", finalPrice / 1e18);
        console.log("Settlement time:", settlementTime);

        console.log("[PASS] Batcher initial report lifecycle completed!");
    }

    // Disputes an existing report using the batcher and validates outcome
    function testBatcherDispute() public {
        console.log("=== Testing Batcher Dispute ===");

        // 1. Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: 0.01 ether
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: 3000,
                multiplier: 110,
                settlementTime: 300,
                escalationHalt: 10e18,
                disputeDelay: 5,
                protocolFee: 1000,
                settlerReward: 0.001 ether,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: 0,
                keepFee: false,
                protocolFeeRecipient: address(0)
            })
        );

        console.log("Created report ID:", reportId);

        // 2. Get stateHash
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        console.log("StateHash obtained");

        // 3. Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);
        console.log("Initial report submitted");

        // 4. Wait and dispute using batcher
        vm.warp(block.timestamp + 6);

        // Create dispute data for batcher
        openOracleBatcher.DisputeData[] memory disputes = new openOracleBatcher.DisputeData[](1);
        disputes[0].reportId = reportId;
        disputes[0].tokenToSwap = address(token1);
        disputes[0].newAmount1 = 1.1e18; // 1.1x multiplier
        disputes[0].newAmount2 = 2100e18;
        disputes[0].amt2Expected = 2000e18;
        disputes[0].stateHash = stateHash;

        // Calculate batch amounts needed for dispute
        uint256 fee = (1e18 * 3000) / 1e7; // 0.003e18
        uint256 protocolFee = (1e18 * 1000) / 1e7; // 0.001e18
        uint256 batchAmount1 = 1e18 + 1.1e18 + fee + protocolFee;
        uint256 batchAmount2 = 100e18; // Extra token2 for the swap difference

        vm.prank(alice);
        batcher.disputeReports(disputes, batchAmount1, batchAmount2);
        console.log("Dispute submitted through batcher");

        // 5. Settle
        vm.warp(block.timestamp + 300);
        (uint256 finalPrice, uint256 settlementTime) = oracle.settle(reportId);
        console.log("Settled at price:", finalPrice / 1e18);
        console.log("Settlement time:", settlementTime);

        console.log("[PASS] Batcher dispute lifecycle completed!");
    }

    // Settles a report via the batcher and forwards ETH rewards to caller
    function testBatcherSettle() public {
        console.log("=== Testing Batcher Settle ===");

        // 1. Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: 0.01 ether
        }(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: 3000,
                multiplier: 110,
                settlementTime: 300,
                escalationHalt: 10e18,
                disputeDelay: 5,
                protocolFee: 1000,
                settlerReward: 0.001 ether,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: 0,
                keepFee: false,
                protocolFeeRecipient: address(0)
            })
        );

        console.log("Created report ID:", reportId);

        // 2. Get stateHash
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        console.log("StateHash obtained");

        // 3. Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);
        console.log("Initial report submitted");

        // 4. Wait and dispute
        vm.warp(block.timestamp + 6);

        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1),
            1.1e18, // 1.1x multiplier
            2100e18,
            2000e18, // amt2Expected
            stateHash
        );
        console.log("Dispute submitted");

        // 5. Settle using batcher
        vm.warp(block.timestamp + 300);

        // Create settle data
        openOracleBatcher.SettleData[] memory settles = new openOracleBatcher.SettleData[](1);
        settles[0].reportId = reportId;

        // Check ETH balances before
        uint256 callerBalanceBefore = address(this).balance;
        uint256 batcherBalanceBefore = address(batcher).balance;
        console.log("Caller ETH before:", callerBalanceBefore);
        console.log("Batcher ETH before:", batcherBalanceBefore);

        // Call settleReports - anyone can call this
        batcher.settleReports(settles);

        // Check ETH balances after
        uint256 callerBalanceAfter = address(this).balance;
        uint256 batcherBalanceAfter = address(batcher).balance;
        console.log("Caller ETH after:", callerBalanceAfter);
        console.log("Batcher ETH after:", batcherBalanceAfter);
        console.log("ETH gained:", callerBalanceAfter - callerBalanceBefore);

        // Verify settlement
        IOpenOracle.ReportStatus memory status = IOpenOracle(address(oracle)).reportStatus(reportId);
        assertTrue(status.isDistributed);
        console.log("Settled at price:", status.price / 1e18);
        console.log("Settlement time:", status.settlementTimestamp);

        console.log("[PASS] Batcher settle lifecycle completed!");
    }

    receive() external payable {}
}
