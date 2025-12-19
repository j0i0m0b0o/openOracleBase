// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/OpenOracle.sol";
import "../../src/openSwap.sol";
import "../../src/oracleBounty.sol";
import "../utils/MockERC20.sol";

/**
 * @title OpenSwapInputValidationTest
 * @notice Tests for swap() and matchSwap() input validations
 */
contract OpenSwapInputValidationTest is Test {
    OpenOracle internal oracle;
    openSwap internal swapContract;
    openOracleBounty internal bountyContract;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal swapper = address(0x1);
    address internal matcher = address(0x2);

    address constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 constant SETTLER_REWARD = 0.001 ether;
    uint256 constant BOUNTY_AMOUNT = 0.01 ether;
    uint256 constant INITIAL_LIQUIDITY = 1e18;
    uint48 constant SETTLEMENT_TIME = 300;
    uint24 constant DISPUTE_DELAY = 5;
    uint24 constant SWAP_FEE = 3000;
    uint24 constant PROTOCOL_FEE = 1000;
    uint48 constant LATENCY_BAILOUT = 600;
    uint48 constant MAX_GAME_TIME = 7200;

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
        // Mock WETH
        vm.etch(WETH, address(new MockERC20("WETH", "WETH")).code);

        oracle = new OpenOracle();
        bountyContract = new openOracleBounty(address(oracle));
        swapContract = new openSwap(address(oracle), address(bountyContract));

        sellToken = new MockERC20("SellToken", "SELL");
        buyToken = new MockERC20("BuyToken", "BUY");

        sellToken.transfer(swapper, 100e18);
        buyToken.transfer(matcher, 100_000e18);

        vm.deal(swapper, 100 ether);
        vm.deal(matcher, 100 ether);

        vm.prank(swapper);
        sellToken.approve(address(swapContract), type(uint256).max);

        vm.prank(matcher);
        buyToken.approve(address(swapContract), type(uint256).max);
    }

    function _validOracleParams() internal pure returns (openSwap.OracleParams memory) {
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

    function _validSlippageParams() internal pure returns (openSwap.SlippageParams memory) {
        return openSwap.SlippageParams({priceTolerated: 0, toleranceRange: 0});
    }

    function _validFulfillFeeParams() internal pure returns (openSwap.FulfillFeeParams memory) {
        return openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: MAX_FEE,
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });
    }

    // ============ swap() Token Validation Tests ============

    function testSwap_SellTokenEqualsBuyToken_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "sellToken = buyToken"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(sellToken), // same as sellToken
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_WETHSellETHBuy_Reverts() public {
        // Give swapper WETH tokens and approve
        deal(WETH, swapper, 100e18);
        vm.prank(swapper);
        IERC20(WETH).approve(address(swapContract), type(uint256).max);

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "sellToken = buyToken"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            WETH,
            MIN_OUT,
            address(0), // ETH
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_ETHSellWETHBuy_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "sellToken = buyToken"));
        swapContract.swap{value: SELL_AMT + GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            address(0), // ETH
            MIN_OUT,
            WETH,
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    // ============ swap() Zero Amount Tests ============

    function testSwap_ZeroSellAmt_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "zero amounts"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            0, // zero sellAmt
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_ZeroMinOut_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "zero amounts"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            address(sellToken),
            0, // zero minOut
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_ZeroMinFulfillLiquidity_Reverts() public {
        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "zero amounts"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            0, // zero minFulfillLiquidity
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    // ============ swap() FulfillFeeParams Tests ============

    function testSwap_MaxFeeTooHigh_Reverts() public {
        openSwap.FulfillFeeParams memory badFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: uint24(1e7), // maxFee >= 1e7
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillmentFee"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            badFeeParams
        );
        vm.stopPrank();
    }

    function testSwap_MaxFeeAtBoundary_Reverts() public {
        openSwap.FulfillFeeParams memory badFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: uint24(1e7), // Exactly 1e7 should revert
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "fulfillmentFee"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            badFeeParams
        );
        vm.stopPrank();
    }

    function testSwap_MaxFeeBelowBoundary_Succeeds() public {
        openSwap.FulfillFeeParams memory goodFeeParams = openSwap.FulfillFeeParams({
            startFulfillFeeIncrease: 0,
            maxFee: uint24(1e7 - 1), // 1e7 - 1 should work
            startingFee: STARTING_FEE,
            roundLength: ROUND_LENGTH,
            growthRate: GROWTH_RATE,
            maxRounds: MAX_ROUNDS
        });

        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT,
            address(sellToken),
            MIN_OUT,
            address(buyToken),
            MIN_FULFILL_LIQUIDITY,
            block.timestamp + 1 hours,
            BOUNTY_AMOUNT,
            GAS_COMPENSATION,
            _validOracleParams(),
            _validSlippageParams(),
            goodFeeParams
        );
        assertGt(swapId, 0, "Swap should be created");
        vm.stopPrank();
    }

    // ============ swap() OracleParams Tests ============

    function testSwap_SettlerRewardTooLow_Reverts() public {
        openSwap.OracleParams memory params = _validOracleParams();
        params.settlerReward = 99; // < 100

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + 99 + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_SwapFeeZero_Reverts() public {
        openSwap.OracleParams memory params = _validOracleParams();
        params.swapFee = 0;

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_SettlementTimeZero_Reverts() public {
        openSwap.OracleParams memory params = _validOracleParams();
        params.settlementTime = 0;

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_InitialLiquidityZero_Reverts() public {
        openSwap.OracleParams memory params = _validOracleParams();
        params.initialLiquidity = 0;

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_DisputeDelayGteSettlementTime_Reverts() public {
        openSwap.OracleParams memory params = _validOracleParams();
        params.disputeDelay = uint24(params.settlementTime); // disputeDelay >= settlementTime

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_EscalationHaltLtInitialLiquidity_Reverts() public {
        openSwap.OracleParams memory params = _validOracleParams();
        params.escalationHalt = params.initialLiquidity - 1; // escalationHalt < initialLiquidity

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_SettlementTimeTooLong_Reverts() public {
        openSwap.OracleParams memory params = _validOracleParams();
        params.settlementTime = 4 * 60 * 60 + 1; // > 4 hours

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    function testSwap_SwapFeePlusProtocolFeeTooHigh_Reverts() public {
        openSwap.OracleParams memory params = _validOracleParams();
        params.swapFee = 5e6;
        params.protocolFee = 5e6; // sum = 1e7, >= 1e7

        vm.startPrank(swapper);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "oracleParams"));
        swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            params, _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();
    }

    // ============ matchSwap() Validation Tests ============

    function testMatchSwap_ParamHashMismatch_Reverts() public {
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _validOracleParams(), _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();

        vm.startPrank(matcher);
        bytes32 wrongHash = keccak256("wrong");
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "params"));
        swapContract.matchSwap(swapId, wrongHash);
        vm.stopPrank();
    }

    function testMatchSwap_Expired_Reverts() public {
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _validOracleParams(), _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();

        // Warp past expiration
        vm.warp(block.timestamp + 2 hours);

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "expired"));
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();
    }

    function testMatchSwap_AlreadyMatched_Reverts() public {
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _validOracleParams(), _validSlippageParams(), _validFulfillFeeParams()
        );
        vm.stopPrank();

        // First match succeeds
        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        swapContract.matchSwap(swapId, swapHash);

        // Second match fails - need to get new hash since swap state changed
        bytes32 newSwapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "swap matched"));
        swapContract.matchSwap(swapId, newSwapHash);
        vm.stopPrank();
    }

    function testMatchSwap_Cancelled_Reverts() public {
        vm.startPrank(swapper);
        uint256 swapId = swapContract.swap{value: GAS_COMPENSATION + BOUNTY_AMOUNT + SETTLER_REWARD + 1}(
            SELL_AMT, address(sellToken), MIN_OUT, address(buyToken),
            MIN_FULFILL_LIQUIDITY, block.timestamp + 1 hours, BOUNTY_AMOUNT, GAS_COMPENSATION,
            _validOracleParams(), _validSlippageParams(), _validFulfillFeeParams()
        );
        swapContract.cancelSwap(swapId);
        vm.stopPrank();

        vm.startPrank(matcher);
        bytes32 swapHash = swapContract.getSwapHash(swapId);
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "swap cancelled"));
        swapContract.matchSwap(swapId, swapHash);
        vm.stopPrank();
    }

    function testMatchSwap_NotActive_Reverts() public {
        vm.startPrank(matcher);
        bytes32 fakeHash = keccak256(abi.encode(swapContract.getSwap(999)));
        vm.expectRevert(abi.encodeWithSelector(openSwap.InvalidInput.selector, "swap not active"));
        swapContract.matchSwap(999, fakeHash);
        vm.stopPrank();
    }
}
