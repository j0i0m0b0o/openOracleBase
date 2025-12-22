// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapGasCompensationTest
 * @notice Tests for gasCompensation mechanism
 *
 * gasCompensation is a fixed ETH amount:
 *   - Paid by swapper when creating swap (included in msg.value)
 *   - Paid to matcher immediately when they call matchSwap
 *   - Returned to swapper if swap is cancelled (before match)
 *   - NOT returned on bailout (matcher already received it)
 */
contract OpenSwapGasCompensationTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal matcher2 = address(0x5);
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
        buyToken.transfer(matcher2, 100_000e18);
        buyToken.transfer(initialReporter, 100_000e18);

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(matcher2, 10 ether);
        vm.deal(initialReporter, 10 ether);
        vm.deal(settler, 1 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher2);
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

    function _getFulfillFeeParams() internal pure returns (openSwap.FulfillFeeParams memory) {
        return openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
    }

    function _createSwapWithGasComp(uint256 gasCompensation) internal returns (uint256 swapId) {
        vm.startPrank(swapper);

        uint256 ethToSend = gasCompensation + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            gasCompensation,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams()
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

    // ============ Gas Compensation on Swap Creation Tests ============

    function testGasComp_StoredInSwapStruct() public {
        uint256 gasComp = 0.005 ether;
        uint256 swapId = _createSwapWithGasComp(gasComp);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.gasCompensation, gasComp, "gasCompensation should be stored in swap");
    }

    function testGasComp_IncludedInMsgValue() public {
        uint256 gasComp = 0.005 ether;
        uint256 swapperEthBefore = swapper.balance;

        uint256 expectedSent = gasComp + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        _createSwapWithGasComp(gasComp);

        assertEq(swapper.balance, swapperEthBefore - expectedSent, "Swapper should send gasComp + bounty + settler + 1");
    }

    function testGasComp_ZeroIsValid() public {
        uint256 swapId = _createSwapWithGasComp(0);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.gasCompensation, 0, "Zero gasCompensation should be valid");
    }

    function testGasComp_HighValueIsValid() public {
        uint256 gasComp = 1 ether;
        uint256 swapId = _createSwapWithGasComp(gasComp);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.gasCompensation, gasComp, "High gasCompensation should be valid");
    }

    function testGasComp_ContractHoldsUntilMatch() public {
        uint256 gasComp = 0.005 ether;
        uint256 contractEthBefore = address(swapContract).balance;

        _createSwapWithGasComp(gasComp);

        uint256 expectedHeld = gasComp + BOUNTY_AMOUNT + SETTLER_REWARD + 1;
        assertEq(
            address(swapContract).balance,
            contractEthBefore + expectedHeld,
            "Contract should hold gasComp until match"
        );
    }

    // ============ Gas Compensation on Match Tests ============

    function testGasComp_PaidToMatcherOnMatch() public {
        uint256 gasComp = 0.005 ether;
        uint256 matcherEthBefore = matcher.balance;

        uint256 swapId = _createSwapWithGasComp(gasComp);

        _matchSwap(swapId);

        assertEq(matcher.balance, matcherEthBefore + gasComp, "Matcher should receive gasCompensation on match");
    }

    function testGasComp_PaidImmediatelyOnMatch() public {
        uint256 gasComp = 0.005 ether;
        uint256 matcherEthBefore = matcher.balance;

        uint256 swapId = _createSwapWithGasComp(gasComp);

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);

        // Balance changes during matchSwap call
        uint256 balanceBeforeMatch = matcher.balance;
        swapContract.matchSwap(swapId, swapHash);
        uint256 balanceAfterMatch = matcher.balance;

        vm.stopPrank();

        assertEq(balanceAfterMatch - balanceBeforeMatch, gasComp, "gasComp should be paid during match tx");
    }

    function testGasComp_ZeroPaysNothing() public {
        uint256 matcherEthBefore = matcher.balance;

        uint256 swapId = _createSwapWithGasComp(0);
        _matchSwap(swapId);

        assertEq(matcher.balance, matcherEthBefore, "Zero gasComp should not change matcher balance");
    }

    function testGasComp_DifferentMatchersGetTheirGasComp() public {
        uint256 gasComp = 0.005 ether;

        uint256 swapId1 = _createSwapWithGasComp(gasComp);
        uint256 swapId2 = _createSwapWithGasComp(gasComp);

        uint256 matcher1EthBefore = matcher.balance;
        uint256 matcher2EthBefore = matcher2.balance;

        // Matcher 1 matches swap 1
        vm.startPrank(matcher);
        bytes32 swapHash1 = swapContract.getSwapHash(swapId1);
        swapContract.matchSwap(swapId1, swapHash1);
        vm.stopPrank();

        // Matcher 2 matches swap 2
        vm.startPrank(matcher2);
        bytes32 swapHash2 = swapContract.getSwapHash(swapId2);
        swapContract.matchSwap(swapId2, swapHash2);
        vm.stopPrank();

        assertEq(matcher.balance, matcher1EthBefore + gasComp, "Matcher 1 should receive gasComp from swap 1");
        assertEq(matcher2.balance, matcher2EthBefore + gasComp, "Matcher 2 should receive gasComp from swap 2");
    }

    // ============ Gas Compensation on Cancel Tests ============

    function testGasComp_ReturnedOnCancel() public {
        uint256 gasComp = 0.005 ether;
        uint256 swapperEthBefore = swapper.balance;

        uint256 ethSent = gasComp + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapId = _createSwapWithGasComp(gasComp);

        assertEq(swapper.balance, swapperEthBefore - ethSent, "Swapper sent ETH");

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        assertEq(swapper.balance, swapperEthBefore, "Swapper should get all ETH back including gasComp");
    }

    function testGasComp_ZeroReturnedOnCancel() public {
        uint256 swapperEthBefore = swapper.balance;

        uint256 ethSent = BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapId = _createSwapWithGasComp(0);

        assertEq(swapper.balance, swapperEthBefore - ethSent, "Swapper sent ETH");

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        assertEq(swapper.balance, swapperEthBefore, "Swapper should get all ETH back");
    }

    // ============ Gas Compensation on Bailout Tests ============

    function testGasComp_NotReturnedOnBailout() public {
        uint256 gasComp = 0.005 ether;

        uint256 swapperEthBeforeCreate = swapper.balance;
        uint256 matcherEthBeforeMatch = matcher.balance;

        uint256 swapId = _createSwapWithGasComp(gasComp);

        uint256 swapperEthAfterCreate = swapper.balance;

        _matchSwap(swapId);

        // Matcher received gasComp at match
        assertEq(matcher.balance, matcherEthBeforeMatch + gasComp, "Matcher got gasComp");

        // Warp past latency bailout
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        swapContract.bailOut(swapId);

        // Swapper gets: sellAmt (if ERC20) + bounty recall
        // But NOT gasComp (matcher already has it)
        uint256 swapperEthAfterBailout = swapper.balance;

        // Swapper should get bounty back (no claim happened)
        uint256 bountyReturn = BOUNTY_AMOUNT;
        assertEq(
            swapperEthAfterBailout - swapperEthAfterCreate,
            bountyReturn,
            "Swapper should get bounty but not gasComp on bailout"
        );
    }

    function testGasComp_MatcherKeepsGasCompOnBailout() public {
        uint256 gasComp = 0.005 ether;

        uint256 matcherEthBefore = matcher.balance;

        uint256 swapId = _createSwapWithGasComp(gasComp);
        _matchSwap(swapId);

        uint256 matcherEthAfterMatch = matcher.balance;
        assertEq(matcherEthAfterMatch, matcherEthBefore + gasComp, "Matcher received gasComp at match");

        // Bailout
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        swapContract.bailOut(swapId);

        // Matcher balance unchanged from after match
        assertEq(matcher.balance, matcherEthAfterMatch, "Matcher keeps gasComp after bailout");
    }

    // ============ Gas Compensation in Full Flow Tests ============

    function testGasComp_HappyPathFlow() public {
        uint256 gasComp = 0.005 ether;

        uint256 swapperEthStart = swapper.balance;
        uint256 matcherEthStart = matcher.balance;

        uint256 swapId = _createSwapWithGasComp(gasComp);

        // Swapper paid gasComp + bounty + settler + 1
        uint256 ethSent = gasComp + BOUNTY_AMOUNT + SETTLER_REWARD + 1;
        assertEq(swapper.balance, swapperEthStart - ethSent, "Swapper sent ETH");

        _matchSwap(swapId);

        // Matcher received gasComp
        assertEq(matcher.balance, matcherEthStart + gasComp, "Matcher received gasComp");

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // After settle, swapper gets bounty recall
        uint256 bountyClaimed = BOUNTY_AMOUNT / 20;
        uint256 bountyRecall = BOUNTY_AMOUNT - bountyClaimed;

        // Swapper: started with ethStart, sent ethSent, got bountyRecall back
        // Final = ethStart - ethSent + bountyRecall
        uint256 expectedSwapperFinal = swapperEthStart - ethSent + bountyRecall;
        assertEq(swapper.balance, expectedSwapperFinal, "Swapper final ETH balance");

        // Matcher keeps gasComp
        assertEq(matcher.balance, matcherEthStart + gasComp, "Matcher keeps gasComp after settle");
    }

    function testGasComp_WithETHSellToken() public {
        uint256 gasComp = 0.005 ether;
        uint256 ethSellAmt = 1 ether;

        uint256 swapperEthBefore = swapper.balance;
        uint256 matcherEthBefore = matcher.balance;

        vm.startPrank(swapper);

        uint256 ethToSend = ethSellAmt + gasComp + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapId = swapContract.swap{value: ethToSend}(
            ethSellAmt,
            address(0), // ETH
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            gasComp,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams()
        );

        vm.stopPrank();

        assertEq(swapper.balance, swapperEthBefore - ethToSend, "Swapper sent ETH (sell + gasComp + extras)");

        _matchSwap(swapId);

        // Matcher receives: gasComp immediately, sellAmt after settle
        assertEq(matcher.balance, matcherEthBefore + gasComp, "Matcher received gasComp on match");
    }

    function testGasComp_MultipleSwapsDifferentAmounts() public {
        uint256 gasComp1 = 0.001 ether;
        uint256 gasComp2 = 0.01 ether;
        uint256 gasComp3 = 0.1 ether;

        uint256 swapId1 = _createSwapWithGasComp(gasComp1);
        uint256 swapId2 = _createSwapWithGasComp(gasComp2);
        uint256 swapId3 = _createSwapWithGasComp(gasComp3);

        openSwap.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwap.Swap memory s2 = swapContract.getSwap(swapId2);
        openSwap.Swap memory s3 = swapContract.getSwap(swapId3);

        assertEq(s1.gasCompensation, gasComp1, "Swap 1 gasComp");
        assertEq(s2.gasCompensation, gasComp2, "Swap 2 gasComp");
        assertEq(s3.gasCompensation, gasComp3, "Swap 3 gasComp");

        // Match all
        uint256 matcherEthBefore = matcher.balance;

        vm.startPrank(matcher);
        swapContract.matchSwap(swapId1, swapContract.getSwapHash(swapId1));
        swapContract.matchSwap(swapId2, swapContract.getSwapHash(swapId2));
        swapContract.matchSwap(swapId3, swapContract.getSwapHash(swapId3));
        vm.stopPrank();

        assertEq(
            matcher.balance,
            matcherEthBefore + gasComp1 + gasComp2 + gasComp3,
            "Matcher received all gasComps"
        );
    }

    // ============ Gas Compensation Edge Cases ============

    function testGasComp_SwapperCanMatchOwnSwap() public {
        // Swapper is also matcher
        uint256 gasComp = 0.005 ether;

        vm.prank(swapper);
        buyToken.approve(address(swapContract), type(uint256).max);
        buyToken.transfer(swapper, 50_000e18);

        uint256 swapperEthBefore = swapper.balance;

        uint256 swapId = _createSwapWithGasComp(gasComp);

        uint256 swapperEthAfterCreate = swapper.balance;

        // Swapper matches own swap
        vm.startPrank(swapper);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // Swapper gets gasComp back (they match their own swap)
        assertEq(swapper.balance, swapperEthAfterCreate + gasComp, "Swapper gets gasComp when matching own swap");
    }

    function testGasComp_VeryLargeAmount() public {
        // Give swapper more ETH
        vm.deal(swapper, 100 ether);

        uint256 gasComp = 50 ether;
        uint256 matcherEthBefore = matcher.balance;

        uint256 swapId = _createSwapWithGasComp(gasComp);
        _matchSwap(swapId);

        assertEq(matcher.balance, matcherEthBefore + gasComp, "Very large gasComp paid correctly");
    }

    function testGasComp_MinimalAmount() public {
        uint256 gasComp = 1 wei;
        uint256 matcherEthBefore = matcher.balance;

        uint256 swapId = _createSwapWithGasComp(gasComp);
        _matchSwap(swapId);

        assertEq(matcher.balance, matcherEthBefore + gasComp, "Minimal gasComp (1 wei) paid correctly");
    }

    // ============ Gas Compensation Not Returned on Refund Scenarios ============

    function testGasComp_NotReturnedOnMinOutNotMet() public {
        uint256 gasComp = 0.005 ether;

        uint256 matcherEthBefore = matcher.balance;

        // Create swap with high minOut
        vm.startPrank(swapper);
        uint256 ethToSend = gasComp + BOUNTY_AMOUNT + SETTLER_REWARD + 1;
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            25000e18, // Very high minOut that won't be met
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            gasComp,
            _getOracleParams(),
            _getSlippageParams(),
            _getFulfillFeeParams()
        );
        vm.stopPrank();

        _matchSwap(swapId);

        // Matcher received gasComp at match
        assertEq(matcher.balance, matcherEthBefore + gasComp, "Matcher received gasComp");

        // Report price that makes fulfillAmt < minOut
        // fulfillAmt = 10e18 * 2000e18 / 1e18 = 20000e18 < 25000e18 minOut
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Both parties refunded their tokens, but matcher keeps gasComp
        assertEq(matcher.balance, matcherEthBefore + gasComp, "Matcher keeps gasComp even on refund");
    }

    function testGasComp_NotReturnedOnSlippageFail() public {
        uint256 gasComp = 0.005 ether;

        uint256 matcherEthBefore = matcher.balance;

        // Create swap with slippage check
        vm.startPrank(swapper);
        uint256 ethToSend = gasComp + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        openSwap.SlippageParams memory strictSlippage = openSwap.SlippageParams({
            priceTolerated: 5e14, // Expected price
            toleranceRange: 10000 // 0.1% tolerance
        });

        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            gasComp,
            _getOracleParams(),
            strictSlippage,
            _getFulfillFeeParams()
        );
        vm.stopPrank();

        _matchSwap(swapId);
        assertEq(matcher.balance, matcherEthBefore + gasComp, "Matcher received gasComp");

        // Report price outside slippage tolerance
        // price = 1e18 / 1800e18 = 5.55e14 (>10% off from 5e14)
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(s.reportId);

        vm.prank(initialReporter);
        bountyContract.submitInitialReport(s.reportId, INITIAL_LIQUIDITY, 1800e18, stateHash, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(s.reportId);

        // Refunded due to slippage, but matcher keeps gasComp
        assertEq(matcher.balance, matcherEthBefore + gasComp, "Matcher keeps gasComp on slippage refund");
    }
}
