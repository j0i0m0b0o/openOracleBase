// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapMaxGameTimeTest
 * @notice Tests for maxGameTime bailout condition
 *
 * maxGameTime allows bailout if oracle game takes too long.
 * Condition: block.timestamp - s.start > s.oracleParams.maxGameTime
 *
 * This is independent of:
 * - isLatent (no initial report within latencyBailout)
 * - isDistributed (oracle already distributed but callback failed)
 */
contract OpenSwapMaxGameTimeTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal initialReporter = address(0x3);
    address internal settler = address(0x4);
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
    uint48 constant MAX_GAME_TIME = 7200; // 2 hours

    // Swap params
    uint256 constant SELL_AMT = 10e18;
    uint256 constant MIN_OUT = 1e18;
    uint256 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint256 constant GAS_COMPENSATION = 0.001 ether;

    // FulfillFeeParams
    uint24 constant MAX_FEE = 10000;
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000;
    uint16 constant MAX_ROUNDS_FEE = 10;

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
        vm.deal(settler, 1 ether);

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
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });

        openSwap.FulfillFeeParams memory fulfillFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS_FEE
        });

        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: BOUNTY_AMOUNT,
            bountyStartAmt: BOUNTY_AMOUNT / 20,
            roundLength: 1,
            bountyToken: address(0),
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            GAS_COMPENSATION,
            oracleParams,
            slippageParams,
            fulfillFeeParams,
            bountyParams
        );

        vm.stopPrank();
    }

    function _createSwapWithMaxGameTime(uint48 maxGameTime) internal returns (uint256 swapId) {
        vm.startPrank(swapper);

        openSwap.OracleParams memory oracleParams = openSwap.OracleParams({
            settlerReward: SETTLER_REWARD,
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            latencyBailout: LATENCY_BAILOUT,
            maxGameTime: maxGameTime,
            blocksPerSecond: 500,
            disputeDelay: DISPUTE_DELAY,
            swapFee: SWAP_FEE,
            protocolFee: PROTOCOL_FEE,
            multiplier: 110,
            timeType: true
        });

        openSwap.SlippageParams memory slippageParams = openSwap.SlippageParams({
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });

        openSwap.FulfillFeeParams memory fulfillFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS_FEE
        });

        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: BOUNTY_AMOUNT,
            bountyStartAmt: BOUNTY_AMOUNT / 20,
            roundLength: 1,
            bountyToken: address(0),
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            GAS_COMPENSATION,
            oracleParams,
            slippageParams,
            fulfillFeeParams,
            bountyParams
        );

        vm.stopPrank();
    }

    function _matchSwap(uint256 swapId) internal {
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();
    }

    function _submitReport(uint256 swapId, uint256 amount1, uint256 amount2) internal {
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.prank(initialReporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, initialReporter);
    }

    // ============ maxGameTime Bailout Tests ============

    function testMaxGameTime_BailOutAfterMaxGameTimeExceeded() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report so isLatent doesn't trigger
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory sBefore = swapContract.getSwap(swapId);
        assertFalse(sBefore.finished, "Should not be finished before bailout");

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        // Warp past maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // Anyone can call bailout
        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Should be finished after bailout");

        // Both parties should get refunds
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore + SELL_AMT, "Swapper should get sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore + MIN_FULFILL_LIQUIDITY, "Matcher should get buyToken back");
    }

    function testMaxGameTime_NoOpBeforeMaxGameTime() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report so isLatent doesn't trigger
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Warp to just before maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME - 1);
        vm.roll(block.number + (MAX_GAME_TIME - 1) / 2);

        openSwap.Swap memory sBefore = swapContract.getSwap(swapId);
        assertFalse(sBefore.finished, "Should not be finished");

        // Try bailout - should revert (no bailout condition met)
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "can't bail out yet"));
        swapContract.bailOut(swapId);

        // Should still not be finished
        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertFalse(sAfter.finished, "Should still not be finished");
    }

    function testMaxGameTime_ExactBoundary() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Warp to exactly maxGameTime (not exceeded yet)
        vm.warp(block.timestamp + MAX_GAME_TIME);
        vm.roll(block.number + MAX_GAME_TIME / 2);

        // Bailout should revert - condition is > not >=
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "can't bail out yet"));
        swapContract.bailOut(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertFalse(s.finished, "Should not be finished at exact boundary");

        // Warp 1 more second
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Should be finished after boundary");
    }

    function testMaxGameTime_WorksEvenWithUnsettledGame() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report but don't settle
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Now warp past maxGameTime (but not settlement time from last report)
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // Bailout should work despite game not being settled
        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Should be finished - maxGameTime overrides unsettled game");
    }

    function testMaxGameTime_IndependentOfLatencyBailout() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Submit initial report - this disables isLatent condition
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Warp past latencyBailout but not maxGameTime
        vm.warp(block.timestamp + LATENCY_BAILOUT + 100);
        vm.roll(block.number + (LATENCY_BAILOUT + 100) / 2);

        // Bailout should revert - isLatent requires reportTimestamp == 0
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "can't bail out yet"));
        swapContract.bailOut(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertFalse(s.finished, "Should not be finished - latency bailout blocked by initial report");

        // Now warp past maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME);
        vm.roll(block.number + MAX_GAME_TIME / 2);

        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Should be finished - maxGameTime works independently");
    }

    function testMaxGameTime_AnyoneCanCallBailOut() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        // Random user (not swapper, not matcher) can call
        address nobody = address(0xDEAD);
        vm.prank(nobody);
        swapContract.bailOut(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Anyone should be able to trigger bailout");
    }

    function testMaxGameTime_SwapperAndMatcherBothGetRefunds() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        swapContract.bailOut(swapId);

        // Verify exact refund amounts
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore + SELL_AMT, "Swapper gets exact sellAmt back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore + MIN_FULFILL_LIQUIDITY, "Matcher gets exact minFulfillLiquidity back");
    }

    function testMaxGameTime_BountyRecalledOnBailout() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Don't submit initial report - bounty unclaimed

        // Warp past maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        (,,,,,,,,,,,,, bool recalledBefore,,) = bountyContract.Bounty(reportId);
        assertFalse(recalledBefore, "Bounty should not be recalled before bailout");

        swapContract.bailOut(swapId);

        (,,,,,,,,,,,,, bool recalledAfter,,) = bountyContract.Bounty(reportId);
        assertTrue(recalledAfter, "Bounty should be recalled after bailout");
    }

    function testMaxGameTime_CannotBailOutTwice() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);
        swapContract.bailOut(swapId);

        // Second bailout should revert
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "finished"));
        swapContract.bailOut(swapId);
    }

    function testMaxGameTime_MinimumValidValue() public {
        // maxGameTime must be >= settlementTime * 20
        // SETTLEMENT_TIME = 300, so minimum = 6000
        uint48 minMaxGameTime = SETTLEMENT_TIME * 20;

        uint256 swapId = _createSwapWithMaxGameTime(minMaxGameTime);
        _matchSwap(swapId);
        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Warp past minMaxGameTime
        vm.warp(block.timestamp + minMaxGameTime + 1);
        vm.roll(block.number + (minMaxGameTime + 1) / 2);

        swapContract.bailOut(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Bailout should work with minimum valid maxGameTime");
    }

    function testMaxGameTime_ValidationOnSwapCreation() public {
        vm.startPrank(swapper);

        // Try to create swap with maxGameTime too low
        openSwap.OracleParams memory badParams = openSwap.OracleParams({
            settlerReward: SETTLER_REWARD,
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            latencyBailout: LATENCY_BAILOUT,
            maxGameTime: SETTLEMENT_TIME * 20 - 1, // Below minimum
            blocksPerSecond: 500,
            disputeDelay: DISPUTE_DELAY,
            swapFee: SWAP_FEE,
            protocolFee: PROTOCOL_FEE,
            multiplier: 110,
            timeType: true
        });

        openSwap.SlippageParams memory slippageParams = openSwap.SlippageParams({
            priceTolerated: 5e14,
            toleranceRange: 1e7 - 1
        });

        openSwap.FulfillFeeParams memory fulfillFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS_FEE
        });

        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: BOUNTY_AMOUNT,
            bountyStartAmt: BOUNTY_AMOUNT / 20,
            roundLength: 1,
            bountyToken: address(0),
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            GAS_COMPENSATION,
            badParams,
            slippageParams,
            fulfillFeeParams,
            bountyParams
        );

        vm.stopPrank();
    }
}
