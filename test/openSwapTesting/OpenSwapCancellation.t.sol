// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

contract OpenSwapCancellationTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal initialReporter = address(0x3);
    address internal randomUser = address(0x5);

    // Oracle params
    uint256 constant SETTLER_REWARD = 0.001 ether;
    uint256 constant BOUNTY_AMOUNT = 0.01 ether;
    uint256 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant SWAP_FEE = 3000;
    uint24 constant PROTOCOL_FEE = 1000;
    uint48 constant LATENCY_BAILOUT = 600;
    uint48 constant MAX_GAME_TIME = 7200;

    // Swap params
    uint256 constant SELL_AMT = 10e18;
    uint256 constant MIN_OUT = 19000e18;
    uint256 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint256 constant GAS_COMPENSATION = 0.001 ether;

    // FulfillFeeParams
    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS = 10;

    function setUp() public {
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        swapContract = new openSwap(address(oracle), address(bountyContract));

        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(initialReporter, 100e18);
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(initialReporter, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(initialReporter, 10 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);

        vm.startPrank(initialReporter);
        sellToken.approve(address(bountyContract), type(uint256).max);
        buyToken.approve(address(bountyContract), type(uint256).max);
        vm.stopPrank();
    }

    function _createSwap() internal returns (uint256 swapId) {
        vm.startPrank(swapper);

        openSwap.OracleParams memory oracleParams = openSwap.OracleParams({
            settlerReward: SETTLER_REWARD,
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            latencyBailout: LATENCY_BAILOUT,
            maxGameTime: MAX_GAME_TIME,
            blocksPerSecond: 500,
            disputeDelay: DISPUTE_DELAY,
            swapFee: SWAP_FEE,
            protocolFee: PROTOCOL_FEE,
            multiplier: 110,
            timeType: true
        });

        openSwap.SlippageParams memory slippageParams = openSwap.SlippageParams({
            priceTolerated: 0,
            toleranceRange: 0
        });

        openSwap.FulfillFeeParams memory fulfillFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });

        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            oracleParams,
            slippageParams,
            fulfillFeeParams
        );

        vm.stopPrank();
    }

    function _matchSwap(uint256 swapId) internal {
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();
    }

    // ============ cancelSwap Tests ============

    function testCancelSwap_Success() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapId = _createSwap();

        // Verify tokens were transferred
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper should have sent sellToken");
        assertEq(swapper.balance, swapperEthBefore - ethToSend, "Swapper should have sent ETH");

        // Cancel the swap
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        // Verify swap state
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.cancelled, "Swap should be cancelled");
        assertFalse(s.matched, "Swap should not be matched");
        assertFalse(s.finished, "Swap should not be finished");

        // Verify tokens returned
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(swapper.balance, swapperEthBefore, "Swapper should have ETH back");

        // Verify contract has no tokens
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "Contract should have no sellToken");
    }

    function testCancelSwap_FailsIfNotSwapper() public {
        uint256 swapId = _createSwap();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "not swapper"));
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_FailsIfAlreadyMatched() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "already matched"));
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_FailsIfAlreadyCancelled() public {
        uint256 swapId = _createSwap();

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "cancelled"));
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_FailsIfNotActive() public {
        // SwapId 999 doesn't exist, so active = false
        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "not swapper"));
        swapContract.cancelSwap(999);
    }

    // ============ bailOut Tests ============

    function testBailOut_SuccessLatencyTimeout() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Verify tokens transferred
        assertEq(sellToken.balanceOf(address(swapContract)), SELL_AMT, "Contract should hold sellToken");
        assertEq(buyToken.balanceOf(address(swapContract)), MIN_FULFILL_LIQUIDITY, "Contract should hold buyToken");

        // Warp past latency bailout time without initial report
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        vm.roll(block.number + (LATENCY_BAILOUT + 1) / 2);

        // Anyone can call bailOut
        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        // Verify swap state
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Verify refunds
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");

        // Verify contract empty
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "Contract should have no sellToken");
        assertEq(buyToken.balanceOf(address(swapContract)), 0, "Contract should have no buyToken");
    }

    function testBailOut_FailsIfNotMatched() public {
        uint256 swapId = _createSwap();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "not matched"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_FailsIfCancelled() public {
        uint256 swapId = _createSwap();

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "not matched"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_FailsIfFinished() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Warp past latency bailout
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        vm.roll(block.number + (LATENCY_BAILOUT + 1) / 2);

        // First bailout succeeds
        swapContract.bailOut(swapId);

        // Second bailout fails
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "finished"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_NoOpIfLatencyNotReached() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Don't warp - latency not reached and no initial report
        // But also oracle not distributed, so neither condition met
        // Function should be a no-op (no revert, but no state change)
        swapContract.bailOut(swapId);

        // Verify swap is NOT finished
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertFalse(s.finished, "Swap should NOT be finished - conditions not met");
        assertTrue(s.matched, "Swap should still be matched");
    }

    function testBailOut_OracleDistributedButCallbackSucceeds() public {
        // When callback succeeds, swap is finished, bailout reverts
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.startPrank(initialReporter);
        bountyContract.submitInitialReport(reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        oracle.settle(reportId);

        // Swap should be finished via callback
        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished via callback");

        // Calling bailOut on finished swap should revert
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "finished"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_OracleDistributedButCallbackFails() public {
        // Edge case: oracle settles (isDistributed=true) but callback fails
        // This leaves swap.finished = false, so bailout should work

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.startPrank(initialReporter);
        bountyContract.submitInitialReport(reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);
        vm.stopPrank();

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // Mock the onSettle callback to revert (simulating callback failure)
        vm.mockCallRevert(
            address(swapContract),
            abi.encodeWithSelector(openSwap.onSettle.selector),
            "callback failed"
        );

        // Settle oracle - callback will fail but oracle still marks isDistributed = true
        oracle.settle(reportId);

        // Clear the mock
        vm.clearMockedCalls();

        // Verify oracle is distributed
        (,,,,,,,,, bool isDistributed) = oracle.reportStatus(reportId);
        assertTrue(isDistributed, "Oracle should be distributed");

        // Verify swap is NOT finished (callback failed)
        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertFalse(sAfter.finished, "Swap should NOT be finished since callback failed");

        // Now bailout should work via the isDistributed path
        swapContract.bailOut(swapId);

        // Verify swap is now finished
        openSwap.Swap memory sFinal = swapContract.getSwap(swapId);
        assertTrue(sFinal.finished, "Swap should be finished after bailout");

        // Verify refunds happened
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    function testBailOut_FailsIfReportIdZero() public {
        // Create swap but don't match - reportId will be 0
        uint256 swapId = _createSwap();

        // Can't call bailOut on unmatched swap
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "not matched"));
        swapContract.bailOut(swapId);
    }

    function testBailOut_ExactLatencyBoundary() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 matchTime = s.start;

        // Warp to exactly latency bailout time - should be no-op (need to be > not >=)
        vm.warp(matchTime + LATENCY_BAILOUT);
        vm.roll(block.number + LATENCY_BAILOUT / 2);
        swapContract.bailOut(swapId);

        openSwap.Swap memory sMid = swapContract.getSwap(swapId);
        assertFalse(sMid.finished, "Swap should NOT be finished at exact boundary");

        // Warp 1 second more - should succeed
        vm.warp(matchTime + LATENCY_BAILOUT + 1);
        vm.roll(block.number + 1);
        swapContract.bailOut(swapId);

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished after boundary");
    }

    function testCancelSwap_MatcherCannotCancel() public {
        uint256 swapId = _createSwap();

        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "not swapper"));
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_EmitsEvent() public {
        uint256 swapId = _createSwap();

        vm.prank(swapper);
        vm.expectEmit(true, false, false, false);
        emit openSwap.SwapCancelled(swapId);
        swapContract.cancelSwap(swapId);
    }

    function testCancelSwap_MultipleSwapsCancelIndependently() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        // Create two swaps
        uint256 swapId1 = _createSwap();
        uint256 swapId2 = _createSwap();

        // Cancel only the first one
        vm.prank(swapper);
        swapContract.cancelSwap(swapId1);

        openSwap.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwap.Swap memory s2 = swapContract.getSwap(swapId2);

        assertTrue(s1.cancelled, "Swap 1 should be cancelled");
        assertFalse(s2.cancelled, "Swap 2 should not be cancelled");
        assertTrue(s2.active, "Swap 2 should still be active");

        // Swapper should have one swap's worth of tokens back
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper should have 1 SELL_AMT still locked");

        // Contract should still hold swap2's tokens
        assertEq(sellToken.balanceOf(address(swapContract)), SELL_AMT, "Contract should hold swap2's sellToken");
    }
}
