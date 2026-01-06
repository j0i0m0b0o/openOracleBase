// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapERC20BountyTest
 * @notice Thorough tests for ERC20 bounty functionality
 *
 * When bountyToken != address(0), the bounty is paid in ERC20 tokens
 * instead of ETH. This changes:
 * - Swap creation: bounty tokens are transferred from swapper
 * - msg.value: only includes gasCompensation + settlerReward + 1 (no bounty)
 * - Cancel: ERC20 bounty returned to swapper
 * - Match: bounty contract gets ERC20 approval
 * - Settle: reporter receives ERC20 bounty
 * - Bailout: ERC20 bounty recalled to creator
 */
contract OpenSwapERC20BountyTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    MockERC20 internal bountyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal initialReporter = address(0x3);
    address internal settler = address(0x4);
    address internal randomUser = address(0x5);

    // Oracle params
    uint256 constant SETTLER_REWARD = 0.001 ether;
    uint256 constant BOUNTY_AMOUNT = 1000e18; // ERC20 bounty amount
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
        bountyToken = new MockERC20("BountyToken", "BOUNTY");

        // Distribute tokens
        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(initialReporter, 100e18);
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(initialReporter, 100_000e18);
        bountyToken.transfer(swapper, 10_000e18); // Swapper needs bounty tokens

        // Give ETH
        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(initialReporter, 10 ether);
        vm.deal(settler, 1 ether);

        // Approvals
        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.prank(swapper);
        bountyToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);

        vm.startPrank(initialReporter);
        sellToken.approve(address(bountyContract), type(uint256).max);
        buyToken.approve(address(bountyContract), type(uint256).max);
        vm.stopPrank();
    }

    function _createSwapWithERC20Bounty() internal returns (uint256 swapId) {
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

        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: BOUNTY_AMOUNT,
            bountyStartAmt: BOUNTY_AMOUNT / 20,
            roundLength: 1,
            bountyToken: address(bountyToken), // ERC20 bounty!
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        // Note: msg.value does NOT include bounty when using ERC20 bounty
        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD + 1;

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

    // ============ Swap Creation Tests ============

    function testERC20Bounty_SwapCreation_TransfersBountyToken() public {
        uint256 swapperBountyBefore = bountyToken.balanceOf(swapper);
        uint256 contractBountyBefore = bountyToken.balanceOf(address(swapContract));

        _createSwapWithERC20Bounty();

        // Bounty tokens transferred from swapper to contract
        assertEq(bountyToken.balanceOf(swapper), swapperBountyBefore - BOUNTY_AMOUNT, "Swapper bounty tokens decreased");
        assertEq(bountyToken.balanceOf(address(swapContract)), contractBountyBefore + BOUNTY_AMOUNT, "Contract holds bounty tokens");
    }

    function testERC20Bounty_SwapCreation_CorrectMsgValue() public {
        uint256 swapperEthBefore = swapper.balance;

        _createSwapWithERC20Bounty();

        // msg.value should only include gasComp + settlerReward + 1 (NO bounty)
        uint256 expectedEthSpent = GAS_COMPENSATION + SETTLER_REWARD + 1;
        assertEq(swapper.balance, swapperEthBefore - expectedEthSpent, "Swapper ETH decreased by correct amount");
    }

    function testERC20Bounty_SwapCreation_StoresBountyParams() public {
        uint256 swapId = _createSwapWithERC20Bounty();

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.bountyParams.bountyToken, address(bountyToken), "Bounty token stored correctly");
        assertEq(s.bountyParams.totalAmtDeposited, BOUNTY_AMOUNT, "Bounty amount stored correctly");
    }

    function testERC20Bounty_SwapCreation_WrongMsgValue_Reverts() public {
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

        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: BOUNTY_AMOUNT,
            bountyStartAmt: BOUNTY_AMOUNT / 20,
            roundLength: 1,
            bountyToken: address(bountyToken),
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        // Sending wrong ETH amount (too much - any extra is wrong)
        uint256 correctEth = GAS_COMPENSATION + SETTLER_REWARD + 1;
        uint256 wrongEth = correctEth + 1 ether; // Extra 1 ETH is wrong

        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "msg.value wrong"));
        swapContract.swap{value: wrongEth}(
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

    // ============ Cancel Swap Tests ============

    function testERC20Bounty_Cancel_ReturnsBountyToken() public {
        uint256 swapperBountyBefore = bountyToken.balanceOf(swapper);

        uint256 swapId = _createSwapWithERC20Bounty();

        // Bounty tokens should be in contract
        assertEq(bountyToken.balanceOf(swapper), swapperBountyBefore - BOUNTY_AMOUNT, "Bounty tokens in contract");

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        // Bounty tokens returned to swapper
        assertEq(bountyToken.balanceOf(swapper), swapperBountyBefore, "Bounty tokens returned");
    }

    function testERC20Bounty_Cancel_ReturnsCorrectETH() public {
        uint256 swapperEthBefore = swapper.balance;

        uint256 swapId = _createSwapWithERC20Bounty();

        uint256 ethSpent = GAS_COMPENSATION + SETTLER_REWARD + 1;
        assertEq(swapper.balance, swapperEthBefore - ethSpent, "ETH spent on creation");

        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        // ETH returned: gasComp + settlerReward + 1 (no bounty since ERC20)
        assertEq(swapper.balance, swapperEthBefore, "All ETH returned on cancel");
    }

    // ============ Match Swap Tests ============

    function testERC20Bounty_Match_CreatesBountyWithToken() public {
        uint256 swapId = _createSwapWithERC20Bounty();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Check bounty was created with ERC20 token
        (,,,,,, address payable creator, address editor, address storedBountyToken,,,,,,) = bountyContract.Bounty(reportId);
        assertEq(storedBountyToken, address(bountyToken), "Bounty token stored in bounty contract");
        assertEq(creator, swapper, "Creator is swapper");
        assertEq(editor, address(swapContract), "Editor is swap contract");
    }

    function testERC20Bounty_Match_TransfersBountyToContract() public {
        uint256 swapId = _createSwapWithERC20Bounty();

        uint256 bountyContractBefore = bountyToken.balanceOf(address(bountyContract));

        _matchSwap(swapId);

        // Bounty tokens should now be in bounty contract
        assertEq(
            bountyToken.balanceOf(address(bountyContract)),
            bountyContractBefore + BOUNTY_AMOUNT,
            "Bounty contract holds bounty tokens"
        );
    }

    // ============ Settle Tests ============

    function testERC20Bounty_Settle_ReporterReceivesBountyToken() public {
        uint256 swapId = _createSwapWithERC20Bounty();
        _matchSwap(swapId);

        uint256 reporterBountyBefore = bountyToken.balanceOf(initialReporter);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Reporter should have received some bounty tokens
        uint256 reporterBountyAfter = bountyToken.balanceOf(initialReporter);
        assertGt(reporterBountyAfter, reporterBountyBefore, "Reporter received bounty tokens");

        // At round 0: bountyClaimed = bountyStartAmt = BOUNTY_AMOUNT / 20
        uint256 expectedBountyClaimed = BOUNTY_AMOUNT / 20;
        assertEq(reporterBountyAfter - reporterBountyBefore, expectedBountyClaimed, "Reporter received correct bounty amount");
    }

    function testERC20Bounty_Settle_RecallsRemainingBounty() public {
        uint256 swapId = _createSwapWithERC20Bounty();
        _matchSwap(swapId);

        uint256 swapperBountyBefore = bountyToken.balanceOf(swapper);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Remaining bounty should be recalled to swapper (creator)
        // Recalled = totalDeposited - bountyClaimed = BOUNTY_AMOUNT - (BOUNTY_AMOUNT/20)
        uint256 bountyClaimed = BOUNTY_AMOUNT / 20;
        uint256 expectedRecall = BOUNTY_AMOUNT - bountyClaimed;

        uint256 swapperBountyAfter = bountyToken.balanceOf(swapper);
        assertEq(swapperBountyAfter - swapperBountyBefore, expectedRecall, "Swapper received remaining bounty");
    }

    function testERC20Bounty_Settle_BountyMarkedRecalled() public {
        uint256 swapId = _createSwapWithERC20Bounty();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        (,,,,,,,,,,,, bool recalled,,) = bountyContract.Bounty(reportId);
        assertTrue(recalled, "Bounty should be marked as recalled");
    }

    // ============ Bailout Tests ============

    function testERC20Bounty_Bailout_RecallsBountyToken() public {
        uint256 swapId = _createSwapWithERC20Bounty();
        _matchSwap(swapId);

        uint256 swapperBountyBefore = bountyToken.balanceOf(swapper);

        // Warp past latency bailout without initial report
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        vm.roll(block.number + (LATENCY_BAILOUT + 1) / 2);

        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        // Full bounty should be recalled to swapper
        assertEq(
            bountyToken.balanceOf(swapper),
            swapperBountyBefore + BOUNTY_AMOUNT,
            "Full bounty recalled on bailout"
        );
    }

    function testERC20Bounty_Bailout_MaxGameTime_RecallsBounty() public {
        uint256 swapId = _createSwapWithERC20Bounty();
        _matchSwap(swapId);

        // Submit initial report first (so latency doesn't trigger)
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        vm.prank(initialReporter);
        bountyContract.submitInitialReport(reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

        // Reporter claimed some bounty
        uint256 bountyClaimed = BOUNTY_AMOUNT / 20;
        uint256 expectedRecall = BOUNTY_AMOUNT - bountyClaimed;

        uint256 swapperBountyBefore = bountyToken.balanceOf(swapper);

        // Warp past maxGameTime
        vm.warp(block.timestamp + MAX_GAME_TIME + 1);
        vm.roll(block.number + (MAX_GAME_TIME + 1) / 2);

        vm.prank(randomUser);
        swapContract.bailOut(swapId);

        // Remaining bounty recalled
        assertEq(
            bountyToken.balanceOf(swapper),
            swapperBountyBefore + expectedRecall,
            "Remaining bounty recalled on maxGameTime bailout"
        );
    }

    // ============ Edge Cases ============

    function testERC20Bounty_BountyTokenSameAsSellToken() public {
        // Use sellToken as bounty token
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

        // Use sellToken as bounty - need enough sellToken (already approved)
        uint256 smallBounty = 5e18; // Smaller bounty so swapper has enough

        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: smallBounty,
            bountyStartAmt: smallBounty / 20,
            roundLength: 1,
            bountyToken: address(sellToken), // Same as sell token!
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD + 1;
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        uint256 swapId = swapContract.swap{value: ethToSend}(
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

        // Swapper should have lost SELL_AMT + smallBounty
        assertEq(
            sellToken.balanceOf(swapper),
            swapperSellBefore - SELL_AMT - smallBounty,
            "Both sellAmt and bounty deducted from same token"
        );

        // Cancel should return both
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "All sellToken returned on cancel");
    }

    function testERC20Bounty_BountyTokenSameAsBuyToken() public {
        // Give swapper some buyToken for bounty
        buyToken.transfer(swapper, 1000e18);
        vm.prank(swapper);
        buyToken.approve(address(swapContract), type(uint256).max);

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

        uint256 smallBounty = 500e18;

        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: smallBounty,
            bountyStartAmt: smallBounty / 20,
            roundLength: 1,
            bountyToken: address(buyToken), // Same as buy token!
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD + 1;
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        uint256 swapId = swapContract.swap{value: ethToSend}(
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

        // Swapper lost buyToken for bounty
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore - smallBounty, "Bounty deducted from buyToken");

        _matchSwap(swapId);

        // Get swap data for report
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Submit report and settle
        vm.prank(initialReporter);
        bountyContract.submitInitialReport(reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(reportId);

        // Swapper should now have: originalBuyBefore - bounty + recalledBounty + fulfillAmt (all in buyToken!)
        uint256 bountyClaimed = smallBounty / 20;
        uint256 recalledBounty = smallBounty - bountyClaimed;
        uint256 fulfillAmt = (SELL_AMT * 2000e18) / INITIAL_LIQUIDITY;
        fulfillAmt -= fulfillAmt * STARTING_FEE / 1e7;

        assertEq(
            buyToken.balanceOf(swapper),
            swapperBuyBefore - smallBounty + recalledBounty + fulfillAmt,
            "Swapper received buyToken as bounty recall and fulfillment"
        );
    }

    function testERC20Bounty_MultipleSwapsIndependent() public {
        // Create two swaps with different ERC20 bounties
        MockERC20 bountyToken2 = new MockERC20("BountyToken2", "BOUNTY2");
        bountyToken2.transfer(swapper, 10_000e18);
        vm.prank(swapper);
        bountyToken2.approve(address(swapContract), type(uint256).max);

        // First swap with bountyToken
        uint256 swapId1 = _createSwapWithERC20Bounty();

        // Second swap with bountyToken2
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

        openSwap.BountyParams memory bountyParams2 = openSwap.BountyParams({
            totalAmtDeposited: BOUNTY_AMOUNT / 2,
            bountyStartAmt: BOUNTY_AMOUNT / 40,
            roundLength: 1,
            bountyToken: address(bountyToken2),
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD + 1;

        uint256 swapId2 = swapContract.swap{value: ethToSend}(
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
            bountyParams2
        );
        vm.stopPrank();

        // Verify each swap has correct bounty token
        openSwap.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwap.Swap memory s2 = swapContract.getSwap(swapId2);

        assertEq(s1.bountyParams.bountyToken, address(bountyToken), "Swap1 has bountyToken");
        assertEq(s2.bountyParams.bountyToken, address(bountyToken2), "Swap2 has bountyToken2");

        // Cancel swap1, should only return bountyToken
        uint256 bounty1Before = bountyToken.balanceOf(swapper);
        uint256 bounty2Before = bountyToken2.balanceOf(swapper);

        vm.prank(swapper);
        swapContract.cancelSwap(swapId1);

        assertEq(bountyToken.balanceOf(swapper), bounty1Before + BOUNTY_AMOUNT, "BountyToken returned");
        assertEq(bountyToken2.balanceOf(swapper), bounty2Before, "BountyToken2 unchanged");
    }

    // ============ ETH vs ERC20 Bounty Comparison ============

    function testERC20Bounty_CompareWithETHBounty_ETH() public {
        // Create swap with ETH bounty for comparison
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

        uint256 ethBountyAmt = 0.01 ether;

        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: ethBountyAmt,
            bountyStartAmt: ethBountyAmt / 20,
            roundLength: 1,
            bountyToken: address(0), // ETH bounty!
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        // ETH bounty included in msg.value
        uint256 ethToSend = GAS_COMPENSATION + ethBountyAmt + SETTLER_REWARD + 1;
        uint256 swapperEthBefore = swapper.balance;

        uint256 swapId = swapContract.swap{value: ethToSend}(
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

        // ETH decreased by full amount including bounty
        assertEq(swapper.balance, swapperEthBefore - ethToSend, "ETH bounty included in msg.value");

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.bountyParams.bountyToken, address(0), "ETH bounty has address(0) as token");
    }

    function testERC20Bounty_CompareWithETHBounty_ERC20() public {
        uint256 swapperEthBefore = swapper.balance;
        uint256 swapperBountyBefore = bountyToken.balanceOf(swapper);

        _createSwapWithERC20Bounty();

        // ETH only includes gasComp + settlerReward + 1
        uint256 expectedEthSpent = GAS_COMPENSATION + SETTLER_REWARD + 1;
        assertEq(swapper.balance, swapperEthBefore - expectedEthSpent, "ERC20 bounty: ETH excludes bounty");

        // ERC20 bounty transferred separately
        assertEq(bountyToken.balanceOf(swapper), swapperBountyBefore - BOUNTY_AMOUNT, "ERC20 bounty transferred");
    }

    // ============ Reporter Bounty Escalation Tests ============

    function testERC20Bounty_ReporterGetsEscalatedBounty() public {
        uint256 swapId = _createSwapWithERC20Bounty();
        _matchSwap(swapId);

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;

        // Wait a few rounds for bounty to escalate
        // roundLength = 1 second, let's wait 3 rounds
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 2);

        uint256 reporterBountyBefore = bountyToken.balanceOf(initialReporter);

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);
        vm.prank(initialReporter);
        bountyContract.submitInitialReport(reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

        uint256 reporterBountyAfter = bountyToken.balanceOf(initialReporter);
        uint256 bountyReceived = reporterBountyAfter - reporterBountyBefore;

        // After 3 rounds with multiplier 12247 (1.2247x):
        // Round 0: 50e18 (BOUNTY_AMOUNT/20)
        // Round 1: 50e18 * 12247 / 10000 = 61.235e18
        // Round 2: 61.235e18 * 12247 / 10000 = 74.99e18
        // Round 3: 74.99e18 * 12247 / 10000 = 91.86e18

        uint256 expectedBounty = BOUNTY_AMOUNT / 20; // Start
        for (uint256 i = 0; i < 3; i++) {
            expectedBounty = (expectedBounty * 12247) / 10000;
        }

        assertEq(bountyReceived, expectedBounty, "Reporter received escalated bounty");
        assertGt(bountyReceived, BOUNTY_AMOUNT / 20, "Escalated bounty > start bounty");
    }

    // ============ Balance Invariant Tests (No Double Dipping) ============

    // Unrelated balances to seed
    uint256 constant UNRELATED_SELL_TOKEN = 777e18;
    uint256 constant UNRELATED_BUY_TOKEN = 888e18;
    uint256 constant UNRELATED_BOUNTY_TOKEN = 555e18;

    function _seedUnrelatedBalances() internal {
        // Someone accidentally sends tokens directly to the contracts
        sellToken.transfer(address(swapContract), UNRELATED_SELL_TOKEN);
        buyToken.transfer(address(swapContract), UNRELATED_BUY_TOKEN);
        bountyToken.transfer(address(swapContract), UNRELATED_BOUNTY_TOKEN);
        bountyToken.transfer(address(bountyContract), UNRELATED_BOUNTY_TOKEN);
    }

    function testERC20Bounty_BalanceInvariant_HappyPath() public {
        _seedUnrelatedBalances();

        uint256 swapContractBountyBefore = bountyToken.balanceOf(address(swapContract));
        uint256 bountyContractBountyBefore = bountyToken.balanceOf(address(bountyContract));

        assertEq(swapContractBountyBefore, UNRELATED_BOUNTY_TOKEN, "Initial swap contract bounty");
        assertEq(bountyContractBountyBefore, UNRELATED_BOUNTY_TOKEN, "Initial bounty contract bounty");

        // Create and match swap with ERC20 bounty
        uint256 swapId = _createSwapWithERC20Bounty();

        // After create: swapContract has unrelated + BOUNTY_AMOUNT
        assertEq(
            bountyToken.balanceOf(address(swapContract)),
            UNRELATED_BOUNTY_TOKEN + BOUNTY_AMOUNT,
            "After create: swap contract has unrelated + bounty"
        );

        _matchSwap(swapId);

        // After match: bountyContract has unrelated + BOUNTY_AMOUNT, swapContract back to unrelated
        assertEq(
            bountyToken.balanceOf(address(swapContract)),
            UNRELATED_BOUNTY_TOKEN,
            "After match: swap contract has only unrelated"
        );
        assertEq(
            bountyToken.balanceOf(address(bountyContract)),
            UNRELATED_BOUNTY_TOKEN + BOUNTY_AMOUNT,
            "After match: bounty contract has unrelated + bounty"
        );

        // Complete the swap
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // After settle: unrelated amounts should remain in both contracts
        assertEq(
            bountyToken.balanceOf(address(swapContract)),
            UNRELATED_BOUNTY_TOKEN,
            "After settle: swap contract unrelated bounty intact"
        );
        // Bounty contract keeps unrelated, bounty was claimed/recalled
        assertEq(
            bountyToken.balanceOf(address(bountyContract)),
            UNRELATED_BOUNTY_TOKEN,
            "After settle: bounty contract unrelated bounty intact"
        );

        // Also verify sell/buy token invariants
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken intact"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken intact"
        );
    }

    function testERC20Bounty_BalanceInvariant_Cancel() public {
        _seedUnrelatedBalances();

        uint256 swapId = _createSwapWithERC20Bounty();

        // Cancel the swap
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        // All unrelated balances should be intact
        assertEq(
            bountyToken.balanceOf(address(swapContract)),
            UNRELATED_BOUNTY_TOKEN,
            "Unrelated bountyToken intact after cancel"
        );
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken intact after cancel"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken intact after cancel"
        );
    }

    function testERC20Bounty_BalanceInvariant_Bailout() public {
        _seedUnrelatedBalances();

        uint256 swapId = _createSwapWithERC20Bounty();
        _matchSwap(swapId);

        // Warp past latency bailout
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        vm.roll(block.number + (LATENCY_BAILOUT + 1) / 2);
        swapContract.bailOut(swapId);

        // All unrelated balances should be intact
        assertEq(
            bountyToken.balanceOf(address(swapContract)),
            UNRELATED_BOUNTY_TOKEN,
            "Unrelated bountyToken intact after bailout"
        );
        assertEq(
            bountyToken.balanceOf(address(bountyContract)),
            UNRELATED_BOUNTY_TOKEN,
            "Bounty contract unrelated bountyToken intact after bailout"
        );
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken intact after bailout"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken intact after bailout"
        );
    }

    function testERC20Bounty_BalanceInvariant_MultipleSwaps() public {
        _seedUnrelatedBalances();

        // Run 3 complete swaps with ERC20 bounty
        for (uint256 i = 0; i < 3; i++) {
            // Give swapper more tokens
            sellToken.transfer(swapper, SELL_AMT);
            bountyToken.transfer(swapper, BOUNTY_AMOUNT);
            vm.deal(swapper, 1 ether);

            uint256 swapId = _createSwapWithERC20Bounty();
            _matchSwap(swapId);
            _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);
        }

        // After 3 complete swaps, unrelated balances intact
        assertEq(
            bountyToken.balanceOf(address(swapContract)),
            UNRELATED_BOUNTY_TOKEN,
            "Unrelated bountyToken intact after multiple swaps"
        );
        assertEq(
            bountyToken.balanceOf(address(bountyContract)),
            UNRELATED_BOUNTY_TOKEN,
            "Bounty contract unrelated intact after multiple swaps"
        );
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken intact after multiple swaps"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken intact after multiple swaps"
        );
    }

    function testERC20Bounty_BalanceInvariant_MixedOperations() public {
        _seedUnrelatedBalances();

        // Swap 1: Create and cancel
        uint256 swapId1 = _createSwapWithERC20Bounty();
        vm.prank(swapper);
        swapContract.cancelSwap(swapId1);

        // Swap 2: Create, match, and complete
        sellToken.transfer(swapper, SELL_AMT);
        bountyToken.transfer(swapper, BOUNTY_AMOUNT);
        vm.deal(swapper, 1 ether);
        uint256 swapId2 = _createSwapWithERC20Bounty();
        _matchSwap(swapId2);
        _submitReportAndSettle(swapId2, INITIAL_LIQUIDITY, 2000e18);

        // Swap 3: Create, match, and bailout
        sellToken.transfer(swapper, SELL_AMT);
        bountyToken.transfer(swapper, BOUNTY_AMOUNT);
        vm.deal(swapper, 1 ether);
        uint256 swapId3 = _createSwapWithERC20Bounty();
        _matchSwap(swapId3);
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        vm.roll(block.number + (LATENCY_BAILOUT + 1) / 2);
        swapContract.bailOut(swapId3);

        // All unrelated balances intact after mixed operations
        assertEq(
            bountyToken.balanceOf(address(swapContract)),
            UNRELATED_BOUNTY_TOKEN,
            "Unrelated bountyToken intact after mixed ops"
        );
        assertEq(
            bountyToken.balanceOf(address(bountyContract)),
            UNRELATED_BOUNTY_TOKEN,
            "Bounty contract unrelated intact after mixed ops"
        );
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken intact after mixed ops"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken intact after mixed ops"
        );
    }

    function testERC20Bounty_BalanceInvariant_BountyTokenIsSellToken() public {
        // Special case: bounty token is the same as sell token
        // Need to verify unrelated balances of OTHER tokens are intact

        // Seed only buyToken as unrelated (sellToken is the bounty)
        buyToken.transfer(address(swapContract), UNRELATED_BUY_TOKEN);

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

        uint256 smallBounty = 5e18;
        openSwap.BountyParams memory bountyParams = openSwap.BountyParams({
            totalAmtDeposited: smallBounty,
            bountyStartAmt: smallBounty / 20,
            roundLength: 1,
            bountyToken: address(sellToken), // Same as sell token!
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        uint256 ethToSend = GAS_COMPENSATION + SETTLER_REWARD + 1;
        uint256 swapId = swapContract.swap{value: ethToSend}(
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

        // Cancel and verify unrelated buyToken is intact
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken intact when bounty=sellToken"
        );
    }
}
