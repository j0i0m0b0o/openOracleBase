// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapMinOutTest
 * @notice Tests for minOut protection mechanism
 *
 * fulfillAmt calculation:
 *   fulfillAmt = (sellAmt * oracleAmount2) / oracleAmount1
 *   fulfillAmt -= fulfillAmt * fulfillmentFee / 1e7
 *
 * If fulfillAmt < minOut -> refund both parties
 */
contract OpenSwapMinOutTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal initialReporter = address(0x3);
    address internal settler = address(0x4);

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

    function _createSwapWithMinOut(uint256 minOut) internal returns (uint256 swapId) {
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

        // No slippage check for minOut tests
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
            minOut,
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

    function _submitReportAndSettle(uint256 swapId, uint256 amount1, uint256 amount2) internal {
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.prank(initialReporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);
    }

    // Helper to calculate expected fulfillAmt
    function _calcFulfillAmt(uint256 amount1, uint256 amount2) internal pure returns (uint256) {
        uint256 fulfillAmt = (SELL_AMT * amount2) / amount1;
        fulfillAmt -= fulfillAmt * STARTING_FEE / 1e7;
        return fulfillAmt;
    }

    // ============ MinOut Pass Tests ============

    function testMinOut_ExactlyMet() public {
        // With amount1=1e18, amount2=2000e18:
        // fulfillAmt = 10e18 * 2000e18 / 1e18 = 20000e18
        // fulfillAmt -= 20000e18 * 10000 / 1e7 = 20000e18 - 20e18 = 19980e18
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        assertEq(expectedFulfill, 19980e18, "Expected fulfillAmt calculation");

        uint256 swapId = _createSwapWithMinOut(expectedFulfill); // minOut exactly equals fulfillAmt
        _matchSwap(swapId);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive exact fulfillAmt");
    }

    function testMinOut_Exceeded() public {
        // minOut = 19000e18, but fulfillAmt will be 19980e18
        uint256 minOut = 19000e18;
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive fulfillAmt > minOut");
        assertGt(expectedFulfill, minOut, "fulfillAmt should exceed minOut");
    }

    function testMinOut_ZeroReverts() public {
        // minOut = 0 is rejected by the contract
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

        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "zero amounts"));
        swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            0, // minOut = 0 should revert
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

    // ============ MinOut Fail Tests (Refund) ============

    function testMinOut_NotMet_Refund() public {
        // Set high minOut that won't be met
        uint256 minOut = 25000e18;
        // fulfillAmt will be 19980e18 < 25000e18

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Both parties refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
        assertEq(buyToken.balanceOf(swapper), 0, "Swapper should NOT receive buyToken");
    }

    function testMinOut_BarelyNotMet_Refund() public {
        // fulfillAmt = 19980e18, set minOut to 19980e18 + 1
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        uint256 minOut = expectedFulfill + 1;

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Refunded because minOut missed by 1 wei
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    function testMinOut_LowOraclePrice_Refund() public {
        // Reasonable minOut but oracle reports lower price
        uint256 minOut = 15000e18;

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        // Report lower amount2 -> lower fulfillAmt
        // fulfillAmt = 10e18 * 1400e18 / 1e18 = 14000e18 (minus fee ~13986e18) < 15000e18
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 1400e18);
        assertLt(expectedFulfill, minOut, "Expected fulfillAmt < minOut");

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 1400e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    // ============ Edge Cases ============

    function testMinOut_HighOraclePrice_StillPasses() public {
        // Very high oracle price should easily pass minOut
        uint256 minOut = 19000e18;

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        // High amount2 means high fulfillAmt
        // fulfillAmt = 10e18 * 2500e18 / 1e18 = 25000e18 (minus fee) = 24975e18
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2500e18);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2500e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive high fulfillAmt");
        assertGt(expectedFulfill, minOut, "fulfillAmt should exceed minOut");
    }

    function testMinOut_FulfillmentFeeImpact() public {
        // Verify the fee actually impacts the fulfillAmt calculation
        // Without fee: 10e18 * 2000e18 / 1e18 = 20000e18
        // With 0.1% fee: 20000e18 - 20e18 = 19980e18

        uint256 withoutFee = (SELL_AMT * 2000e18) / INITIAL_LIQUIDITY;
        uint256 withFee = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        assertEq(withoutFee, 20000e18, "Without fee calculation");
        assertEq(withFee, 19980e18, "With fee calculation");
        assertEq(withoutFee - withFee, 20e18, "Fee should be 20e18");

        // If minOut is between these values, swap should fail
        uint256 minOut = 19990e18; // Between 19980 and 20000

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        uint256 swapId = _createSwapWithMinOut(minOut);
        _matchSwap(swapId);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Should be refunded because actual fulfillAmt (19980) < minOut (19990)
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Should be refunded due to fee");
    }
}
