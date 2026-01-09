// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapOnSettleTest
 * @notice Tests for onSettle callback access control and behavior
 *
 * onSettle is called by the oracle when a report settles.
 * Access control:
 * - Only oracle can call (msg.sender == oracle)
 * - reportId must match stored reportId
 * - Cannot be called if already finished
 */
contract OpenSwapOnSettleTest is Test {
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
    uint48 constant MAX_GAME_TIME = 7200;

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
            maxRounds: MAX_ROUNDS
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

    // ============ Access Control Tests ============

    function testOnSettle_OnlyOracleCanCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Random user cannot call onSettle
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "invalid sender"));
        swapContract.onSettle(reportId, 5e14, 0, address(sellToken), address(buyToken));
    }

    function testOnSettle_SwapperCannotCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "invalid sender"));
        swapContract.onSettle(reportId, 5e14, 0, address(sellToken), address(buyToken));
    }

    function testOnSettle_MatcherCannotCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "invalid sender"));
        swapContract.onSettle(reportId, 5e14, 0, address(sellToken), address(buyToken));
    }

    function testOnSettle_BountyContractCannotCall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.prank(address(bountyContract));
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "invalid sender"));
        swapContract.onSettle(reportId, 5e14, 0, address(sellToken), address(buyToken));
    }

    // ============ ReportId Validation Tests ============

    function testOnSettle_WrongReportIdReverts() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 correctReportId = s.reportId;
        uint256 wrongReportId = correctReportId + 100;

        // Even oracle can't call with wrong reportId
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "wrong reportId"));
        swapContract.onSettle(wrongReportId, 5e14, 0, address(sellToken), address(buyToken));
    }

    function testOnSettle_ZeroReportIdReverts() public {
        // reportId 0 doesn't map to any swap
        // This causes division by zero when trying to calculate fulfillAmt
        // because the swap doesn't exist and oracleAmount1 = 0
        vm.prank(address(oracle));
        vm.expectRevert(); // Panics with division by zero
        swapContract.onSettle(0, 5e14, 0, address(sellToken), address(buyToken));
    }

    // ============ Already Finished Tests ============

    function testOnSettle_CannotCallTwice() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // First settle via oracle (normal flow)
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);

        // Verify swap is finished
        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished");

        // Second call to onSettle should fail
        vm.prank(address(oracle));
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "finished"));
        swapContract.onSettle(reportId, 5e14, 0, address(sellToken), address(buyToken));
    }

    // ============ Normal Flow via Oracle Tests ============

    function testOnSettle_OracleSettleTriggersCallback() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        assertFalse(s.finished, "Swap should not be finished yet");

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished after oracle settle");
    }

    function testOnSettle_SetsFinishedFlag() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "finished flag should be set");
    }

    // ============ Multiple Swaps Isolation Tests ============

    function testOnSettle_OnlyAffectsMatchingSwap() public {
        uint256 swapId1 = _createSwap();
        uint256 swapId2 = _createSwap();

        _matchSwap(swapId1);
        _matchSwap(swapId2);

        _submitReport(swapId1, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s1 = swapContract.getSwap(swapId1);
        uint256 reportId1 = s1.reportId;

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId1);

        // Swap 1 finished, swap 2 not
        openSwap.Swap memory s1After = swapContract.getSwap(swapId1);
        openSwap.Swap memory s2After = swapContract.getSwap(swapId2);

        assertTrue(s1After.finished, "Swap 1 should be finished");
        assertFalse(s2After.finished, "Swap 2 should NOT be finished");
    }

    // ============ Direct Oracle Call Test ============

    function testOnSettle_DirectOracleCallWorks() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        _submitReport(swapId, INITIAL_LIQUIDITY, 2000e18);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Advance time/blocks to pass impliedBlocksPerSecond check
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        // Directly call onSettle as oracle (bypassing oracle.settle)
        // This simulates what the oracle does internally
        vm.prank(address(oracle));
        swapContract.onSettle(reportId, 5e14, block.timestamp, address(sellToken), address(buyToken));

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Direct oracle call should work");
    }
}
