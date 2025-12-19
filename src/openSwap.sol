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
 * @notice Uses openOracle for swap execution price
           Different from simpleSwapper since there's no choice about whether to fulfill
           simpleSwapper flow is deposit sellToken -> oracle game ends in price -> anyone has choice to swap against that price
           openSwap flow is deposit sellToken -> someone matches with enough buyToken -> oracle game ends in price -> swap executed against price
           In general it is our belief that this swapping method may offer extremely cheap mean swap execution costs so it is worth pursuing.
           The design is compatible with long round times (settlementTime) in the oracle game, since manipulating the oracle is the same game at any time scale:
                      https://openprices.gitbook.io/openoracle-docs/contents/considerations#manipulation-without-a-swap-fee
           The bias scales with something like the square root of the settlementTime.
           It is hard to bias the mean finalized oracle price much off from true, even if the matcher in this contract is doing their best.
           The geometry of the dispute barriers in the oracle game ensures very low survival probabilites for any prices reported off true.
           The closer you get to true, the lower the extraction. Farther from true, the survival probabilities approach 0 much faster than extraction increases.
 * @author OpenOracle Team
 * @custom:version 0.1.6
 * @custom:documentation https://openprices.gitbook.io/openoracle-docs
 */

 //TODO: rescue funds if settle executed but callback bricked - done
 //TODO: _transferTokens like oracle contract for erc20 transfer brick handling - done
 //TODO: add slippage protection for matcher - done
 //TODO: swapper can choose oracle initial liquidity - done
 //TODO: initial report latency bail-out option - done
 //TODO: oracleFeeReceiver contract + optional protocol fees split 50/50 by seller and buyer.
 //TODO: change bounty payer to swapper - done
 //TODO: make sure initial reporter & min wei semantics in oracle contract are reflected in this contract. initial reporter reward = msg.value - settlerReward.
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
    mapping(address => mapping(address => uint256)) public tempHolding;

    struct Swap {
        uint256 sellAmt;
        uint256 minOut;
        uint256 minFulfillLiquidity;
        uint256 expiration;
        uint256 fulfillmentFee;
        uint256 requiredBounty;
        uint256 reportId;
        uint48 start;
        address sellToken;
        address buyToken;
        address swapper;
        address matcher;
        bool active;
        bool matched;
        bool finished;
        bool cancelled;
        OracleParams oracleParams;
        SlippageParams slippageParams;
    }

    struct OracleParams {
        uint256 settlerReward;
        uint256 initialLiquidity;
        uint256 escalationHalt;
        uint48 settlementTime;
        uint48 latencyBailout;
        uint24 disputeDelay;
        uint24 swapFee;
        uint24 protocolFee;
    }

    struct SlippageParams {
        uint256 priceTolerated; // one of two max slippage inputs. current price at time of swap, formatted as priceTolerated = 225073570923495617630012810 => (1e30 / priceTolerated) = $4442.99 for WETH/USDC trading (sellToken WETH/ETH buyToken USDC)
                                //should match oracle game price calculation (respecting PRICE_PRECISION semantics)
        uint24 toleranceRange; // 100000 = 1% max slippage against priceTolerated
    }

    event SwapCreated(uint256 indexed swapId, uint256 sellAmt, address sellToken, uint256 minOut, address buyToken, uint256 minFulfillLiquidity, uint256 expiration, uint256 fulfillmentFee, uint256 priceTolerated, uint256 toleranceRange, uint256 blockTimestamp);
    event SwapCancelled(uint256 swapId);

    function swap(uint256 sellAmt, address sellToken, uint256 minOut, address buyToken, uint256 minFulfillLiquidity, uint256 expiration, uint256 fulfillmentFee, uint256 bountyAmount, OracleParams memory oracleParams, SlippageParams memory slippageParams) external payable nonReentrant returns(uint256 swapId) {
        uint256 settlerReward = oracleParams.settlerReward;
        uint256 extraEth = bountyAmount + settlerReward + 1;
        if (sellToken != address(0) && msg.value != extraEth) revert InvalidInput("selling eth but no msg.value");
        if (sellToken == address(0) && msg.value != sellAmt + extraEth) revert InvalidInput("msg.value vs sellAmt mismatch");

        if (sellToken == buyToken) revert InvalidInput("sellToken = buyToken");
        if (sellToken == WETH && buyToken == address(0) || sellToken == address(0) && buyToken == WETH) revert InvalidInput("sellToken = buyToken");

        if (sellAmt == 0 || minOut == 0 || minFulfillLiquidity == 0) revert InvalidInput("zero amounts");
        if (fulfillmentFee >= 1e7) revert InvalidInput("fulfillmentFee");

        if (oracleParams.settlerReward < 100
            || oracleParams.swapFee == 0 
            || oracleParams.settlementTime == 0 
            || oracleParams.initialLiquidity == 0
            || oracleParams.disputeDelay >= oracleParams.settlementTime
            || oracleParams.escalationHalt < oracleParams.initialLiquidity
            || oracleParams.settlementTime > 4 * 60 * 60
            || oracleParams.swapFee + oracleParams.protocolFee >= 1e7
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
        s.requiredBounty = bountyAmount;
        s.oracleParams = oracleParams;
        s.slippageParams = slippageParams;

        if (sellToken != address(0)) {
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmt);
        }

        emit SwapCreated(swapId, sellAmt, sellToken, minOut, buyToken, minFulfillLiquidity, expiration, fulfillmentFee, slippageParams.priceTolerated, slippageParams.toleranceRange, block.timestamp);
    }

    function matchSwap(uint256 swapId) external payable nonReentrant {
        Swap storage s = swaps[swapId];

        if (s.buyToken != address(0) && msg.value != 0) revert InvalidInput("selling eth but no msg.value");
        if (s.buyToken == address(0) && msg.value != s.minFulfillLiquidity) revert InvalidInput("msg.value");

        if (s.cancelled) revert InvalidInput("swap cancelled");
        if (s.matched) revert InvalidInput("swap matched");
        if (!s.active) revert InvalidInput("swap not active");
        if (s.finished) revert InvalidInput("finished");
        if (block.timestamp > s.expiration) revert InvalidInput("expired");

        s.matched = true;
        s.matcher = msg.sender;
        s.start = uint48(block.timestamp);

        if(s.buyToken != address(0)) {
            IERC20(s.buyToken).safeTransferFrom(msg.sender, address(this), s.minFulfillLiquidity);
        }

        bounty.createOracleBountyFwd{value: s.requiredBounty}(
            oracle.nextReportId(),
            s.requiredBounty / 20,
            s.swapper,
            address(this),
            12247,
            20,
            true,
            0
        );

        uint256 reportId = oracleGame(s);
        s.reportId = reportId;
        reportIdToSwapId[reportId] = swapId;

    }

    function cancelSwap(uint256 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];
        OracleParams memory o = s.oracleParams;

        if (msg.sender != s.swapper) revert InvalidInput("not swapper");
        if (s.matched) revert InvalidInput("already matched");
        if (!s.active) revert InvalidInput("not active");
        if (s.cancelled) revert InvalidInput("cancelled");
        if (s.finished) revert InvalidInput("finished");

        s.cancelled = true;

        if (s.sellToken != address(0)) {
            IERC20(s.sellToken).safeTransfer(msg.sender, s.sellAmt);
            payEth(s.swapper, s.requiredBounty + o.settlerReward + 1);
        } else {
            payEth(s.swapper, s.sellAmt + s.requiredBounty + o.settlerReward + 1);
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
            exactToken1Report: o.initialLiquidity,
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
    function onSettle(uint256 id, uint256 price, uint256, address, address)
        external
        payable
        nonReentrant
    {
        if (msg.sender != address(oracle)) revert InvalidInput("invalid sender");
        uint256 swapId = reportIdToSwapId[id];
        Swap storage s = swaps[swapId];
        if (id != s.reportId) revert InvalidInput("wrong reportId");
        if (s.finished) revert InvalidInput("finished");
        s.finished = true;

        IOpenOracle.ReportStatus memory rs = oracle.reportStatus(id);
        uint256 oracleAmount1 = rs.currentAmount1;
        uint256 oracleAmount2 = rs.currentAmount2;
        uint256 fulfillAmt = (s.sellAmt * oracleAmount2) / oracleAmount1;
        fulfillAmt -= fulfillAmt * s.fulfillmentFee / 1e7;
        bool slippageOk = toleranceCheck(price, s.slippageParams.priceTolerated, s.slippageParams.toleranceRange);

        // maybe we dont need minOut anymore?
        if (fulfillAmt > s.minFulfillLiquidity || fulfillAmt < s.minOut || !slippageOk) {
            refund(s.sellToken, s.sellAmt, s.swapper, s.buyToken, s.minFulfillLiquidity, s.matcher);
        } else {
            //complete swap
            if (s.buyToken != address(0)){
                _transferTokens(s.buyToken, address(this), s.swapper, fulfillAmt);
                _transferTokens(s.buyToken, address(this), s.matcher, s.minFulfillLiquidity - fulfillAmt);
                if (s.sellToken != address(0)) {
                    _transferTokens(s.sellToken, address(this), s.matcher, s.sellAmt);
                } else {
                    payEth(s.matcher, s.sellAmt);
                }
            } else {
                payEth(s.swapper, fulfillAmt);
                payEth(s.matcher, s.minFulfillLiquidity - fulfillAmt);
                _transferTokens(s.sellToken, address(this), s.matcher, s.sellAmt);
            }
        }

        // maxRounds > 0 checks if bounty exists for this reportId
        IBounty.Bounties memory b = bounty.Bounty(id);
        if (b.maxRounds > 0 && !b.recalled) {
            try bounty.recallBounty(id) {} catch {}
        }

    }

    function bailOut(uint256 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];
        IOpenOracle.ReportStatus memory rs = oracle.reportStatus(s.reportId);

        if (s.finished) revert InvalidInput("finished");
        if (!s.active) revert InvalidInput("not active");
        if (!s.matched) revert InvalidInput("not matched");
        if (s.cancelled) revert InvalidInput("cancelled");
        if (s.reportId == 0) revert InvalidInput("doesnt exist");

        bool isLatent;
        uint256 latency = s.oracleParams.latencyBailout;

        isLatent = block.timestamp > s.start + latency;
        isLatent = isLatent && (rs.reportTimestamp == 0);

        if (rs.isDistributed && !s.finished || isLatent){
            s.finished = true;

            IBounty.Bounties memory b = bounty.Bounty(s.reportId);
            if (b.maxRounds > 0 && !b.recalled) {
                try bounty.recallBounty(s.reportId) {} catch {}
            }

            refund(s.sellToken, s.sellAmt, s.swapper, s.buyToken, s.minFulfillLiquidity, s.matcher);
        }
    }

    function payEth(address _to, uint256 _amount) internal {
        (bool ok,) = payable(_to).call{value: _amount, gas: 40000}("");
        if (!ok) {
            IWETH(WETH).deposit{value: _amount}();
            IERC20(WETH).safeTransfer(_to, _amount);
        }
    }

    /**
     * @dev Internal function to handle token transfers.                
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization: skip zero transfers

        if (from == address(this)) {

            (bool success, bytes memory returndata) = token.call(
                    abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
                );

            if (success && ((returndata.length > 0 && abi.decode(returndata, (bool))) || 
                (returndata.length == 0 && address(token).code.length > 0))) {
               return;
            }

            tempHolding[to][token] += amount;

        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    function refund(address sellToken, uint256 sellAmt, address swapper, address buyToken, uint256 buyAmt, address matcher) internal {
        if (sellToken != address(0)){
            _transferTokens(sellToken, address(this), swapper, sellAmt);
            if (buyToken != address(0)){
                _transferTokens(buyToken, address(this), matcher, buyAmt);
            } else {
                payEth(matcher, buyAmt);
            }
        } else {
            payEth(swapper, sellAmt);
            _transferTokens(buyToken, address(this), matcher, buyAmt);
        }
    }

    /**
     * @notice Withdraws temp holdings for a specific token
     * @param tokenToGet The token address to withdraw tokens for
     */
    function getTempHolding(address tokenToGet, address _to) external nonReentrant {
        uint256 amount = tempHolding[_to][tokenToGet];
        if (amount > 0) {
            tempHolding[_to][tokenToGet] = 0;
            _transferTokens(tokenToGet, address(this), _to, amount);
        }
    }
    
    // can maybe make this log-symmetric but just keep it simple for now
    // balances incentives in the swapping game so the swapper puts the current price in priceTolerated if they want a matcher to come.
    function toleranceCheck(uint256 price, uint256 priceTolerated, uint24 toleranceRange)
        internal
        pure
        returns (bool)
    {
        if (priceTolerated == 0 || toleranceRange == 0) return true;
        uint256 maxDiff = (priceTolerated * toleranceRange) / 1e7;
        
        if (priceTolerated > price) {
            return (priceTolerated - price) <= maxDiff;
        } else {
            return (price - priceTolerated) <= maxDiff;
        }
    }

}
