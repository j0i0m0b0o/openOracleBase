// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBounty.sol";
import "../utils/MockERC20.sol";
import "../../src/interfaces/IWETH.sol";

/**
 * @title OpenSwapETHTest
 * @notice Tests for native ETH swaps (sellToken or buyToken = address(0))
 */
contract OpenSwapETHTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal token;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);
    address internal initialReporter = address(0x3);
    address internal settler = address(0x4);

    address constant WETH = 0x4200000000000000000000000000000000000006;

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
    uint256 constant SELL_AMT = 1 ether;
    uint256 constant MIN_OUT = 1900e18;
    uint256 constant MIN_FULFILL_LIQUIDITY = 2500e18;
    uint256 constant FULFILLMENT_FEE = 10000;

    function setUp() public {
        // Deploy mock WETH and use vm.etch to put it at the WETH address
        MockERC20 mockWeth = new MockERC20("WETH", "WETH");
        vm.etch(WETH, address(mockWeth).code);

        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        swapContract = new openSwap(address(oracle), address(bountyContract));

        token = new MockERC20("Token", "TKN");

        // Fund participants
        token.transfer(swapper, 100e18);
        token.transfer(matcher, 100_000e18);
        token.transfer(initialReporter, 100_000e18);

        // Give reporter mock WETH tokens using deal (sets balance directly)
        deal(WETH, initialReporter, 10e18);

        vm.deal(swapper, 100 ether);
        vm.deal(matcher, 100 ether);
        vm.deal(initialReporter, 10 ether);
        vm.deal(settler, 1 ether);

        // Approvals
        vm.prank(swapper);
        token.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher);
        token.approve(address(swapContract), type(uint256).max);

        vm.startPrank(initialReporter);
        token.approve(address(bountyContract), type(uint256).max);
        // Need WETH approval for oracle game
        IERC20(WETH).approve(address(bountyContract), type(uint256).max);
        IERC20(WETH).approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    function _getOracleParams() internal pure returns (openSwap.OracleParams memory) {
        return openSwap.OracleParams({
            settlerReward: SETTLER_REWARD,
            initialLiquidity: INITIAL_LIQUIDITY,
            escalationHalt: SELL_AMT * 2,
            settlementTime: SETTLEMENT_TIME,
            latencyBailout: LATENCY_BAILOUT,
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

    // ============ ETH → ERC20 Tests ============

    function testETHToToken_CreateSwap() public {
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = SELL_AMT + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        vm.startPrank(swapper);

        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(0), // sellToken = ETH
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );

        vm.stopPrank();

        // Verify ETH transferred
        assertEq(swapper.balance, swapperEthBefore - ethToSend, "Swapper should have sent ETH");
        // Contract holds sellAmt + bounty + settlerReward + 1 (bounty forwarded on match)
        assertEq(address(swapContract).balance, ethToSend, "Contract should hold all ETH until match");

        // Verify swap state
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.sellToken, address(0), "sellToken should be address(0)");
        assertEq(s.sellAmt, SELL_AMT, "sellAmt should match");
        assertEq(s.buyToken, address(token), "buyToken should be token");
        assertTrue(s.active, "Swap should be active");
    }

    function testETHToToken_FullFlow() public {
        uint256 swapperTokenBefore = token.balanceOf(swapper);
        uint256 matcherTokenBefore = token.balanceOf(matcher);
        uint256 matcherEthBefore = matcher.balance;
        uint256 ethToSend = SELL_AMT + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        // Create swap: ETH → Token
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );
        vm.stopPrank();

        // Match swap
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // Verify matcher sent tokens
        assertEq(token.balanceOf(matcher), matcherTokenBefore - MIN_FULFILL_LIQUIDITY, "Matcher should have sent tokens");

        // Submit report and settle
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(s.reportId);

        // Reporter already has mock WETH from setUp, just submit report
        // Report: 1 WETH = 2000 tokens (amount1=WETH, amount2=token)
        vm.prank(initialReporter);
        bountyContract.submitInitialReport(s.reportId, INITIAL_LIQUIDITY, 2000e18, stateHash, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);
        vm.prank(settler);
        oracle.settle(s.reportId);

        // Verify swap completed
        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished");

        // Calculate expected fulfillAmt
        uint256 fulfillAmt = (SELL_AMT * 2000e18) / INITIAL_LIQUIDITY;
        fulfillAmt -= fulfillAmt * FULFILLMENT_FEE / 1e7;

        // Swapper should have received tokens (initial balance + fulfillAmt)
        assertEq(token.balanceOf(swapper), swapperTokenBefore + fulfillAmt, "Swapper should have received tokens");

        // Matcher should have received ETH (sellAmt)
        assertEq(matcher.balance, matcherEthBefore + SELL_AMT, "Matcher should have received ETH");
    }

    function testETHToToken_Cancel() public {
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = SELL_AMT + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );

        // Cancel
        swapContract.cancelSwap(swapId);
        vm.stopPrank();

        // Verify ETH returned
        assertEq(swapper.balance, swapperEthBefore, "Swapper should have all ETH back");
        assertEq(address(swapContract).balance, 0, "Contract should have no ETH");
    }

    // ============ ERC20 → ETH Tests ============

    function testTokenToETH_CreateSwap() public {
        uint256 swapperTokenBefore = token.balanceOf(swapper);
        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        vm.startPrank(swapper);

        uint256 swapId = swapContract.swap{value: ethToSend}(
            10e18, // sellAmt in tokens
            address(token), // sellToken = token
            1e17, // minOut in ETH (0.1 ETH)
            address(0), // buyToken = ETH
            1 ether, // minFulfillLiquidity in ETH
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );

        vm.stopPrank();

        // Verify tokens transferred
        assertEq(token.balanceOf(swapper), swapperTokenBefore - 10e18, "Swapper should have sent tokens");
        assertEq(token.balanceOf(address(swapContract)), 10e18, "Contract should hold tokens");

        // Verify swap state
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertEq(s.sellToken, address(token), "sellToken should be token");
        assertEq(s.buyToken, address(0), "buyToken should be address(0)");
    }

    function testTokenToETH_MatchWithETH() public {
        uint256 matcherEthBefore = matcher.balance;
        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;
        uint256 minFulfillETH = 1 ether;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            10e18,
            address(token),
            1e17,
            address(0),
            minFulfillETH,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );
        vm.stopPrank();

        // Match with ETH
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap{value: minFulfillETH}(swapId, swapHash);
        vm.stopPrank();

        // Verify matcher sent ETH
        assertEq(matcher.balance, matcherEthBefore - minFulfillETH, "Matcher should have sent ETH");

        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.matched, "Swap should be matched");
        assertEq(s.matcher, matcher, "Matcher should be set");
    }

    function testTokenToETH_FullFlow() public {
        uint256 matcherTokenBefore = token.balanceOf(matcher);
        uint256 swapperEthBefore = swapper.balance;
        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;
        uint256 minFulfillETH = 1 ether;
        uint256 sellAmtTokens = 10e18;

        // Create swap: Token → ETH
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            sellAmtTokens,
            address(token),
            1e17, // minOut
            address(0),
            minFulfillETH,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );
        vm.stopPrank();

        uint256 swapperEthAfterCreate = swapper.balance;

        // Match with ETH
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap{value: minFulfillETH}(swapId, swapHash);
        vm.stopPrank();

        // Submit report and settle
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        (bytes32 stateHash,,,,,,,) = oracle.extraData(s.reportId);

        // Reporter already has mock WETH and token from setUp
        // Report: 1 token = 0.05 ETH (so 10 tokens = 0.5 ETH)
        // token1 = token, token2 = WETH
        // amount1 = 1e18 (token), amount2 = 5e16 (0.05 WETH)
        vm.prank(initialReporter);
        bountyContract.submitInitialReport(s.reportId, INITIAL_LIQUIDITY, 5e16, stateHash, initialReporter);

        vm.warp(block.timestamp + SETTLEMENT_TIME + 1);

        vm.prank(settler);
        oracle.settle(s.reportId);

        // Verify swap completed
        openSwap.Swap memory sAfter = swapContract.getSwap(swapId);
        assertTrue(sAfter.finished, "Swap should be finished");

        // Calculate expected fulfillAmt in ETH
        uint256 fulfillAmt = (sellAmtTokens * 5e16) / INITIAL_LIQUIDITY;
        fulfillAmt -= fulfillAmt * FULFILLMENT_FEE / 1e7;

        // Bounty recall: totalDeposited - bountyClaimed
        // bountyClaimed = bountyStartAmt (since claimed same block, 0 rounds)
        // bountyStartAmt = BOUNTY_AMOUNT / 20 = 0.01e18 / 20 = 5e14
        // recall = 0.01e18 - 5e14 = 9.5e15
        uint256 bountyRecall = BOUNTY_AMOUNT - (BOUNTY_AMOUNT / 20);

        // Swapper should have received ETH (fulfillAmt + bounty recall)
        assertEq(swapper.balance, swapperEthAfterCreate + fulfillAmt + bountyRecall, "Swapper should have received ETH");

        // Matcher should have received tokens
        assertEq(token.balanceOf(matcher), matcherTokenBefore + sellAmtTokens, "Matcher should have received tokens");
    }

    // ============ ETH msg.value Validation Tests ============

    function testETHToToken_WrongMsgValue_Reverts() public {
        uint256 ethToSend = SELL_AMT + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        vm.startPrank(swapper);

        // Send wrong amount (missing sellAmt)
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "msg.value vs sellAmt mismatch"));
        swapContract.swap{value: BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );

        vm.stopPrank();
    }

    function testTokenToETH_MatchWrongMsgValue_Reverts() public {
        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;
        uint256 minFulfillETH = 1 ether;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            10e18,
            address(token),
            1e17,
            address(0),
            minFulfillETH,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );
        vm.stopPrank();

        // Match with wrong ETH amount
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);

        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "msg.value"));
        swapContract.matchSwap{value: minFulfillETH - 1}(swapId, swapHash);

        vm.stopPrank();
    }

    function testTokenToToken_MatchWithETH_Reverts() public {
        // Create ERC20 → ERC20 swap
        MockERC20 otherToken = new MockERC20("Other", "OTH");
        otherToken.transfer(matcher, 100_000e18);

        vm.prank(matcher);
        otherToken.approve(address(swapContract), type(uint256).max);

        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            10e18,
            address(token),
            1e18,
            address(otherToken),
            100e18,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );
        vm.stopPrank();

        // Try to match with ETH (should fail since buyToken is not ETH)
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);

        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "selling eth but no msg.value"));
        swapContract.matchSwap{value: 1 ether}(swapId, swapHash);

        vm.stopPrank();
    }

    // ============ BailOut with ETH Tests ============

    function testETHToToken_BailOut() public {
        uint256 matcherTokenBefore = token.balanceOf(matcher);
        uint256 ethToSend = SELL_AMT + BOUNTY_AMOUNT + SETTLER_REWARD + 1;

        // Create and match
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            SELL_AMT,
            address(0),
            MIN_OUT,
            address(token),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );
        vm.stopPrank();

        uint256 swapperEthAfterCreate = swapper.balance;

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();

        // Warp past latency bailout
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        swapContract.bailOut(swapId);

        // Verify swap finished
        openSwap.Swap memory s = swapContract.getSwap(swapId);
        assertTrue(s.finished, "Swap should be finished");

        // Swapper gets sellAmt ETH back + full bounty recall (not claimed since no initial report)
        assertEq(swapper.balance, swapperEthAfterCreate + SELL_AMT + BOUNTY_AMOUNT, "Swapper should have sellAmt + bounty ETH back");
        // Matcher gets tokens back
        assertEq(token.balanceOf(matcher), matcherTokenBefore, "Matcher should have tokens back");
    }

    function testTokenToETH_BailOut() public {
        uint256 swapperTokenBefore = token.balanceOf(swapper);
        uint256 matcherEthBefore = matcher.balance;
        uint256 ethToSend = BOUNTY_AMOUNT + SETTLER_REWARD + 1;
        uint256 minFulfillETH = 1 ether;

        // Create and match
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: ethToSend}(
            10e18,
            address(token),
            1e17,
            address(0),
            minFulfillETH,
            block.timestamp + 1 hours,
            FULFILLMENT_FEE,
            BOUNTY_AMOUNT,
            _getOracleParams(),
            _getSlippageParams()
        );
        vm.stopPrank();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap{value: minFulfillETH}(swapId, swapHash);
        vm.stopPrank();

        // Warp past latency bailout
        vm.warp(block.timestamp + LATENCY_BAILOUT + 1);
        swapContract.bailOut(swapId);

        // Verify refunds
        assertEq(token.balanceOf(swapper), swapperTokenBefore, "Swapper should have tokens back");
        assertEq(matcher.balance, matcherEthBefore, "Matcher should have ETH back");
    }
}
