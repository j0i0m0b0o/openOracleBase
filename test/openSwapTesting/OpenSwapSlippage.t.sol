// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBounty.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapSlippageTest
 * @notice Thorough tests for slippage protection mechanism
 *
 * toleranceCheck logic:
 *   if (priceTolerated == 0 || toleranceRange == 0) return true;  // bypassed
 *   maxDiff = (priceTolerated * toleranceRange) / 1e7;
 *   return abs(price - priceTolerated) <= maxDiff;
 *
 * If slippage check fails -> refund both parties
 */
contract OpenSwapSlippageTest is Test {
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
    uint256 constant MIN_OUT = 1e18; // Low minOut to not interfere with slippage tests
    uint256 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint256 constant FULFILLMENT_FEE = 10000;

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

    function _createSwapWithSlippage(uint256 priceTolerated, uint24 toleranceRange) internal returns (uint256 swapId) {
        vm.startPrank(swapper);

        openSwap.OracleParams memory oracleParams = openSwap.OracleParams({
            settlerReward: SETTLER_REWARD,
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            latencyBailout: LATENCY_BAILOUT,
            maxGameTime: MAX_GAME_TIME,
            disputeDelay: DISPUTE_DELAY,
            swapFee: SWAP_FEE,
            protocolFee: PROTOCOL_FEE
        });

        openSwap.SlippageParams memory slippageParams = openSwap.SlippageParams({
            priceTolerated: priceTolerated,
            toleranceRange: toleranceRange
        });

        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            oracleParams,
            slippageParams
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
        vm.prank(settler);
        oracle.settle(reportId);
    }

    // ============ Slippage Bypass Tests ============

    function testSlippage_BypassWhenPriceToleratedZero() public {
        // priceTolerated = 0 bypasses slippage check
        uint256 swapId = _createSwapWithSlippage(0, 100000); // toleranceRange set but priceTolerated = 0
        _matchSwap(swapId);

        // Report price that keeps fulfillAmt <= minFulfillLiquidity
        // fulfillAmt = SELL_AMT * price = 10e18 * 2000e18 / 1e18 = 20000e18 < 25000e18
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Swapper should have received buyToken (not refunded)
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    function testSlippage_BypassWhenToleranceRangeZero() public {
        // toleranceRange = 0 bypasses slippage check
        uint256 swapId = _createSwapWithSlippage(2000e18, 0); // priceTolerated set but toleranceRange = 0
        _matchSwap(swapId);

        // Report different price but still within liquidity bounds
        // fulfillAmt = 10e18 * 2400e18 / 1e18 = 24000e18 < 25000e18
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2400e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    function testSlippage_BypassWhenBothZero() public {
        uint256 swapId = _createSwapWithSlippage(0, 0);
        _matchSwap(swapId);

        // Price within liquidity bounds
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 1234e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    // ============ Slippage Pass Tests ============
    // NOTE: Oracle price = (amount1 * 1e18) / amount2
    // So with amount1=1e18, amount2=2000e18: price = 5e14 (not 2000e18!)

    function testSlippage_PassExactPrice() public {
        // With amount1=1e18, amount2=2000e18: oracle price = 5e14
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 100000; // 1%

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    function testSlippage_PassPriceWithinRange() public {
        // priceTolerated = 5e14, 1% tolerance = maxDiff of 5e12
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 100000; // 1%

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        // Report amount2=1990e18 -> price = 1e18*1e18/1990e18 ≈ 5.025e14 (within 1%)
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 1990e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    // ============ Slippage Fail Tests (Refund) ============

    function testSlippage_FailPriceOutsideRange() public {
        // priceTolerated = 5e14, 1% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 100000; // 1%

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        // Report amount2=1800e18 -> price = 1e18*1e18/1800e18 ≈ 5.55e14 (>10% off)
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 1800e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Both parties should be refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    function testSlippage_FailWildlyDifferentPrice() public {
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 100000; // 1%

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        // Report amount2=500e18 -> price = 2e15 (way off from 5e14)
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 500e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    // ============ Tolerance Range Tests ============

    function testSlippage_TightTolerance_Pass() public {
        // 0.1% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 10000; // 0.1%

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        // Report amount2=1999e18 -> price ≈ 5.0025e14 (within 0.1%)
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 1999e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    function testSlippage_TightTolerance_Fail() public {
        // 0.1% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 10000; // 0.1%

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        // Report amount2=1980e18 -> price ≈ 5.05e14 (~1% off, outside 0.1%)
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 1980e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }

    function testSlippage_WideTolerance_Pass() public {
        // 10% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 1000000; // 10%

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        // Report amount2=1850e18 -> price ≈ 5.4e14 (within 10%)
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 1850e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");
        assertGt(buyToken.balanceOf(swapper), 0, "Swapper should have received buyToken");
    }

    function testSlippage_WideTolerance_Fail() public {
        // 10% tolerance
        uint256 priceTolerated = 5e14;
        uint24 toleranceRange = 1000000; // 10%

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 swapId = _createSwapWithSlippage(priceTolerated, toleranceRange);
        _matchSwap(swapId);

        // Report amount2=1500e18 -> price ≈ 6.67e14 (~33% off, outside 10%)
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 1500e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Refunded
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper should have sellToken back");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore, "Matcher should have buyToken back");
    }
}
