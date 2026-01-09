// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

contract OpenSwapHappyPathTest is Test {
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
    uint24 constant SWAP_FEE = 3000; // 0.03%
    uint24 constant PROTOCOL_FEE = 1000; // 0.01%
    uint48 constant LATENCY_BAILOUT = 600;
    uint48 constant MAX_GAME_TIME = 7200;

    // Swap params
    uint256 constant SELL_AMT = 10e18;
    uint256 constant MIN_OUT = 19000e18;
    uint256 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint256 constant GAS_COMPENSATION = 0.001 ether;

    // FulfillFeeParams
    uint24 constant MAX_FEE = 10000; // 0.1%
    uint24 constant STARTING_FEE = 10000;
    uint24 constant ROUND_LENGTH = 60;
    uint16 constant GROWTH_RATE = 15000; // 1.5x
    uint16 constant MAX_ROUNDS = 10;

    function setUp() public {
        // Deploy contracts
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        swapContract = new openSwap(address(oracle), address(bountyContract));

        // Deploy tokens
        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        // Fund accounts
        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(initialReporter, 100e18);
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(initialReporter, 100_000e18);

        // Give ETH
        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(initialReporter, 10 ether);
        vm.deal(settler, 1 ether);

        // Approvals for swapper
        vm.startPrank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        // Approvals for matcher
        vm.startPrank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
        vm.stopPrank();

        // Approvals for initial reporter (needs to approve bounty contract)
        vm.startPrank(initialReporter);
        sellToken.approve(address(bountyContract), type(uint256).max);
        buyToken.approve(address(bountyContract), type(uint256).max);
        vm.stopPrank();
    }

    function testHappyPath() public {
        // Track initial balances
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        uint256 matcherSellBefore = sellToken.balanceOf(matcher);
        uint256 matcherBuyBefore = buyToken.balanceOf(matcher);

        uint256 reporterSellBefore = sellToken.balanceOf(initialReporter);
        uint256 reporterBuyBefore = buyToken.balanceOf(initialReporter);
        uint256 reporterEthBefore = initialReporter.balance;

        uint256 settlerEthBefore = settler.balance;

        // ============ STEP 1: Swapper creates swap ============
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
            priceTolerated: 5e14, // price = amount1 * 1e18 / amount2 = 1e18 / 2000 = 5e14
            toleranceRange: 1e7 - 1 // max tolerance to effectively bypass slippage
        });

        openSwap.FulfillFeeParams memory fulfillFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0, // set by contract
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
            bountyToken: address(0), // ETH
            bountyMultiplier: 12247,
            maxRounds: 20
        });

        uint256 ethToSend = GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

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

        // Verify swapper's sellToken transferred
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper should have sent sellToken");
        assertEq(sellToken.balanceOf(address(swapContract)), SELL_AMT, "SwapContract should hold sellToken");

        // ============ STEP 2: Matcher matches swap ============
        vm.startPrank(matcher);

        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);

        vm.stopPrank();

        // Verify matcher's buyToken transferred
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - MIN_FULFILL_LIQUIDITY, "Matcher should have sent buyToken");
        assertEq(buyToken.balanceOf(address(swapContract)), MIN_FULFILL_LIQUIDITY, "SwapContract should hold buyToken");

        // Get the reportId created by the oracle game
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        uint256 reportId = s.reportId;
        assertEq(reportId, 1, "ReportId should be 1 (first report)");

        // ============ STEP 3: Initial reporter submits report via bounty contract ============
        // Get state hash from oracle
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Initial reporter submits through bounty contract
        // Amount1 = initialLiquidity (sellToken), Amount2 = equivalent buyToken value
        // Let's say 1 sellToken = 2000 buyToken (like ETH/USDC)
        uint256 amount1 = INITIAL_LIQUIDITY;
        uint256 amount2 = 2000e18;

        vm.startPrank(initialReporter);
        bountyContract.submitInitialReport(reportId, amount1, amount2, stateHash, initialReporter);
        vm.stopPrank();

        // Verify bounty was claimed with exact values
        // bountyStartAmt in matchSwap = requiredBounty / 20, claimed same block so rounds = 0
        uint256 expectedBounty = BOUNTY_AMOUNT / 20;
        (
            uint256 totalAmtDeposited,
            uint256 bountyStartAmt,
            uint256 bountyClaimed,
            uint256 start,
            uint256 forwardStartTime,
            uint256 roundLength,
            uint256 recallUnlockAt,
            address payable creator,
            address editor,
            address bountyToken,
            uint16 bountyMultiplier,
            uint16 maxRounds,
            bool claimed,
            bool recalled,
            bool timeType,
        ) = bountyContract.Bounty(reportId);

        assertEq(totalAmtDeposited, BOUNTY_AMOUNT, "totalAmtDeposited should be BOUNTY_AMOUNT");
        assertEq(bountyStartAmt, BOUNTY_AMOUNT / 20, "bountyStartAmt should be BOUNTY_AMOUNT / 20");
        assertEq(bountyClaimed, expectedBounty, "bountyClaimed should equal expectedBounty");
        assertEq(start, block.timestamp, "start should be block.timestamp");
        assertEq(forwardStartTime, 0, "forwardStartTime should be 0");
        assertEq(creator, swapper, "creator should be swapper");
        assertEq(editor, address(swapContract), "editor should be swapContract");
        assertEq(bountyMultiplier, 12247, "bountyMultiplier should be 12247");
        assertEq(maxRounds, 20, "maxRounds should be 20");
        assertTrue(claimed, "claimed should be true");
        assertFalse(recalled, "recalled should be false");
        assertTrue(timeType, "timeType should be true");

        // Reporter should have received exact bounty ETH
        assertEq(initialReporter.balance, reporterEthBefore + expectedBounty, "Reporter should have received exact bounty");

        // ============ STEP 4: Wait for settlement time and settle ============
        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);

        vm.prank(settler);
        oracle.settle(reportId);

        // ============ STEP 5: Verify final balances ============

        // Settler should have received settler reward
        assertEq(settler.balance, settlerEthBefore + SETTLER_REWARD, "Settler should receive settler reward");

        // Swap should be finished
        openSwap.Swap memory finalSwap = swapContract.getSwap(swapId);
        assertTrue(finalSwap.finished, "Swap should be finished");

        // Calculate expected fulfillAmt based on oracle price
        // fulfillAmt = (sellAmt * oracleAmount2) / oracleAmount1
        // fulfillAmt -= fulfillAmt * fulfillmentFee / 1e7
        (uint256 currentAmount1, uint256 currentAmount2,,,,,,,,) = oracle.reportStatus(reportId);
        uint256 fulfillAmt = (SELL_AMT * currentAmount2) / currentAmount1;
        fulfillAmt -= fulfillAmt * MAX_FEE / 1e7;

        // Swapper should have received buyToken
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore + fulfillAmt, "Swapper should receive buyToken");

        // Matcher should have received sellToken and leftover buyToken
        assertEq(sellToken.balanceOf(matcher), matcherSellBefore + SELL_AMT, "Matcher should receive sellToken");
        assertEq(buyToken.balanceOf(matcher), matcherBuyBefore - fulfillAmt, "Matcher should have remaining buyToken");

        // Initial reporter should have their oracle tokens back (after settlement)
        assertEq(sellToken.balanceOf(initialReporter), reporterSellBefore, "Reporter should have sellToken back");
        assertEq(buyToken.balanceOf(initialReporter), reporterBuyBefore, "Reporter should have buyToken back");

        // SwapContract should have no tokens left
        assertEq(sellToken.balanceOf(address(swapContract)), 0, "SwapContract should have no sellToken");
        assertEq(buyToken.balanceOf(address(swapContract)), 0, "SwapContract should have no buyToken");

        console.log("=== Happy Path Complete ===");
        console.log("Swapper received buyToken:", fulfillAmt);
        console.log("Matcher received sellToken:", SELL_AMT);
        console.log("Reporter bounty:", bountyClaimed);
        console.log("Settler reward:", SETTLER_REWARD);
    }
}
