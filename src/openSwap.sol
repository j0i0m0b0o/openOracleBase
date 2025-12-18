// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IBounty} from "./interfaces/IBounty.sol";

/**
 * @title openSwap
 * @notice Uses openOracle for swap execution
           Different from simpleSwapper since there's no choice about fulfilling or not
 * @author OpenOracle Team
 * @custom:version 0.1.6
 * @custom:documentation https://openprices.gitbook.io/openoracle-docs
 */

 //TODO: rescue funds if settle executed but callback bricked
 //TODO: _transferTokens like oracle contract for erc20 transfer brick handling
 //TODO: add slippage protection for matcher
 //THIS CONTRACT IS JUST A SKETCH SO FAR
contract openSwap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IBounty public immutable bounty;
    IOpenOracle public immutable oracle;
    address public immutable WETH = 0x4200000000000000000000000000000000000006;

    error InvalidInput(string);
    error EthTransferFailed();

    constructor(address oracle_, address bounty_) {
        oracle = IOpenOracle(oracle_);
        bounty = IBounty(bounty_);
    }

    mapping (uint256 => Swap) swaps;
    uint256 public nextSwapId = 1;

    mapping (uint256 => uint256) reportIdToSwapId;

    struct Swap {
        uint256 sellAmt;
        uint256 minOut;
        uint256 minFulfillLiquidity;
        uint256 expiration;
        uint256 fulfillmentFee;
        uint256 requiredBounty;
        uint256 reportId;
        address sellToken;
        address buyToken;
        address swapper;
        address matcher;
        bool active;
        bool matched;
        bool finished;
        bool cancelled;
        OracleParams oracleParams;
    }

    struct OracleParams {
        uint256 settlerReward;
        uint48 settlementTime;
        uint24 disputeDelay;
        uint24 swapFee;
        uint24 protocolFee;
    }

    event SwapCreated(uint256 indexed swapId, uint256 sellAmt, address sellToken, uint256 minOut, address buyToken, uint256 minFulfillLiquidity, uint256 expiration, uint256 fulfillmentFee, uint256 blockTimestamp);
    event SwapCancelled(uint256 swapId);

    function swap(uint256 sellAmt, address sellToken, uint256 minOut, address buyToken, uint256 minFulfillLiquidity, uint256 expiration, uint256 fulfillmentFee, uint256 requiredBounty, OracleParams memory oracleParams) external payable nonReentrant returns(uint256 swapId) {
        if (sellToken == address(0) && msg.value == 0) revert InvalidInput("selling eth but no msg.value");
        if (sellToken == address(0) && msg.value != sellAmt) revert InvalidInput("msg.value vs sellAmt mismatch");
        if (sellToken == buyToken) revert InvalidInput("sellToken = buyToken");
        if (sellAmt == 0 || minOut == 0 || minFulfillLiquidity == 0) revert InvalidInput("zero amounts");
        if (fulfillmentFee >= 1e7) revert InvalidInput("fulfillmentFee"); 
        if (oracleParams.settlerReward == 0 
            || oracleParams.swapFee == 0 
            || oracleParams.settlementTime == 0 
            || oracleParams.disputeDelay >= oracleParams.settlementTime
            ) revert InvalidInput("oracleParams");

        swapId = nextSwapId++;
        Swap storage s = swaps[swapId];
        
        s.swapper = msg.sender;
        s.sellAmt = sellAmt;
        s.sellToken = sellToken;
        s.minOut = minOut;
        s.buyToken = buyToken;
        s.minFulfillLiquidity =  minFulfillLiquidity;
        s.expiration = expiration;
        s.fulfillmentFee = fulfillmentFee;
        s.active = true;
        s.requiredBounty = requiredBounty;
        s.oracleParams = oracleParams;

        if (sellToken != address(0)) {
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmt);
        }

        emit SwapCreated(swapId, sellAmt, sellToken, minOut, buyToken, minFulfillLiquidity, expiration, fulfillmentFee, block.timestamp);
    }

    function matchSwap(uint256 swapId) external payable nonReentrant {
        Swap storage s = swaps[swapId];
        OracleParams memory o = s.oracleParams;

        if (s.buyToken == address(0) && msg.value == 0) revert InvalidInput("selling eth but no msg.value");
        if (s.buyToken == address(0) && msg.value != s.minFulfillLiquidity + s.requiredBounty + o.settlerReward + 1) revert InvalidInput("msg.value");
        if (s.buyToken != address(0) && msg.value != s.requiredBounty + o.settlerReward + 1) revert InvalidInput("msg.value");

        if (s.cancelled) revert InvalidInput("swap cancelled");
        if (s.matched) revert InvalidInput("swap matched");
        if (!s.active) revert InvalidInput("swap not active");
        if (s.finished) revert InvalidInput("finished");
        if (block.timestamp > s.expiration) revert InvalidInput("expired");

        s.matched = true;
        s.matcher = msg.sender;

        if(s.buyToken != address(0)) {
            IERC20(s.buyToken).safeTransferFrom(msg.sender, address(this), s.minFulfillLiquidity);
        }

        bounty.createOracleBountyFwd{value: s.requiredBounty}(
            oracle.nextReportId(),
            s.requiredBounty / 10,
            msg.sender,
            address(this),
            14142,
            10,
            true,
            0
        );

        uint256 reportId = oracleGame(s);
        s.reportId = reportId;
        reportIdToSwapId[reportId] = swapId;

    }

    function cancelSwap(uint256 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];

        if (msg.sender != s.swapper) revert InvalidInput("not swapper");
        if (s.matched) revert InvalidInput("already matched");
        if (!s.active) revert InvalidInput("not active");
        if (s.cancelled) revert InvalidInput("cancelled");
        if (s.finished) revert InvalidInput("finished");

        s.cancelled = true;

        if (s.sellToken != address(0)) {
            IERC20(s.sellToken).safeTransfer(msg.sender, s.sellAmt);
        } else {
            (bool ok,) = payable(s.swapper).call{value: s.sellAmt, gas: 40000}("");
            if (!ok) {
                IWETH(WETH).deposit{value: s.sellAmt}();
                IERC20(WETH).safeTransfer(s.swapper, s.sellAmt);
            }
        }

        emit SwapCancelled(swapId);
    }

    function oracleGame(Swap memory s) internal nonReentrant returns (uint256 reportId) {
        OracleParams memory o = s.oracleParams;
        address token1;
        address token2;

        if (s.sellToken == address(0)){
            token1 = WETH;
            token2 = s.buyToken;
        } else if (s.buyToken == address(0)) {
            token1 = s.sellToken;
            token2 = WETH;
        } else {
            token1 = s.sellToken;
            token2 = s.buyToken;
        }

        IOpenOracle.CreateReportParams memory params = IOpenOracle.CreateReportParams({
            exactToken1Report: s.sellAmt / 10,
            escalationHalt: s.sellAmt * 2,
            settlerReward: o.settlerReward,
            token1Address: token1,
            settlementTime: o.settlementTime,
            disputeDelay: o.disputeDelay,
            protocolFee: o.protocolFee,
            token2Address: token2,
            callbackGasLimit: 1000000,
            feePercentage: o.swapFee,
            multiplier: 110,
            timeType: true,
            trackDisputes: false,
            keepFee: true,
            callbackContract: address(this),
            callbackSelector: this.onSettle.selector,
            protocolFeeRecipient: address(0) // make this a feerecipient contract
        });

        /* ------------ create report instance ------------ */
        reportId = oracle.createReportInstance{value: o.settlerReward + 1}(params);
        return reportId;

    }

    /* -------- oracle callback -------- */
    function onSettle(uint256 id, uint256, uint256, address, address)
        external
        payable
        nonReentrant
    {
        if (msg.sender != address(oracle)) revert InvalidInput("invalid sender");
        Swap storage s = swaps[id];
        if (id != swaps[reportIdToSwapId[id]].reportId) revert InvalidInput("wrong reportId");

        s.finished = true;

        IOpenOracle.ReportStatus memory rs = oracle.reportStatus(id);
        uint256 oracleAmount1 = rs.currentAmount1;
        uint256 oracleAmount2 = rs.currentAmount2;
        uint256 fulfillAmt = (s.sellAmt * oracleAmount2) / oracleAmount1;
        fulfillAmt -= fulfillAmt * s.fulfillmentFee / 1e7;

        if (fulfillAmt > s.minFulfillLiquidity || fulfillAmt < s.minOut) {
            //end swap. wrap in tempHolding _transferTokens logic eventually.
            if (s.sellToken != address(0)){
                IERC20(s.sellToken).safeTransfer(s.swapper, s.sellAmt);
                if (s.buyToken != address(0)){
                    IERC20(s.buyToken).safeTransfer(s.matcher, s.minFulfillLiquidity);
                } else {
                    payEth(s.matcher, s.minFulfillLiquidity);
                }
            } else {
                payEth(s.swapper, s.sellAmt);
                IERC20(s.buyToken).safeTransfer(s.matcher, s.minFulfillLiquidity);
            }
        } else {
            //complete swap
            if (s.buyToken != address(0)){
                IERC20(s.buyToken).safeTransfer(s.swapper, fulfillAmt);
                IERC20(s.buyToken).safeTransfer(s.matcher, s.minFulfillLiquidity - fulfillAmt);
                if (s.sellToken != address(0)) {
                    IERC20(s.sellToken).safeTransfer(s.matcher, s.sellAmt);
                } else {
                    payEth(s.matcher, s.sellAmt);
                }
            } else {
                payEth(s.swapper, fulfillAmt);
                payEth(s.matcher, s.minFulfillLiquidity - fulfillAmt);
                IERC20(s.sellToken).safeTransfer(s.matcher, s.sellAmt);
            }
        }

        // maxRounds > 0 checks if bounty exists for this reportId
        IBounty.Bounties memory b = bounty.Bounty(id);
        if (b.maxRounds > 0 && !b.recalled) {
            try bounty.recallBounty(id) {} catch {}
        }

    }

    function payEth(address _to, uint256 _amount) internal nonReentrant {
        (bool ok,) = payable(_to).call{value: _amount, gas: 40000}("");
        if (!ok) {
            IWETH(WETH).deposit{value: _amount}();
            IERC20(WETH).safeTransfer(_to, _amount);
        }
    }

}
