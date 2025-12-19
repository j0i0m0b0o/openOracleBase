// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBounty.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapBountyRecallTest
 * @notice Tests for bounty recall mechanism
 *
 * Bounty recall returns unclaimed bounty back to the creator (swapper).
 * - If bounty not claimed: recall = totalDeposited (full amount)
 * - If bounty claimed: recall = totalDeposited - bountyClaimed
 *
 * Bounty is recalled automatically in:
 * - onSettle callback
 * - bailOut function
 */
contract OpenSwapBountyRecallTest is Test {
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
            disputeDelay: DISPUTE_DELAY,
            swapFee: SWAP_FEE,
            protocolFee: PROTOCOL_FEE
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

    function _calcFulfillAmt(uint256 amount1, uint256 amount2) internal pure returns (uint256) {
        uint256 fulfillAmt = (SELL_AMT * amount2) / amount1;
        fulfillAmt -= fulfillAmt * STARTING_FEE / 1e7;
        return fulfillAmt;
    }

    // ============ Bounty Recall on onSettle Tests ============

    function testBountyRecall_OnSettleWithClaimedBounty() public {
        // When initial report is submitted, bounty is claimed
        // Recall returns: totalDeposited - bountyClaimed

        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // After create + match, swapper's ETH decreased by ethToSend
        assertEq(swapper.balance, swapperEthBefore - ethToSend, "Swapper sent ETH");

        // Get fulfillAmt for balance calculation
        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Bounty was claimed at block 0 (same block as start)
        // bountyStartAmt = BOUNTY_AMOUNT / 20
        // At round 0: bountyClaimed = bountyStartAmt = BOUNTY_AMOUNT / 20
        // recall = BOUNTY_AMOUNT - (BOUNTY_AMOUNT / 20) = 19 * BOUNTY_AMOUNT / 20
        uint256 bountyClaimed = BOUNTY_AMOUNT / 20;
        uint256 expectedRecall = BOUNTY_AMOUNT - bountyClaimed;

        // Swapper should have: originalBalance - ethToSend + bountyRecall + fulfillAmt (in buyToken)
        // But wait, fulfillAmt is in buyToken, not ETH
        // And settlerReward goes to settler, not swapper
        // So swapper's ETH = original - ethToSend + bountyRecall
        // But the "+1" also gets returned... let me check the exact flow

        // Actually on settle, swapper gets:
        // - buyToken: fulfillAmt
        // - ETH: bountyRecall (if bounty exists)
        // The settlerReward goes to the settler

        // But we need to track swapper's ETH more carefully
        // ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1
        // The contract holds BOUNTY_AMOUNT + SETTLER_REWARD + 1
        // On settle:
        // - settlerReward goes to settler
        // - bountyRecall goes to swapper (creator)
        // - the "+1" is just extra wei that... stays in contract?

        // Let's just verify the bounty was recalled by checking the Bounty struct
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (,,,,,,,,,, bool recalled,) = bountyContract.Bounty(reportId);
        assertTrue(recalled, "Bounty should be recalled");
    }

    function testBountyRecall_OnSettleAmountCorrect() public {
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapId = _createSwap();
        uint256 swapperEthAfterCreate = swapper.balance;
        assertEq(swapperEthAfterCreate, swapperEthBefore - ethToSend, "Swapper sent ETH for create");

        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Check bounty state before settle
        (uint256 totalDeposited,,,,,,,,,, bool recalledBefore,) = bountyContract.Bounty(reportId);
        assertEq(totalDeposited, BOUNTY_AMOUNT, "Total deposited should be BOUNTY_AMOUNT");
        assertFalse(recalledBefore, "Should not be recalled before settle");

        uint256 swapperEthBeforeSettle = swapper.balance;

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        uint256 swapperEthAfterSettle = swapper.balance;

        // bountyClaimed = BOUNTY_AMOUNT / 20 (round 0)
        uint256 bountyClaimed = BOUNTY_AMOUNT / 20;
        uint256 expectedRecall = BOUNTY_AMOUNT - bountyClaimed;

        assertEq(
            swapperEthAfterSettle - swapperEthBeforeSettle,
            expectedRecall,
            "Swapper should receive correct bounty recall"
        );
    }

    // ============ Bounty Recall on bailOut Tests ============

    function testBountyRecall_OnBailOutNoClaim() public {
        // When bailout happens without initial report, full bounty is recalled

        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // No initial report submitted
        // Warp past latency bailout
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);

        uint256 swapperEthBeforeBailout = swapper.balance;

        swapContract.bailOut(swapId);

        uint256 swapperEthAfterBailout = swapper.balance;

        // Full bounty should be recalled (no claim happened)
        assertEq(
            swapperEthAfterBailout - swapperEthBeforeBailout,
            BOUNTY_AMOUNT,
            "Full bounty recalled on bailout without claim"
        );

        // Verify bounty is recalled
        (,,,,,,,,,, bool recalled,) = bountyContract.Bounty(reportId);
        assertTrue(recalled, "Bounty should be marked as recalled");
    }

    function testBountyRecall_BailOutBlockedAfterClaim() public {
        // After initial report, bailout via latency is blocked
        // because isLatent requires reportTimestamp == 0

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Submit initial report (claims bounty)
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        vm.prank(initialReporter);
        bountyContract.submitInitialReport(reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

        // Check bounty was claimed
        (,, uint256 bountyClaimed,,,,,,,bool claimed,,) = bountyContract.Bounty(reportId);
        assertTrue(claimed, "Bounty should be claimed after initial report");
        assertEq(bountyClaimed, BOUNTY_AMOUNT / 20, "BountyClaimed should be bountyStartAmt");

        // Warp past latency bailout time
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);

        // bailOut does nothing because:
        // - isDistributed = false (oracle not settled)
        // - isLatent = false (reportTimestamp != 0 because we submitted initial report)
        swapContract.bailOut(swapId);

        // Swap should NOT be finished
        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertFalse(sAfter.finished, "Swap should NOT be finished - bailout conditions not met");

        // Bounty should NOT be recalled
        (,,,,,,,,,, bool recalled,) = bountyContract.Bounty(reportId);
        assertFalse(recalled, "Bounty should NOT be recalled");
    }

    // ============ Bounty Struct State Tests ============

    function testBountyRecall_MarksRecalledTrue() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (,,,,,,,,,, bool recalledBefore,) = bountyContract.Bounty(reportId);
        assertFalse(recalledBefore, "Should not be recalled initially");

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        (,,,,,,,,,, bool recalledAfter,) = bountyContract.Bounty(reportId);
        assertTrue(recalledAfter, "Should be recalled after settle");
    }

    function testBountyRecall_CannotRecallTwice() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Bounty already recalled by onSettle
        // Try to recall again directly
        vm.prank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "bounty already recalled"));
        bountyContract.recallBounty(reportId);
    }

    // ============ Creator/Editor Access Tests ============

    function testBountyRecall_SwapContractIsEditor() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (,,,,,,address editor,,,,,) = bountyContract.Bounty(reportId);
        assertEq(editor, address(swapContract), "SwapContract should be bounty editor");
    }

    function testBountyRecall_SwapperIsCreator() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        (,,,,,address creator,,,,,,) = bountyContract.Bounty(reportId);
        assertEq(creator, swapper, "Swapper should be bounty creator");
    }

    function testBountyRecall_MatcherCannotRecall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Matcher is not creator or editor
        vm.prank(matcher);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "wrong sender"));
        bountyContract.recallBounty(reportId);
    }

    function testBountyRecall_RandomUserCannotRecall() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        address randomUser = address(0x999);
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(openOracleBounty.InvalidInput.selector, "wrong sender"));
        bountyContract.recallBounty(reportId);
    }

    // ============ ETH Flow Verification ============

    function testBountyRecall_ETHFlowComplete() public {
        // Complete ETH flow verification
        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapperStart = swapper.balance;
        uint256 settlerStart = settler.balance;

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // After create: swapper sent ethToSend
        assertEq(swapper.balance, swapperStart - ethToSend, "Swapper sent ETH");

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        uint256 swapperEnd = swapper.balance;
        uint256 settlerEnd = settler.balance;

        // Settler receives SETTLER_REWARD
        assertEq(settlerEnd - settlerStart, SETTLER_REWARD, "Settler received reward");

        // Swapper receives bounty recall
        uint256 bountyClaimed = BOUNTY_AMOUNT / 20;
        uint256 bountyRecall = BOUNTY_AMOUNT - bountyClaimed;
        assertEq(swapperEnd - (swapperStart - ethToSend), bountyRecall, "Swapper received bounty recall");

        // Total ETH accounting:
        // Sent: BOUNTY_AMOUNT + SETTLER_REWARD + 1
        // Settler got: SETTLER_REWARD
        // Swapper got back: BOUNTY_AMOUNT - bountyClaimed = 0.0095 ether
        // InitialReporter got: bountyClaimed = 0.0005 ether
        // Remaining: 1 wei (stays in bounty contract)
    }
}
