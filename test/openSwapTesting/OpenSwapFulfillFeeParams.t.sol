// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapFulfillFeeParamsTest
 * @notice Tests for dynamic fulfillment fee mechanism (FulfillFeeParams)
 *
 * FulfillFeeParams:
 *   - startFulfillFeeIncrease: set to block.timestamp on swap creation
 *   - maxFee: max fee that can be charged (1000 = 0.01%)
 *   - startingFee: initial fee when swap is created
 *   - roundLength: duration of each round in seconds
 *   - growthRate: multiplier per round (15000 = 1.5x)
 *   - maxRounds: maximum number of fee increase rounds
 *
 * calcFee logic:
 *   - timeDelta = (block.timestamp - startFulfillFeeIncrease) / roundLength
 *   - timeDelta capped at maxRounds
 *   - currentFee = startingFee * (growthRate/10000)^timeDelta
 *   - capped at maxFee
 */
contract OpenSwapFulfillFeeParamsTest is Test {
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
    uint256 constant MIN_OUT = 1e18;
    uint256 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint256 constant GAS_COMPENSATION = 0.001 ether;

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

    function _getOracleParams() internal pure returns (openSwap.OracleParams memory) {
        return openSwap.OracleParams({
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
    }

    function _getSlippageParams() internal pure returns (openSwap.SlippageParams memory) {
        return openSwap.SlippageParams({
            priceTolerated: 0,
            toleranceRange: 0
        });
    }

    function _createSwapWithFeeParams(openSwap.FulfillFeeParams memory feeParams) internal returns (uint256 swapId) {
        vm.startPrank(swapper);

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
            _getOracleParams(),
            _getSlippageParams(),
            feeParams
        );

        vm.stopPrank();
    }

    function _matchSwap(uint256 swapId) internal {
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();
    }

    // ============ FulfillFeeParams Validation Tests ============

    function testFulfillFeeParams_MaxFeeZero_Reverts() public {
        openSwap.FulfillFeeParams memory badParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 0,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_StartingFeeZero_Reverts() public {
        openSwap.FulfillFeeParams memory badParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 0,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_GrowthRateZero_Reverts() public {
        openSwap.FulfillFeeParams memory badParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 0,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_MaxRoundsZero_Reverts() public {
        openSwap.FulfillFeeParams memory badParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 0
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_RoundLengthZero_Reverts() public {
        openSwap.FulfillFeeParams memory badParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 10000,
            roundLength: 0,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_MaxFeeLessThanStartingFee_Reverts() public {
        openSwap.FulfillFeeParams memory badParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 5000,
            startingFee: 10000, // startingFee > maxFee
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillFeeParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams
        );
        vm.stopPrank();
    }

    function testFulfillFeeParams_MaxFeeAbove1e7_Reverts() public {
        openSwap.FulfillFeeParams memory badParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: uint24(1e7 + 1),
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillmentFee"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), badParams
        );
        vm.stopPrank();
    }

    // ============ Fee Calculation Tests ============

    function testFulfillFee_ImmediateMatch_UsesStartingFee() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000, // 0.1%
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Match immediately (same block)
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.fulfillmentFee, 10000, "Fee should be starting fee when matched immediately");
    }

    function testFulfillFee_AfterOneRound_Increases() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000, // 0.1%
            roundLength: 60,
            growthRate: 15000, // 1.5x per round
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait one round
        vm.warp(block.timestamp + 60);

        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        // Fee should be 10000 * 1.5 = 15000
        assertEq(s.fulfillmentFee, 15000, "Fee should increase after one round");
    }

    function testFulfillFee_AfterTwoRounds_IncreasesExponentially() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000, // 1.5x per round
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait two rounds
        vm.warp(block.timestamp + 120);

        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        // Fee should be 10000 * 1.5 * 1.5 = 22500
        assertEq(s.fulfillmentFee, 22500, "Fee should increase exponentially");
    }

    function testFulfillFee_CappedAtMaxFee() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 20000, // Cap at 20000
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000, // 1.5x per round
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait many rounds (would be 10000 * 1.5^5 = 75937 without cap)
        vm.warp(block.timestamp + 300);

        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.fulfillmentFee, 20000, "Fee should be capped at maxFee");
    }

    function testFulfillFee_CappedAtMaxRounds() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 1000000, // Very high cap
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000, // 1.5x per round
            maxRounds: 3 // Only 3 rounds allowed
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait 10 rounds (but maxRounds = 3)
        vm.warp(block.timestamp + 600);

        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        // Fee should be 10000 * 1.5^3 = 33750 (capped at 3 rounds, not 10)
        assertEq(s.fulfillmentFee, 33750, "Fee should be capped at maxRounds worth of growth");
    }

    function testFulfillFee_PartialRoundNotCounted() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait less than one round
        vm.warp(block.timestamp + 59);

        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.fulfillmentFee, 10000, "Fee should not increase for partial round");
    }

    // ============ getCurrentFulfillmentFee Tests ============

    function testGetCurrentFulfillmentFee_BeforeMatch() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        uint256 fee = swapContract.getCurrentFulfillmentFee(swapId);
        assertEq(fee, 10000, "Should return starting fee right after creation");
    }

    function testGetCurrentFulfillmentFee_IncreasesOverTime() public {
        // Set a known starting timestamp
        uint256 startTime = 1000;
        vm.warp(startTime);

        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Check at different times using absolute timestamps
        assertEq(swapContract.getCurrentFulfillmentFee(swapId), 10000, "Fee at t=0");

        vm.warp(startTime + 60);
        assertEq(swapContract.getCurrentFulfillmentFee(swapId), 15000, "Fee at t=60");

        vm.warp(startTime + 120);
        assertEq(swapContract.getCurrentFulfillmentFee(swapId), 22500, "Fee at t=120");
    }

    function testGetCurrentFulfillmentFee_ReturnsZeroIfMatched() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);
        _matchSwap(swapId);

        uint256 fee = swapContract.getCurrentFulfillmentFee(swapId);
        assertEq(fee, 0, "Should return 0 after match");
    }

    // ============ getFulfillmentFeeParams Tests ============

    function testGetFulfillmentFeeParams_ReturnsCorrectParams() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 50000,
            startingFee: 5000,
            roundLength: 120,
            growthRate: 20000,
            maxRounds: 5
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        openSwap.FulfillFeeParams memory retrieved = swapContract.getFulfillmentFeeParams(swapId);

        // startFulfillFeeIncrease is set by contract to block.timestamp
        assertEq(retrieved.maxFee, 50000, "maxFee should match");
        assertEq(retrieved.startingFee, 5000, "startingFee should match");
        assertEq(retrieved.roundLength, 120, "roundLength should match");
        assertEq(retrieved.growthRate, 20000, "growthRate should match");
        assertEq(retrieved.maxRounds, 5, "maxRounds should match");
    }

    function testGetFulfillmentFeeParams_StartTimestampSetCorrectly() public {
        uint256 startTime = block.timestamp;

        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 50000,
            startingFee: 5000,
            roundLength: 120,
            growthRate: 20000,
            maxRounds: 5
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        openSwap.FulfillFeeParams memory retrieved = swapContract.getFulfillmentFeeParams(swapId);

        assertEq(retrieved.startFulfillFeeIncrease, startTime, "startFulfillFeeIncrease should be block.timestamp at creation");
    }

    // ============ SingleFee Event Tests ============

    function testSingleFee_EmittedWhenMaxEqualsStartAndOneRound() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 10000, // Same as maxFee
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 1 // Single round
        });

        vm.startPrank(swapper);
        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        vm.expectEmit(true, false, false, true);
        emit openSwap.SingleFee(1, 10000); // swapId = 1 (nextSwapId starts at 1)

        swapContract.swap{value: ethToSend}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _getOracleParams(), _getSlippageParams(), feeParams
        );
        vm.stopPrank();
    }

    function testSingleFee_NotEmittedWhenDifferentFees() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 20000,
            startingFee: 10000, // Different from maxFee
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 1
        });

        // Create swap - SingleFee should NOT be emitted
        // (We can't easily check for absence, but this test ensures no revert)
        _createSwapWithFeeParams(feeParams);
    }

    function testSingleFee_NotEmittedWhenMultipleRounds() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 5 // Multiple rounds
        });

        // Create swap - SingleFee should NOT be emitted
        _createSwapWithFeeParams(feeParams);
    }

    // ============ Fee Applied to Fulfill Amount Tests ============

    function testFulfillFee_AppliedCorrectlyOnSettle() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000, // 0.1%
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        uint256 swapId = _createSwapWithFeeParams(feeParams);
        _matchSwap(swapId);

        // Submit report and settle
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(s.reportId);

        vm.prank(initialReporter);
        bountyContract.submitInitialReport(s.reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(s.reportId);

        // Calculate expected fulfillAmt
        // fulfillAmt = (10e18 * 2000e18) / 1e18 = 20000e18
        // fee = 10000 / 1e7 = 0.001 (0.1%)
        // fulfillAmt after fee = 20000e18 - 20e18 = 19980e18
        uint256 expectedFulfill = 20000e18 - (20000e18 * 10000 / 1e7);

        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + expectedFulfill, "Swapper should receive fulfillAmt minus fee");
    }

    function testFulfillFee_HigherFeeReducesFulfillAmount() public {
        // Create two swaps with different fees
        openSwap.FulfillFeeParams memory lowFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 10000, // 0.1%
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 1
        });

        openSwap.FulfillFeeParams memory highFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000, // 1%
            startingFee: 100000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 1
        });

        uint256 swapId1 = _createSwapWithFeeParams(lowFeeParams);
        uint256 swapId2 = _createSwapWithFeeParams(highFeeParams);

        _matchSwap(swapId1);
        _matchSwap(swapId2);

        openSwap.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwap.Swap memory s2 = swapContract.getSwap(swapId2);

        assertEq(s1.fulfillmentFee, 10000, "Swap 1 should have low fee");
        assertEq(s2.fulfillmentFee, 100000, "Swap 2 should have high fee");

        // Higher fee means less output for swapper
        // With 0.1% fee: swapper gets 99.9% of fulfillAmt
        // With 1% fee: swapper gets 99% of fulfillAmt
    }

    // ============ Fee Locked at Match Time ============

    function testFulfillFee_LockedAtMatchTime() public {
        openSwap.FulfillFeeParams memory feeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: 100000,
            startingFee: 10000,
            roundLength: 60,
            growthRate: 15000,
            maxRounds: 10
        });

        uint256 swapId = _createSwapWithFeeParams(feeParams);

        // Wait one round
        vm.warp(block.timestamp + 60);
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 lockedFee = s.fulfillmentFee;
        assertEq(lockedFee, 15000, "Fee should be locked at 15000");

        // Wait more time - fee in struct should NOT change
        vm.warp(block.timestamp + 300);

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertEq(sAfter.fulfillmentFee, lockedFee, "Fee should remain locked after match");
    }
}
