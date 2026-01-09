// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBountyERC20_sketch.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapBalanceInvariantTest
 * @notice Tests that unrelated balances in the swap contract are never touched
 *         Prevents double-dipping bugs where contract might use balanceOf(this) instead of tracked amounts
 */
contract OpenSwapBalanceInvariantTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal initialReporter = address(0x3);
    address internal settler = address(0x4);
    address internal randomDepositor = address(0x5);

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

    // Unrelated balances to seed
    uint256 constant UNRELATED_SELL_TOKEN = 777e18;
    uint256 constant UNRELATED_BUY_TOKEN = 888e18;

    function setUp() public {
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        swapContract = new openSwap(address(oracle), address(bountyContract));

        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        // Fund participants
        sellToken.transfer(swapper, 100e18);
        sellToken.transfer(initialReporter, 100e18);
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(initialReporter, 100_000e18);

        // Fund random depositor to seed unrelated balances
        sellToken.transfer(randomDepositor, UNRELATED_SELL_TOKEN);
        buyToken.transfer(randomDepositor, UNRELATED_BUY_TOKEN);

        // Give ETH to participants
        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(initialReporter, 10 ether);
        vm.deal(settler, 1 ether);

        // Approvals
        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);

        vm.startPrank(initialReporter);
        sellToken.approve(address(bountyContract), type(uint256).max);
        buyToken.approve(address(bountyContract), type(uint256).max);
        vm.stopPrank();
    }

    function _seedUnrelatedBalances() internal {
        // Someone accidentally sends tokens directly to the contract
        vm.startPrank(randomDepositor);
        sellToken.transfer(address(swapContract), UNRELATED_SELL_TOKEN);
        buyToken.transfer(address(swapContract), UNRELATED_BUY_TOKEN);
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

    // ============ Invariant Tests ============

    function testUnrelatedBalances_HappyPath() public {
        // Seed unrelated balances BEFORE any swap activity
        _seedUnrelatedBalances();

        uint256 contractSellBefore = sellToken.balanceOf(address(swapContract));
        uint256 contractBuyBefore = buyToken.balanceOf(address(swapContract));

        assertEq(contractSellBefore, UNRELATED_SELL_TOKEN, "Initial sellToken should be unrelated amount");
        assertEq(contractBuyBefore, UNRELATED_BUY_TOKEN, "Initial buyToken should be unrelated amount");

        // Create and match swap
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Verify unrelated balances still there (plus swap amounts)
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN + SELL_AMT,
            "Contract should have unrelated + swap sellToken"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN + MIN_FULFILL_LIQUIDITY,
            "Contract should have unrelated + swap buyToken"
        );

        // Submit initial report and settle
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(s.reportId);

        vm.prank(initialReporter);
        bountyContract.submitInitialReport(s.reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(s.reportId);

        // After swap completes, unrelated balances should STILL be there
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken should remain after swap"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken should remain after swap"
        );
    }

    function testUnrelatedBalances_CancelSwap() public {
        _seedUnrelatedBalances();

        uint256 swapId = _createSwap();

        // Cancel the swap
        vm.prank(swapper);
        swapContract.cancelSwap(swapId);

        // Unrelated balances should be untouched
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken should remain after cancel"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken should remain after cancel"
        );
    }

    function testUnrelatedBalances_BailOut() public {
        _seedUnrelatedBalances();

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Warp past latency bailout
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        vm.roll(block.number + (LATENCY_BAILOUT + 1) / 2);
        swapContract.bailOut(swapId);

        // Unrelated balances should be untouched
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken should remain after bailout"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken should remain after bailout"
        );
    }

    function testUnrelatedBalances_MultipleSwaps() public {
        _seedUnrelatedBalances();

        // Create and complete multiple swaps
        for (uint256 i = 0; i < 3; i++) {
            // Need more tokens for swapper
            sellToken.transfer(swapper, SELL_AMT);
            vm.deal(swapper, 1 ether);

            uint256 swapId = _createSwap();
            _matchSwap(swapId);

            openSwap.Swap memory s = swapContract.getSwap(swapId);
            (bytes32 stateHash,,,,,,,) = oracle.extraData(s.reportId);

            vm.prank(initialReporter);
            bountyContract.submitInitialReport(s.reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

            vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
            vm.prank(settler);
            oracle.settle(s.reportId);
        }

        // After 3 complete swaps, unrelated balances should still be there
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken should remain after multiple swaps"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken should remain after multiple swaps"
        );
    }

    function testUnrelatedBalances_MixOfCancelAndComplete() public {
        _seedUnrelatedBalances();

        // Swap 1: Create and cancel
        uint256 swapId1 = _createSwap();
        vm.prank(swapper);
        swapContract.cancelSwap(swapId1);

        // Swap 2: Create, match, and complete
        sellToken.transfer(swapper, SELL_AMT);
        vm.deal(swapper, 1 ether);
        uint256 swapId2 = _createSwap();
        _matchSwap(swapId2);

        openSwap.Swap memory s2 = swapContract.getSwap(swapId2);
        (bytes32 stateHash2,,,,,,,) = oracle.extraData(s2.reportId);

        vm.prank(initialReporter);
        bountyContract.submitInitialReport(s2.reportId, INITIAL_LIQUIDITY, 2000e18, stateHash2, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(s2.reportId);

        // Swap 3: Create, match, and bailout
        sellToken.transfer(swapper, SELL_AMT);
        vm.deal(swapper, 1 ether);
        uint256 swapId3 = _createSwap();
        _matchSwap(swapId3);

        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        vm.roll(block.number + (LATENCY_BAILOUT + 1) / 2);
        swapContract.bailOut(swapId3);

        // After all operations, unrelated balances intact
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "Unrelated sellToken should remain after mixed operations"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "Unrelated buyToken should remain after mixed operations"
        );
    }

    function testUnrelatedBalances_ExactAmounts() public {
        _seedUnrelatedBalances();

        // Track exact amounts throughout the flow
        uint256 swapId = _createSwap();

        // After create: unrelated + SELL_AMT
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN + SELL_AMT,
            "After create: exact sellToken"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "After create: exact buyToken"
        );

        _matchSwap(swapId);

        // After match: unrelated + SELL_AMT sellToken, unrelated + MIN_FULFILL_LIQUIDITY buyToken
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN + SELL_AMT,
            "After match: exact sellToken"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN + MIN_FULFILL_LIQUIDITY,
            "After match: exact buyToken"
        );

        // Complete the swap
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(s.reportId);

        vm.prank(initialReporter);
        bountyContract.submitInitialReport(s.reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.roll(block.number + (SETTLEMENT_TIME + 1) / 2);
        vm.prank(settler);
        oracle.settle(s.reportId);

        // After settle: back to just unrelated amounts
        assertEq(
            sellToken.balanceOf(address(swapContract)),
            UNRELATED_SELL_TOKEN,
            "After settle: exact unrelated sellToken"
        );
        assertEq(
            buyToken.balanceOf(address(swapContract)),
            UNRELATED_BUY_TOKEN,
            "After settle: exact unrelated buyToken"
        );
    }
}
