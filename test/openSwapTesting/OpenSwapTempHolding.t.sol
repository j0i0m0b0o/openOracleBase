// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBounty.sol";
import "../utils/MockERC20.sol";

/**
 * @title BlacklistToken
 * @notice Token that can blacklist addresses from receiving tokens
 */
contract BlacklistToken is MockERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function setBlacklisted(address account, bool status) external {
        blacklisted[account] = status;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[to], "Blacklisted");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[to], "Blacklisted");
        return super.transferFrom(from, to, amount);
    }
}

/**
 * @title OpenSwapTempHoldingTest
 * @notice Tests for tempHolding fallback mechanism
 *
 * When token transfer fails (e.g., recipient is blacklisted),
 * tokens are stored in tempHolding instead of reverting.
 * Users can later call getTempHolding to withdraw.
 */
contract OpenSwapTempHoldingTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    BlacklistToken internal buyToken;

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

    // Swap params
    uint256 constant SELL_AMT = 10e18;
    uint256 constant MIN_OUT = 1e18;
    uint256 constant MIN_FULFILL_LIQUIDITY = 25000e18;
    uint256 constant FULFILLMENT_FEE = 10000;

    function setUp() public {
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        swapContract = new openSwap(address(oracle), address(bountyContract));

        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new BlacklistToken("BuyToken", "BUY");

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
            disputeDelay: DISPUTE_DELAY,
            swapFee: SWAP_FEE,
            protocolFee: PROTOCOL_FEE
        });

        openSwap.SlippageParams memory slippageParams = openSwap.SlippageParams({
            priceTolerated: 0,
            toleranceRange: 0
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

    function _calcFulfillAmt(uint256 amount1, uint256 amount2) internal pure returns (uint256) {
        uint256 fulfillAmt = (SELL_AMT * amount2) / amount1;
        fulfillAmt -= fulfillAmt * FULFILLMENT_FEE / 1e7;
        return fulfillAmt;
    }

    // ============ Normal Transfer Tests ============

    function testTempHolding_NormalTransferNoTempHolding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Normal transfer works - no tempHolding
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), 0, "No tempHolding for normal transfer");
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper received buyToken directly");
    }

    // ============ Blacklisted Recipient Tests ============

    function testTempHolding_BlacklistedSwapperGoesToTempHolding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        // Blacklist swapper before settlement
        buyToken.setBlacklisted(swapper, true);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Swapper is blacklisted, so buyToken goes to tempHolding
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), expectedFulfill, "TempHolding should have fulfillAmt");
        assertEq(buyToken.balanceOf(swapper), 0, "Swapper should NOT have buyToken directly");
    }

    function testTempHolding_BlacklistedMatcherExcessGoesToTempHolding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        uint256 matcherExcess = MIN_FULFILL_LIQUIDITY - expectedFulfill;

        // Blacklist matcher before settlement
        buyToken.setBlacklisted(matcher, true);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Matcher is blacklisted, so excess buyToken goes to tempHolding
        assertEq(swapContract.tempHolding(matcher, address(buyToken)), matcherExcess, "TempHolding should have matcher excess");
        // Swapper is not blacklisted, so they get their tokens directly
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should receive buyToken directly");
    }

    // ============ getTempHolding Tests ============

    function testTempHolding_GetTempHoldingWithdrawsTokens() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        // Blacklist swapper
        buyToken.setBlacklisted(swapper, true);

        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        // Verify tempHolding has tokens
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), expectedFulfill, "TempHolding should have tokens");

        // Remove blacklist
        buyToken.setBlacklisted(swapper, false);

        // Swapper withdraws
        vm.prank(swapper);
        swapContract.getTempHolding(address(buyToken), swapper);

        // TempHolding cleared, swapper has tokens
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), 0, "TempHolding should be cleared");
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should have tokens now");
    }

    function testTempHolding_AnyoneCanCallGetTempHolding() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        uint256 expectedFulfill = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);

        buyToken.setBlacklisted(swapper, true);
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2000e18);

        buyToken.setBlacklisted(swapper, false);

        // Random address can call getTempHolding for swapper
        address randomUser = address(0x999);
        vm.prank(randomUser);
        swapContract.getTempHolding(address(buyToken), swapper);

        // Swapper receives tokens
        assertEq(buyToken.balanceOf(swapper), expectedFulfill, "Swapper should have tokens");
    }

    function testTempHolding_GetTempHoldingZeroAmountNoOp() public {
        // Calling getTempHolding when nothing is held should be a no-op
        uint256 balanceBefore = buyToken.balanceOf(swapper);

        vm.prank(swapper);
        swapContract.getTempHolding(address(buyToken), swapper);

        assertEq(buyToken.balanceOf(swapper), balanceBefore, "Balance unchanged");
    }

    // ============ Multiple Accumulation Tests ============

    function testTempHolding_MultipleSwapsAccumulate() public {
        // First swap
        uint256 swapId1 = _createSwap();
        _matchSwap(swapId1);
        buyToken.setBlacklisted(swapper, true);
        _submitReportAndSettle(swapId1, INITIAL_LIQUIDITY, 2000e18);

        uint256 expectedFulfill1 = _calcFulfillAmt(INITIAL_LIQUIDITY, 2000e18);
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), expectedFulfill1, "First swap in tempHolding");

        // Second swap
        uint256 swapId2 = _createSwap();
        _matchSwap(swapId2);
        _submitReportAndSettle(swapId2, INITIAL_LIQUIDITY, 2100e18);

        uint256 expectedFulfill2 = _calcFulfillAmt(INITIAL_LIQUIDITY, 2100e18);
        uint256 totalExpected = expectedFulfill1 + expectedFulfill2;

        assertEq(swapContract.tempHolding(swapper, address(buyToken)), totalExpected, "Both swaps accumulated in tempHolding");

        // Withdraw all at once
        buyToken.setBlacklisted(swapper, false);
        swapContract.getTempHolding(address(buyToken), swapper);

        assertEq(buyToken.balanceOf(swapper), totalExpected, "Swapper got all accumulated tokens");
        assertEq(swapContract.tempHolding(swapper, address(buyToken)), 0, "TempHolding cleared");
    }

    // ============ Refund Scenario Tests ============

    function testTempHolding_RefundSellTokenToSwapper() public {
        // In a refund scenario, sellToken goes back to swapper
        // sellToken is MockERC20 (no blacklist), so it should transfer normally

        uint256 swapperSellBefore = sellToken.balanceOf(swapper);

        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Verify sellToken left swapper
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper sent sellToken");

        // Trigger refund by exceeding minFulfillLiquidity
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2600e18);

        // Swapper gets sellToken back (direct transfer, no tempHolding)
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore, "Swapper got sellToken back");
        assertEq(swapContract.tempHolding(swapper, address(sellToken)), 0, "No tempHolding for sellToken");
    }

    function testTempHolding_RefundSellTokenToBlacklistedSwapper() public {
        // Use a blacklist token as sellToken to test tempHolding on refund
        BlacklistToken blacklistSellToken = new BlacklistToken("BlacklistSell", "BSELL");
        blacklistSellToken.transfer(swapper, 100e18);
        blacklistSellToken.transfer(initialReporter, 100e18);

        vm.prank(swapper);
        blacklistSellToken.approve(address(swapContract), type(uint256).max);

        vm.prank(initialReporter);
        blacklistSellToken.approve(address(bountyContract), type(uint256).max);

        // Create swap with blacklist sellToken
        vm.startPrank(swapper);
        openSwap.OracleParams memory oracleParams = openSwap.OracleParams({
            settlerReward: SETTLER_REWARD,
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            latencyBailout: LATENCY_BAILOUT,
            disputeDelay: DISPUTE_DELAY,
            swapFee: SWAP_FEE,
            protocolFee: PROTOCOL_FEE
        });
        openSwap.SlippageParams memory slippageParams = openSwap.SlippageParams({
            priceTolerated: 0,
            toleranceRange: 0
        });
        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(blacklistSellToken),
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

        _matchSwap(swapId);

        // Blacklist swapper for the sellToken before refund
        blacklistSellToken.setBlacklisted(swapper, true);

        // Trigger refund
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2600e18);

        // Swapper is blacklisted, so sellToken refund goes to tempHolding
        assertEq(swapContract.tempHolding(swapper, address(blacklistSellToken)), SELL_AMT, "SellToken in tempHolding");
        assertEq(blacklistSellToken.balanceOf(swapper), 100e18 - SELL_AMT, "Swapper didn't get sellToken directly");

        // Unblacklist and withdraw
        blacklistSellToken.setBlacklisted(swapper, false);
        swapContract.getTempHolding(address(blacklistSellToken), swapper);

        assertEq(blacklistSellToken.balanceOf(swapper), 100e18, "Swapper recovered sellToken");
        assertEq(swapContract.tempHolding(swapper, address(blacklistSellToken)), 0, "TempHolding cleared");
    }

    function testTempHolding_RefundBuyTokenToBlacklistedMatcher() public {
        uint256 swapId = _createSwap();
        _matchSwap(swapId);

        // Blacklist matcher before settlement
        buyToken.setBlacklisted(matcher, true);

        // Trigger refund
        _submitReportAndSettle(swapId, INITIAL_LIQUIDITY, 2600e18);

        // Matcher's buyToken refund goes to tempHolding
        assertEq(swapContract.tempHolding(matcher, address(buyToken)), MIN_FULFILL_LIQUIDITY, "Matcher buyToken in tempHolding");

        // Unblacklist and withdraw
        buyToken.setBlacklisted(matcher, false);
        swapContract.getTempHolding(address(buyToken), matcher);

        assertEq(buyToken.balanceOf(matcher), 100_000e18, "Matcher recovered all buyToken");
    }
}
