// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBounty.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapMatchSwapTest
 * @notice Tests for matchSwap behavior and state changes
 *
 * Covers:
 * - State changes after match (matched, matcher, start, reportId)
 * - Token transfers during match
 * - Bounty creation
 * - Oracle report creation
 * - reportIdToSwapId mapping
 * - Self-matching behavior
 */
contract OpenSwapMatchSwapTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal matcher2 = address(0x3);

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

    function setUp() public {
        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        swapContract = new openSwap(address(oracle), address(bountyContract));

        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        sellToken.transfer(swapper, 100e18);
        buyToken.transfer(matcher, 100_000e18);
        buyToken.transfer(matcher2, 100_000e18);
        buyToken.transfer(swapper, 100_000e18); // For self-matching

        vm.deal(swapper, 10 ether);
        vm.deal(matcher, 10 ether);
        vm.deal(matcher2, 10 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher2);
        buyToken.approve(address(swapContract), type(uint256).max);

        vm.prank(swapper);
        buyToken.approve(address(swapContract), type(uint256).max);
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

    // ============ State Change Tests ============

    function testMatchSwap_SetsMatchedTrue() public {
        uint256 swapId = _createSwap();

        openSwap.Swap memory sBefore = swapContract.getSwap(swapId);
        assertFalse(sBefore.matched, "Should not be matched before");

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.matched, "Should be matched after");
    }

    function testMatchSwap_SetsMatcher() public {
        uint256 swapId = _createSwap();

        openSwap.Swap memory sBefore = swapContract.getSwap(swapId);
        assertEq(sBefore.matcher, address(0), "Matcher should be zero before");

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertEq(sAfter.matcher, matcher, "Matcher should be set after");
    }

    function testMatchSwap_SetsStartTimestamp() public {
        uint256 swapId = _createSwap();

        openSwap.Swap memory sBefore = swapContract.getSwap(swapId);
        assertEq(sBefore.start, 0, "Start should be zero before");

        uint256 matchTimestamp = block.timestamp + 100;
        vm.warp(matchTimestamp);

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertEq(sAfter.start, matchTimestamp, "Start should be set to match timestamp");
    }

    function testMatchSwap_SetsReportId() public {
        uint256 swapId = _createSwap();

        openSwap.Swap memory sBefore = swapContract.getSwap(swapId);
        assertEq(sBefore.reportId, 0, "ReportId should be zero before");

        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertEq(sAfter.reportId, expectedReportId, "ReportId should be set");
    }

    function testMatchSwap_SetsReportIdToSwapIdMapping() public {
        uint256 swapId = _createSwap();

        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        uint256 mappedSwapId = swapContract.reportIdToSwapId(expectedReportId);
        assertEq(mappedSwapId, swapId, "reportIdToSwapId should map correctly");
    }

    // ============ Token Transfer Tests ============

    function testMatchSwap_TransfersBuyTokenFromMatcher() public {
        uint256 swapId = _createSwap();

        uint256 matcherBefore = buyToken.balanceOf(matcher);
        uint256 contractBefore = buyToken.balanceOf(address(swapContract));

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        uint256 matcherAfter = buyToken.balanceOf(matcher);
        uint256 contractAfter = buyToken.balanceOf(address(swapContract));

        assertEq(matcherAfter, matcherBefore - MIN_FULFILL_LIQUIDITY, "Matcher should have sent minFulfillLiquidity");
        assertEq(contractAfter, contractBefore + MIN_FULFILL_LIQUIDITY, "Contract should have received minFulfillLiquidity");
    }

    function testMatchSwap_SellTokenAlreadyInContract() public {
        uint256 contractBefore = sellToken.balanceOf(address(swapContract));

        uint256 swapId = _createSwap();

        // After swap creation, sellToken should be in contract
        uint256 contractAfterCreate = sellToken.balanceOf(address(swapContract));
        assertEq(contractAfterCreate, contractBefore + SELL_AMT, "Contract should hold sellToken after create");

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // After match, sellToken should still be in contract (no change)
        uint256 contractAfterMatch = sellToken.balanceOf(address(swapContract));
        assertEq(contractAfterMatch, contractAfterCreate, "sellToken balance unchanged by match");
    }

    // ============ Bounty Creation Tests ============

    function testMatchSwap_CreatesBounty() public {
        uint256 swapId = _createSwap();
        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // Check bounty was created via bountyContract
        (,uint256 bountyStartAmt,,,,,,,,,,) = bountyContract.Bounty(expectedReportId);
        assertEq(bountyStartAmt, BOUNTY_AMOUNT / 20, "Bounty startAmt should be requiredBounty / 20");
    }

    function testMatchSwap_BountyCreatorIsSwapper() public {
        uint256 swapId = _createSwap();
        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // Check bounty creator (6th field in Bounties struct)
        (,,,,,address creator,,,,,,) = bountyContract.Bounty(expectedReportId);
        assertEq(creator, swapper, "Bounty creator should be swapper");
    }

    function testMatchSwap_BountyEditorIsSwapContract() public {
        uint256 swapId = _createSwap();
        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // Check bounty editor (7th field in Bounties struct)
        (,,,,,,address editor,,,,,) = bountyContract.Bounty(expectedReportId);
        assertEq(editor, address(swapContract), "Bounty editor should be swap contract");
    }

    // ============ Oracle Report Creation Tests ============

    function testMatchSwap_CreatesOracleReport() public {
        uint256 swapId = _createSwap();
        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // Check oracle report exists
        (,,,,,,,,, bool isDistributed) = oracle.reportStatus(expectedReportId);
        assertFalse(isDistributed, "Report should exist but not be distributed yet");
    }

    function testMatchSwap_OracleReportHasCorrectTokens() public {
        uint256 swapId = _createSwap();
        uint256 expectedReportId = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // Check report tokens from reportMeta
        (,,,, address token1,, address token2,,,,,) = oracle.reportMeta(expectedReportId);
        assertEq(token1, address(sellToken), "Report token1 should be sellToken");
        assertEq(token2, address(buyToken), "Report token2 should be buyToken");
    }

    // ============ Self-Matching Tests ============

    function testMatchSwap_SwapperCanMatchOwnSwap() public {
        uint256 swapId = _createSwap();

        vm.startPrank(swapper);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.matched, "Swap should be matched");
        assertEq(s.matcher, swapper, "Matcher should be swapper");
    }

    function testMatchSwap_SwapperSelfMatchTokenBalances() public {
        uint256 swapperSellBefore = sellToken.balanceOf(swapper);
        uint256 swapperBuyBefore = buyToken.balanceOf(swapper);

        uint256 swapId = _createSwap();

        // After creating swap, swapper sent sellToken
        assertEq(sellToken.balanceOf(swapper), swapperSellBefore - SELL_AMT, "Swapper sent sellToken");

        vm.startPrank(swapper);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // After self-matching, swapper also sent buyToken
        assertEq(buyToken.balanceOf(swapper), swapperBuyBefore - MIN_FULFILL_LIQUIDITY, "Swapper sent buyToken for match");
    }

    // ============ Multiple Swaps/Matchers Tests ============

    function testMatchSwap_DifferentMatchersForDifferentSwaps() public {
        uint256 swapId1 = _createSwap();
        uint256 swapId2 = _createSwap();

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

        openSwap.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwap.Swap memory s2 = swapContract.getSwap(swapId2);

        assertEq(s1.matcher, matcher, "Swap1 matcher should be matcher");
        assertEq(s2.matcher, matcher2, "Swap2 matcher should be matcher2");
    }

    function testMatchSwap_ReportIdsAreSequential() public {
        uint256 swapId1 = _createSwap();
        uint256 swapId2 = _createSwap();

        uint256 expectedReportId1 = oracle.nextReportId();

        vm.startPrank(matcher);
        bytes32 swapHash1 = swapContract.getSwapHash(swapId1);
        swapContract.matchSwap(swapId1, swapHash1);
        vm.stopPrank();

        uint256 expectedReportId2 = oracle.nextReportId();

        vm.startPrank(matcher2);
        bytes32 swapHash2 = swapContract.getSwapHash(swapId2);
        swapContract.matchSwap(swapId2, swapHash2);
        vm.stopPrank();

        openSwap.Swap memory s1 = swapContract.getSwap(swapId1);
        openSwap.Swap memory s2 = swapContract.getSwap(swapId2);

        assertEq(s1.reportId, expectedReportId1, "Swap1 reportId should match");
        assertEq(s2.reportId, expectedReportId2, "Swap2 reportId should match");
        assertEq(s2.reportId, s1.reportId + 1, "ReportIds should be sequential");
    }

}
