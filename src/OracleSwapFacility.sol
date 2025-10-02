// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";

/* ****************************************************
 *            OracleSwapFacility (v0.1)                *
 ***************************************************** */
contract OracleSwapFacility is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* immutables */
    IOpenOracle public immutable oracle;

    /* -------- EVENTS -------- */
    event SwapReportOpened(
        uint256 indexed reportId,
        address indexed user,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feePaidWei
    );

    constructor(address oracle_) {
        require(oracle_ != address(0), "oracle addr 0");
        oracle = IOpenOracle(oracle_);
    }

    //overloaded functions to keep createAndReport backwards-compatibility with simple settings
    function createAndReport(
        address token1,
        address token2,
        uint256 amount1,
        uint256 amount2,
        uint256 fee,
        uint256 settlementTime
    ) external payable nonReentrant returns (uint256 reportId) {
        reportId = _createAndReport(
            token1,
            token2,
            amount1,
            amount2,
            fee,
            settlementTime,
            true,
            address(0),
            bytes4(0),
            false,
            0,
            false,
            101,
            0,
            amount1
        );
    }
    // createAndReport with full customizability

    function createAndReport(
        address token1,
        address token2,
        uint256 amount1,
        uint256 amount2,
        uint256 fee,
        uint256 settlementTime,
        bool timeType,
        address callbackContract,
        bytes4 callbackSelector,
        bool trackDisputes,
        uint256 callbackGasLimit,
        bool keepFee,
        uint256 multiplier,
        uint256 disputeDelay,
        uint256 escalationHalt
    ) external payable nonReentrant returns (uint256 reportId) {
        reportId = _createAndReport(
            token1,
            token2,
            amount1,
            amount2,
            fee,
            settlementTime,
            timeType,
            callbackContract,
            callbackSelector,
            trackDisputes,
            callbackGasLimit,
            keepFee,
            multiplier,
            disputeDelay,
            escalationHalt
        );
    }

    //you tend to receive the token whose amount converted to USD is smaller
    //percent difference in value minus fee converted to percent is total net execution cost of swap ex-gas
    //configure amount1, amount2 and fee so you end up paying a net fee you are comfortable with
    //msg.value should be ~0.000004 ETH at 0.01 gwei gas and no L1 congestion to ensure oracle settlement
    function _createAndReport(
        address token1,
        address token2,
        uint256 amount1,
        uint256 amount2,
        uint256 fee, // 2222 = 2.222bps
        uint256 settlementTime, // how long your tokens are locked up in seconds. NOT a timestamp
        bool timeType,
        address callbackContract,
        bytes4 callbackSelector,
        bool trackDisputes,
        uint256 callbackGasLimit,
        bool keepFee,
        uint256 multiplier,
        uint256 disputeDelay,
        uint256 escalationHalt
    ) internal returns (uint256 reportId) {
        require(token1 != token2, "tokens identical");
        require(amount1 > 0 && amount2 > 0, "zero amounts");
        if (msg.value <= 100) revert("not enough msg.value");

        /* ------------ pull the user’s tokens ------------ */
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        IERC20(token2).safeTransferFrom(msg.sender, address(this), amount2);

        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: amount1,
            escalationHalt: escalationHalt,
            settlerReward: msg.value - 1,
            token1Address: token1,
            settlementTime: uint48(settlementTime),
            disputeDelay: uint24(disputeDelay),
            protocolFee: 0,
            token2Address: token2,
            callbackGasLimit: uint32(callbackGasLimit),
            feePercentage: uint24(fee),
            multiplier: uint16(multiplier),
            timeType: timeType,
            trackDisputes: trackDisputes,
            keepFee: keepFee,
            callbackContract: callbackContract,
            callbackSelector: callbackSelector,
            protocolFeeRecipient: address(0)
        });

        /* ------------ create report instance ------------ */
        reportId = oracle.createReportInstance{value: msg.value}(params);

        /* ------------ let oracle move the tokens -------- */
        IERC20(token1).safeIncreaseAllowance(address(oracle), amount1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), amount2);

        bytes32 stateHash = oracle.extraData(reportId).stateHash;

        /* ------------ file the initial report ----------- */
        oracle.submitInitialReport(reportId, amount1, amount2, stateHash, msg.sender);

        emit SwapReportOpened(reportId, msg.sender, token1, token2, amount1, amount2, msg.value);
    }
}
