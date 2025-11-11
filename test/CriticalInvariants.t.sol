// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/OpenOracle.sol";

// Minimal mock token for testing
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Callback that tracks execution
contract TestCallback {
    struct Execution {
        bool called;
        uint256 gasReceived;
        uint256 reportId;
        uint256 timestamp;
    }

    mapping(uint256 => Execution) public executions;
    mapping(uint256 => uint256) public executionCount;

    function onOracleSettle(uint256 reportId, uint256, uint256, address, address) external {
        executions[reportId] = Execution({
            called: true,
            gasReceived: gasleft(),
            reportId: reportId,
            timestamp: block.timestamp
        });
        executionCount[reportId]++;
    }
}

contract CriticalInvariantsTest is Test {
    OpenOracle oracle;
    MockToken token1;
    MockToken token2;
    TestCallback callback;

    // The TestCallback writes multiple storage slots per call (mapping to struct + counter),
    // which can exceed 100k gas due to multiple SSTOREs from zero. Use a higher limit
    // to ensure the callback can complete, while still validating the full-attempt invariant.
    uint256 constant CALLBACK_GAS_LIMIT = 200000;
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    function getCallbackCalled(uint256 reportId) internal view returns (bool) {
        (bool called,,,) = callback.executions(reportId);
        return called;
    }

    function setUp() public {
        oracle = new OpenOracle();
        token1 = new MockToken();
        token2 = new MockToken();
        callback = new TestCallback();

        // Setup tokens
        token1.mint(ALICE, 1000e18);
        token2.mint(ALICE, 1000e18);
        token1.mint(BOB, 1000e18);
        token2.mint(BOB, 1000e18);

        // Setup ETH
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
    }

    // Helper to create a report with callback
    function createReportWithCallback() internal returns (uint256) {
        vm.startPrank(ALICE);

        uint256 reportId = oracle.createReportInstance{value: 0.01 ether}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(60),
                escalationHalt: 10e18,
                disputeDelay: uint24(0),
                protocolFee: uint24(1000),
                settlerReward: 0.001 ether,
                timeType: true,
                callbackContract: address(callback),
                callbackSelector: TestCallback.onOracleSettle.selector,
                trackDisputes: false,
                callbackGasLimit: uint32(CALLBACK_GAS_LIMIT),
                keepFee: true,
                protocolFeeRecipient: ALICE
            })
        );

        // Submit initial report
        token1.approve(address(oracle), 1e18);
        token2.approve(address(oracle), 1e18);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        oracle.submitInitialReport(reportId, 1e18, 1e18, stateHash);

        vm.stopPrank();
        return reportId;
    }

    // CRITICAL INVARIANT 1: Full-attempt invariant
    // If a callback is configured and isDistributed = true,
    // then the callback MUST have received a full gas attempt
    function test_Invariant1_FullGasAttempt() public {
        uint256 reportId = createReportWithCallback();

        // Fast forward to settlement time
        vm.warp(block.timestamp + 61);

        // Test 1: Insufficient gas should revert entire transaction
        vm.startPrank(BOB);
        uint256 insufficientGas = 80000; // Not enough for callback to get CALLBACK_GAS_LIMIT

        // This should revert due to gas check
        vm.expectRevert();
        oracle.settle{gas: insufficientGas}(reportId);

        // Verify nothing was distributed
        (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
        assertFalse(isDistributed, "Should not be distributed after failed settle");
        (bool called,,,) = callback.executions(reportId);
        assertFalse(called, "Callback should not be executed");

        // Test 2: Sufficient gas should succeed
        uint256 sufficientGas = 500000;
        oracle.settle{gas: sufficientGas}(reportId);

        // Verify distribution and callback execution
        (,,,,,,,,, isDistributed) = oracle.reportStatus(reportId);
        assertTrue(isDistributed, "Should be distributed after successful settle");
        (bool called2, uint256 gasReceived,,) = callback.executions(reportId);
        assertTrue(called2, "Callback should be executed");

        // Verify callback got close to its gas limit
        assertGt(gasReceived, CALLBACK_GAS_LIMIT - 10000, "Callback should receive near full gas");

        vm.stopPrank();
    }

    // CRITICAL INVARIANT 2: Atomicity invariant
    // No execution path where callback executes but isDistributed remains false
    function test_Invariant2_Atomicity() public {
        uint256 reportId = createReportWithCallback();

        // Fast forward to settlement time
        vm.warp(block.timestamp + 61);

        // Try to settle with edge case gas amounts
        vm.startPrank(BOB);

        // Test various gas amounts
        uint256[] memory gasAmounts = new uint256[](3);
        gasAmounts[0] = 70000;  // Very low
        gasAmounts[1] = 100000; // Borderline
        gasAmounts[2] = 500000; // Plenty

        for (uint256 i = 0; i < gasAmounts.length; i++) {
            // Reset state
            setUp();
            reportId = createReportWithCallback();
            vm.warp(block.timestamp + 61);
            vm.startPrank(BOB);

            try oracle.settle{gas: gasAmounts[i]}(reportId) {
                // If settle succeeded
                (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);

                if (isDistributed) {
                    // If distributed, callback must have been attempted
                    assertTrue(
                        getCallbackCalled(reportId),
                        "Atomicity violated: isDistributed=true but callback not called"
                    );
                }

                if (getCallbackCalled(reportId)) {
                    // If callback was called, must be distributed
                    assertTrue(
                        isDistributed,
                        "Atomicity violated: callback called but isDistributed=false"
                    );
                }
            } catch {
                // If settle reverted, neither should be true
                (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
                assertFalse(isDistributed, "Should not be distributed after revert");
                assertFalse(getCallbackCalled(reportId), "Callback should not persist after revert");
            }

            vm.stopPrank();
        }
    }

    // Test that disputes don't affect isDistributed
    function test_DisputesDoNotSetIsDistributed() public {
        uint256 reportId = createReportWithCallback();

        // Dispute the report
        vm.startPrank(BOB);

        uint256 newAmount1 = 1.1e18; // 10% more
        uint256 newAmount2 = 0.9e18; // Different price

        token1.approve(address(oracle), 10e18);
        token2.approve(address(oracle), 10e18);
        token1.mint(BOB, 10e18);
        token2.mint(BOB, 10e18);

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        oracle.disputeAndSwap(reportId, address(token1), newAmount1, newAmount2, 1e18, stateHash);

        vm.stopPrank();

        // Check that isDistributed is still false
        (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
        assertFalse(isDistributed, "Dispute should not set isDistributed");
        assertFalse(getCallbackCalled(reportId), "Callback should not be called by dispute");

        // Now settle and verify callback works
        vm.warp(block.timestamp + 61);
        vm.prank(BOB);
        oracle.settle{gas: 500000}(reportId);

        (,,,,,,,, isDistributed,) = oracle.reportStatus(reportId);
        assertTrue(isDistributed, "Should be distributed after settle");
        assertTrue(getCallbackCalled(reportId), "Callback should be called after settle");
    }

    // Test callback execution count
    function test_CallbackOnlyCalledOnce() public {
        uint256 reportId = createReportWithCallback();

        vm.warp(block.timestamp + 61);

        // First settle
        vm.prank(BOB);
        oracle.settle{gas: 500000}(reportId);

        uint256 firstCount = callback.executionCount(reportId);
        assertEq(firstCount, 1, "Callback should be called once");

        // Try to settle again
        vm.prank(BOB);
        (uint256 price, uint256 timestamp) = oracle.settle(reportId);

        // Should return cached values
        assertGt(price, 0, "Should return price");
        assertGt(timestamp, 0, "Should return timestamp");

        // Callback count should not increase
        assertEq(callback.executionCount(reportId), firstCount, "Callback should not be called again");
    }
}
