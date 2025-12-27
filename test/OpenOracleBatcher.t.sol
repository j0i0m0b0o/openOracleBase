// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./BaseTest.sol";
import "../src/OpenOracle.sol";
import "../src/OpenOracleBatcher.sol";

contract OpenOracleBatcherTest is BaseTest {
    openOracleBatcher batcher;

    function setUp() public override {
        BaseTest.setUp();

        // Set reasonable timestamp and block number to avoid underflow in timing checks
        vm.warp(1000000);
        vm.roll(1000000);

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

    // ============ NEW FUNCTION TESTS ============

    // Helper to build oracleParams - uses IOpenOracle interface to avoid stack issues
    function _getOracleParams(uint256 reportId) internal view returns (openOracleBatcher.oracleParams memory p, bytes32 stateHash) {
        IOpenOracle iOracle = IOpenOracle(address(oracle));
        IOpenOracle.ReportMeta memory meta = iOracle.reportMeta(reportId);
        IOpenOracle.ReportStatus memory status = iOracle.reportStatus(reportId);
        IOpenOracle.extraReportData memory extra = iOracle.extraData(reportId);

        p = openOracleBatcher.oracleParams({
            exactToken1Report: meta.exactToken1Report,
            escalationHalt: meta.escalationHalt,
            fee: meta.fee,
            settlerReward: meta.settlerReward,
            token1: meta.token1,
            settlementTime: meta.settlementTime,
            token2: meta.token2,
            timeType: meta.timeType,
            feePercentage: meta.feePercentage,
            protocolFee: meta.protocolFee,
            multiplier: meta.multiplier,
            disputeDelay: meta.disputeDelay,
            currentAmount1: status.currentAmount1,
            currentAmount2: status.currentAmount2,
            callbackGasLimit: extra.callbackGasLimit,
            protocolFeeRecipient: extra.protocolFeeRecipient,
            keepFee: extra.keepFee
        });

        stateHash = extra.stateHash;
    }

    // Test submitInitialReportSafe with validation
    function testSubmitInitialReportSafe() public {
        console.log("=== Testing submitInitialReportSafe ===");

        // 1. Create report with keepFee = true (required for safe function)
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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
                keepFee: true, // Must be true for safe function
                protocolFeeRecipient: alice
            })
        );

        // 2. Get oracle data for validation
        (openOracleBatcher.oracleParams memory p, bytes32 stateHash) = _getOracleParams(reportId);
        // Override currentAmount since no initial report yet
        p.currentAmount1 = 0;
        p.currentAmount2 = 0;

        // 3. Build report data
        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        // 4. Submit using safe function
        vm.prank(bob);
        batcher.submitInitialReportSafe(
            reports,
            p,
            1e18,
            2000e18,
            block.timestamp,
            block.number,
            10, // timestampBound
            10  // blockNumberBound
        );

        // Verify
        (uint256 currentAmount1, uint256 currentAmount2,,,,,,,,) = oracle.reportStatus(reportId);
        assertEq(currentAmount1, 1e18);
        assertEq(currentAmount2, 2000e18);
        console.log("[PASS] submitInitialReportSafe completed!");
    }

    // Test submitInitialReportSafe reverts with wrong params
    function testSubmitInitialReportSafe_RevertsOnBadParams() public {
        console.log("=== Testing submitInitialReportSafe revert on bad params ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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
                keepFee: true,
                protocolFeeRecipient: alice
            })
        );

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Build WRONG oracleParams (wrong exactToken1Report)
        openOracleBatcher.oracleParams memory p = openOracleBatcher.oracleParams({
            exactToken1Report: 999e18, // WRONG!
            escalationHalt: 10e18,
            fee: 0.01 ether - 0.001 ether,
            settlerReward: 0.001 ether,
            token1: address(token1),
            settlementTime: 300,
            token2: address(token2),
            timeType: true,
            feePercentage: 3000,
            protocolFee: 1000,
            multiplier: 110,
            disputeDelay: 5,
            currentAmount1: 0,
            currentAmount2: 0,
            callbackGasLimit: 0,
            protocolFeeRecipient: alice,
            keepFee: true
        });

        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(openOracleBatcher.ActionSafetyFailure.selector, "params dont match"));
        batcher.submitInitialReportSafe(reports, p, 1e18, 2000e18, block.timestamp, block.number, 10, 10);

        console.log("[PASS] submitInitialReportSafe correctly reverts on bad params!");
    }

    // Test submitInitialReportsNoValidation with timing checks
    function testSubmitInitialReportsNoValidation() public {
        console.log("=== Testing submitInitialReportsNoValidation ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        vm.prank(bob);
        batcher.submitInitialReportsNoValidation(
            reports,
            1e18,
            2000e18,
            block.timestamp,
            block.number,
            10,
            10
        );

        (uint256 currentAmount1,,,,,,,,,) = oracle.reportStatus(reportId);
        assertEq(currentAmount1, 1e18);
        console.log("[PASS] submitInitialReportsNoValidation completed!");
    }

    // Test submitInitialReportsNoValidation reverts on stale timestamp
    function testSubmitInitialReportsNoValidation_RevertsOnStaleTimestamp() public {
        console.log("=== Testing submitInitialReportsNoValidation revert on stale timestamp ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        // Use a stale timestamp that's definitely out of bounds
        // Current time is 1000000, pass 900000 (100000 seconds in the past)
        // With a bound of 10, this should definitely fail
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(openOracleBatcher.ActionSafetyFailure.selector, "timestamp"));
        batcher.submitInitialReportsNoValidation(
            reports,
            1e18,
            2000e18,
            900000,   // Stale timestamp - 100000 seconds in the past
            1000000,  // Current block number is valid
            10,       // Only 10 second bound
            10        // Only 10 block bound
        );

        console.log("[PASS] submitInitialReportsNoValidation correctly reverts on stale timestamp!");
    }

    // Test disputeReportSafe with validation
    function testDisputeReportSafe() public {
        console.log("=== Testing disputeReportSafe ===");

        // 1. Create report with keepFee = true
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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
                keepFee: true,
                protocolFeeRecipient: alice
            })
        );

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // 2. Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        // 3. Wait for dispute delay
        vm.warp(block.timestamp + 6);

        // 4. Get updated oracle data for validation
        (openOracleBatcher.oracleParams memory p,) = _getOracleParams(reportId);

        // 5. Build dispute data
        openOracleBatcher.DisputeData[] memory disputes = new openOracleBatcher.DisputeData[](1);
        disputes[0] = openOracleBatcher.DisputeData({
            reportId: reportId,
            tokenToSwap: address(token1),
            newAmount1: 1.1e18,
            newAmount2: 2100e18,
            amt2Expected: 2000e18,
            stateHash: stateHash
        });

        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protocolFee = (1e18 * 1000) / 1e7;
        uint256 batchAmount1 = 1e18 + 1.1e18 + fee + protocolFee;

        vm.prank(alice);
        batcher.disputeReportSafe(
            disputes,
            p,
            batchAmount1,
            100e18,
            block.timestamp,
            block.number,
            10,
            10
        );

        (uint256 newAmount1,,,,,,,, bool disputeOccurred,) = oracle.reportStatus(reportId);
        assertEq(newAmount1, 1.1e18);
        assertTrue(disputeOccurred);
        console.log("[PASS] disputeReportSafe completed!");
    }

    // Test disputeReportsNoValidation with timing checks
    function testDisputeReportsNoValidation() public {
        console.log("=== Testing disputeReportsNoValidation ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 6);

        openOracleBatcher.DisputeData[] memory disputes = new openOracleBatcher.DisputeData[](1);
        disputes[0] = openOracleBatcher.DisputeData({
            reportId: reportId,
            tokenToSwap: address(token1),
            newAmount1: 1.1e18,
            newAmount2: 2100e18,
            amt2Expected: 2000e18,
            stateHash: stateHash
        });

        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protocolFee = (1e18 * 1000) / 1e7;
        uint256 batchAmount1 = 1e18 + 1.1e18 + fee + protocolFee;

        vm.prank(alice);
        batcher.disputeReportsNoValidation(
            disputes,
            batchAmount1,
            100e18,
            block.timestamp,
            block.number,
            10,
            10
        );

        (uint256 currentAmount1,,,,,,,,,) = oracle.reportStatus(reportId);
        assertEq(currentAmount1, 1.1e18);
        console.log("[PASS] disputeReportsNoValidation completed!");
    }

    // Test safeSettleReports with stateHash validation and timing checks
    function testSafeSettleReports() public {
        console.log("=== Testing safeSettleReports ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 301);

        openOracleBatcher.SafeSettleData[] memory settles = new openOracleBatcher.SafeSettleData[](1);
        settles[0] = openOracleBatcher.SafeSettleData({
            reportId: reportId,
            stateHash: stateHash
        });

        uint256 balanceBefore = address(this).balance;

        batcher.safeSettleReports(
            settles,
            block.timestamp,
            block.number,
            10,
            10
        );

        uint256 balanceAfter = address(this).balance;
        assertTrue(balanceAfter > balanceBefore, "Should receive settler reward");

        (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
        assertTrue(isDistributed);
        console.log("[PASS] safeSettleReports completed!");
    }

    // Test safeSettleReports skips wrong stateHash
    function testSafeSettleReports_SkipsWrongStateHash() public {
        console.log("=== Testing safeSettleReports skips wrong stateHash ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 301);

        openOracleBatcher.SafeSettleData[] memory settles = new openOracleBatcher.SafeSettleData[](1);
        settles[0] = openOracleBatcher.SafeSettleData({
            reportId: reportId,
            stateHash: bytes32(uint256(12345)) // WRONG stateHash
        });

        batcher.safeSettleReports(settles, block.timestamp, block.number, 10, 10);

        // Should NOT be settled because stateHash didn't match
        (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
        assertFalse(isDistributed);
        console.log("[PASS] safeSettleReports correctly skips wrong stateHash!");
    }

    // ============ BALANCE VALIDATION TESTS ============

    // Test that batcher doesn't leak funds on initial report
    function testBatcherNoLeakOnInitialReport() public {
        console.log("=== Testing batcher doesn't leak funds on initial report ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Record balances BEFORE
        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);
        uint256 batcherToken1Before = token1.balanceOf(address(batcher));
        uint256 batcherToken2Before = token2.balanceOf(address(batcher));
        uint256 oracleToken1Before = token1.balanceOf(address(oracle));
        uint256 oracleToken2Before = token2.balanceOf(address(oracle));

        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        vm.prank(bob);
        batcher.submitInitialReports(reports, 1e18, 2000e18);

        // Record balances AFTER
        uint256 bobToken1After = token1.balanceOf(bob);
        uint256 bobToken2After = token2.balanceOf(bob);
        uint256 batcherToken1After = token1.balanceOf(address(batcher));
        uint256 batcherToken2After = token2.balanceOf(address(batcher));
        uint256 oracleToken1After = token1.balanceOf(address(oracle));
        uint256 oracleToken2After = token2.balanceOf(address(oracle));

        // Validate: Batcher should have ZERO balance change (no leaks)
        assertEq(batcherToken1After, batcherToken1Before, "Batcher leaked token1");
        assertEq(batcherToken2After, batcherToken2Before, "Batcher leaked token2");

        // Validate: Bob should have paid exactly 1e18 token1 and 2000e18 token2
        assertEq(bobToken1Before - bobToken1After, 1e18, "Bob paid wrong token1 amount");
        assertEq(bobToken2Before - bobToken2After, 2000e18, "Bob paid wrong token2 amount");

        // Validate: Oracle should have received exactly 1e18 token1 and 2000e18 token2
        assertEq(oracleToken1After - oracleToken1Before, 1e18, "Oracle received wrong token1 amount");
        assertEq(oracleToken2After - oracleToken2Before, 2000e18, "Oracle received wrong token2 amount");

        console.log("[PASS] No funds leaked on initial report!");
    }

    // Test that batcher doesn't leak funds on dispute
    function testBatcherNoLeakOnDispute() public {
        console.log("=== Testing batcher doesn't leak funds on dispute ===");

        uint256 oldAmount1 = 1e18;
        uint256 oldAmount2 = 2000e18;
        uint256 newAmount1 = 1.1e18;
        uint256 newAmount2 = 2100e18;
        uint24 feePercentage = 3000;
        uint24 protocolFeeRate = 1000;

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: oldAmount1,
                feePercentage: feePercentage,
                multiplier: 110,
                settlementTime: 300,
                escalationHalt: 10e18,
                disputeDelay: 5,
                protocolFee: protocolFeeRate,
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Bob submits initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, oldAmount1, oldAmount2, stateHash);

        vm.warp(block.timestamp + 6);

        // Calculate expected payments based on _handleToken1Swap logic:
        // fee = oldAmount1 * feePercentage / 1e7
        // protocolFee = oldAmount1 * protocolFee / 1e7
        // Disputer pays: newAmount1 + oldAmount1 + fee + protocolFee (token1)
        // Disputer pays: newAmount2 - oldAmount2 (token2) if newAmount2 > oldAmount2
        uint256 fee = (oldAmount1 * feePercentage) / 1e7;
        uint256 protocolFee = (oldAmount1 * protocolFeeRate) / 1e7;
        uint256 expectedToken1Paid = newAmount1 + oldAmount1 + fee + protocolFee;
        uint256 expectedToken2Paid = newAmount2 - oldAmount2; // 100e18

        // Previous reporter (Bob) receives: 2 * oldAmount1 + fee
        uint256 expectedBobToken1Received = 2 * oldAmount1 + fee;

        // Record balances BEFORE
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 aliceToken2Before = token2.balanceOf(alice);
        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 batcherToken1Before = token1.balanceOf(address(batcher));
        uint256 batcherToken2Before = token2.balanceOf(address(batcher));

        openOracleBatcher.DisputeData[] memory disputes = new openOracleBatcher.DisputeData[](1);
        disputes[0] = openOracleBatcher.DisputeData({
            reportId: reportId,
            tokenToSwap: address(token1),
            newAmount1: newAmount1,
            newAmount2: newAmount2,
            amt2Expected: oldAmount2,
            stateHash: stateHash
        });

        vm.prank(alice);
        batcher.disputeReports(disputes, expectedToken1Paid, expectedToken2Paid);

        // Record balances AFTER
        uint256 aliceToken1After = token1.balanceOf(alice);
        uint256 aliceToken2After = token2.balanceOf(alice);
        uint256 bobToken1After = token1.balanceOf(bob);
        uint256 batcherToken1After = token1.balanceOf(address(batcher));
        uint256 batcherToken2After = token2.balanceOf(address(batcher));

        // CRITICAL: Batcher has ZERO balance (no leaks)
        assertEq(batcherToken1After, batcherToken1Before, "Batcher leaked token1");
        assertEq(batcherToken2After, batcherToken2Before, "Batcher leaked token2");

        // Alice paid exact expected amounts
        assertEq(aliceToken1Before - aliceToken1After, expectedToken1Paid, "Alice token1 payment wrong");
        assertEq(aliceToken2Before - aliceToken2After, expectedToken2Paid, "Alice token2 payment wrong");

        // Bob received his stake back + fee
        assertEq(bobToken1After - bobToken1Before, expectedBobToken1Received, "Bob token1 receipt wrong");

        console.log("[PASS] No funds leaked on dispute!");
    }

    // Test that batcher returns excess tokens after batch operations
    function testBatcherReturnsExcessTokens() public {
        console.log("=== Testing batcher returns excess tokens ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);

        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        // Send MORE than needed (excess of 5e18 token1 and 500e18 token2)
        vm.prank(bob);
        batcher.submitInitialReports(reports, 6e18, 2500e18);

        uint256 bobToken1After = token1.balanceOf(bob);
        uint256 bobToken2After = token2.balanceOf(bob);
        uint256 batcherToken1After = token1.balanceOf(address(batcher));
        uint256 batcherToken2After = token2.balanceOf(address(batcher));

        // Batcher should have zero balance
        assertEq(batcherToken1After, 0, "Batcher retained excess token1");
        assertEq(batcherToken2After, 0, "Batcher retained excess token2");

        // Bob should have only lost the actual amount needed (1e18 and 2000e18)
        assertEq(bobToken1Before - bobToken1After, 1e18, "Bob lost more token1 than needed");
        assertEq(bobToken2Before - bobToken2After, 2000e18, "Bob lost more token2 than needed");

        console.log("[PASS] Batcher correctly returns excess tokens!");
    }

    // Test ETH handling on settle (settler reward)
    function testBatcherETHHandlingOnSettle() public {
        console.log("=== Testing batcher ETH handling on settle ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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
                settlerReward: 0.005 ether, // 0.005 ETH settler reward
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: 0,
                keepFee: false,
                protocolFeeRecipient: address(0)
            })
        );

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 301);

        // Record ETH balances
        uint256 callerETHBefore = address(this).balance;
        uint256 batcherETHBefore = address(batcher).balance;

        openOracleBatcher.SettleData[] memory settles = new openOracleBatcher.SettleData[](1);
        settles[0] = openOracleBatcher.SettleData({reportId: reportId});

        batcher.settleReports(settles);

        uint256 callerETHAfter = address(this).balance;
        uint256 batcherETHAfter = address(batcher).balance;

        // Batcher should not retain any ETH
        assertEq(batcherETHAfter, batcherETHBefore, "Batcher retained ETH");

        // Caller should receive settler reward (0.005 ETH)
        assertEq(callerETHAfter - callerETHBefore, 0.005 ether, "Caller didn't receive correct settler reward");

        console.log("[PASS] ETH handling on settle is correct!");
    }

    // Test full lifecycle balance accounting
    function testFullLifecycleBalanceAccounting() public {
        console.log("=== Testing full lifecycle balance accounting ===");

        // Record initial balances
        uint256 aliceToken1Initial = token1.balanceOf(alice);
        uint256 aliceToken2Initial = token2.balanceOf(alice);
        uint256 bobToken1Initial = token1.balanceOf(bob);
        uint256 bobToken2Initial = token2.balanceOf(bob);

        // Alice creates report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Bob submits initial report via batcher (offering 1 token1 for 2000 token2)
        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        vm.prank(bob);
        batcher.submitInitialReports(reports, 1e18, 2000e18);

        vm.warp(block.timestamp + 6);

        // Alice disputes via batcher (better price: 1.1 token1 for 2100 token2)
        // Alice pays token1, receives token2 from Bob's report
        openOracleBatcher.DisputeData[] memory disputes = new openOracleBatcher.DisputeData[](1);
        disputes[0] = openOracleBatcher.DisputeData({
            reportId: reportId,
            tokenToSwap: address(token1),
            newAmount1: 1.1e18,
            newAmount2: 2100e18,
            amt2Expected: 2000e18,
            stateHash: stateHash
        });

        uint256 fee = (1e18 * 3000) / 1e7;
        uint256 protocolFee = (1e18 * 1000) / 1e7;
        uint256 batchAmount1 = 1e18 + 1.1e18 + fee + protocolFee + 1e18; // Extra buffer

        vm.prank(alice);
        batcher.disputeReports(disputes, batchAmount1, 100e18);

        // Settle
        vm.warp(block.timestamp + 301);
        oracle.settle(reportId);

        // Record final balances
        uint256 aliceToken1Final = token1.balanceOf(alice);
        uint256 aliceToken2Final = token2.balanceOf(alice);
        uint256 bobToken1Final = token1.balanceOf(bob);
        uint256 bobToken2Final = token2.balanceOf(bob);
        uint256 batcherToken1Final = token1.balanceOf(address(batcher));
        uint256 batcherToken2Final = token2.balanceOf(address(batcher));

        // Batcher should have ZERO of both tokens
        assertEq(batcherToken1Final, 0, "Batcher has leftover token1");
        assertEq(batcherToken2Final, 0, "Batcher has leftover token2");

        // Log the accounting for verification
        console.log("Alice token1 change:", aliceToken1Initial > aliceToken1Final ?
            aliceToken1Initial - aliceToken1Final : aliceToken1Final - aliceToken1Initial);
        console.log("Alice token2 change:", aliceToken2Final > aliceToken2Initial ?
            aliceToken2Final - aliceToken2Initial : aliceToken2Initial - aliceToken2Final);
        console.log("Bob token1 change:", bobToken1Initial > bobToken1Final ?
            bobToken1Initial - bobToken1Final : bobToken1Final - bobToken1Initial);
        console.log("Bob token2 change:", bobToken2Initial > bobToken2Final ?
            bobToken2Initial - bobToken2Final : bobToken2Final - bobToken2Initial);

        console.log("[PASS] Full lifecycle balance accounting verified!");
    }

    // Test that safe functions also don't leak funds
    function testSafeFunctionsNoLeak() public {
        console.log("=== Testing safe functions don't leak funds ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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
                keepFee: true,
                protocolFeeRecipient: alice
            })
        );

        (openOracleBatcher.oracleParams memory p, bytes32 stateHash) = _getOracleParams(reportId);
        p.currentAmount1 = 0;
        p.currentAmount2 = 0;

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);

        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        // Send extra tokens
        vm.prank(bob);
        batcher.submitInitialReportSafe(
            reports,
            p,
            5e18,   // Extra token1
            3000e18, // Extra token2
            block.timestamp,
            block.number,
            10,
            10
        );

        uint256 bobToken1After = token1.balanceOf(bob);
        uint256 bobToken2After = token2.balanceOf(bob);
        uint256 batcherToken1After = token1.balanceOf(address(batcher));
        uint256 batcherToken2After = token2.balanceOf(address(batcher));

        // Batcher should have zero
        assertEq(batcherToken1After, 0, "Safe function leaked token1");
        assertEq(batcherToken2After, 0, "Safe function leaked token2");

        // Bob should only lose actual amounts
        assertEq(bobToken1Before - bobToken1After, 1e18, "Bob lost more token1 than needed (safe)");
        assertEq(bobToken2Before - bobToken2After, 2000e18, "Bob lost more token2 than needed (safe)");

        console.log("[PASS] Safe functions don't leak funds!");
    }

    // Test that safe functions revert when timestamp is in the future (lower bound check)
    function testSafeFunctions_RevertOnFutureTimestamp() public {
        console.log("=== Testing safe functions revert on future timestamp ===");

        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
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

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        openOracleBatcher.InitialReportData[] memory reports = new openOracleBatcher.InitialReportData[](1);
        reports[0] = openOracleBatcher.InitialReportData({
            reportId: reportId,
            amount1: 1e18,
            amount2: 2000e18,
            stateHash: stateHash
        });

        // Pass a future timestamp that's beyond the bound
        uint256 futureTimestamp = block.timestamp + 100;

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(openOracleBatcher.ActionSafetyFailure.selector, "timestamp"));
        batcher.submitInitialReportsNoValidation(
            reports,
            1e18,
            2000e18,
            futureTimestamp,
            block.number,
            10, // Only 10 second bound - future timestamp is 100 seconds ahead
            10
        );

        console.log("[PASS] Safe functions correctly revert on future timestamp!");
    }
}
