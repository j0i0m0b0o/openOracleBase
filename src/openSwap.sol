// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IBountyERC20} from "./interfaces/IBountyERC20.sol";
import {oracleFeeReceiver} from "./oracleFeeReceiver.sol";

/**
 * @title openSwap
 * @notice Uses openOracle for swap execution price
           Different from simpleSwapper since there's no choice about whether to fulfill
           simpleSwapper flow is deposit sellToken -> oracle game ends in price -> anyone has choice to swap against that price
           openSwap flow is deposit sellToken -> someone matches with enough buyToken -> oracle game ends in price -> swap executed against price
           This swapping method may open up manipulation opportunities:
                      https://openprices.gitbook.io/openoracle-docs/contents/considerations#a-stronger-form-of-manipulation
           The bias scales with something like the square root of the settlementTime ish
           For a 1.1x multiplier and zero swap or protocol fees, the effective fee paid from oracle manipulation is ~ 0.3 st dev of settlementTime returns
           Effective fee (expected value transferred due to oracle manipulation, expressed as an equivalent spread/fee) assumes swapper is passive and lets the matcher manipulate
           Matcher needs to be aware the swapper can manipulate, so if they want to be passive, they should ensure the fulfillmentFee is > ~0.3 st dev of settlement time returns
           If both matcher and swapper commit to manipulation, they both lose uncapped money. So generally if we look at it from a 2x2 decision matrix, the equilibrium is to not manipulate
           However, that 2x2 decision matrix is committing to manipulate, not testing the waters and giving up if the other party is manipulating.
           In general, this is a very complex game and we probably need to play it in the real world to be sure about the economics.
 * @author OpenOracle Team
 * @custom:version 0.1.6
 * @custom:documentation https://openprices.gitbook.io/openoracle-docs
 */

 //TODO: fixed gasCompensation paid to matcher by swapper? separates linear costs from fixed
 //TODO: make the fulfillment fee a capped increasing bounty
 //TODO: add overload swap() with gasCompensation capped at 0.05 eth, other overload can be free to choose
 //TODO: optional max slippage ignored by matcher (but applies to swapper) for blind firing? maybe too complex
 //THIS CONTRACT IS JUST A SKETCH SO FAR
 
contract openSwap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IBountyERC20 public immutable bounty;
    IOpenOracle public immutable oracle;
    address public immutable WETH = 0x4200000000000000000000000000000000000006;

    error InvalidInput(string);
    error EthTransferFailed();

    constructor(address oracle_, address bounty_) {
        oracle = IOpenOracle(oracle_);
        bounty = IBountyERC20(bounty_);
    }

    mapping (uint256 => Swap) public swaps;
    uint256 public nextSwapId = 1;

    mapping (uint256 => uint256) public reportIdToSwapId;
    mapping (address => mapping(address => uint256)) public tempHolding;

    struct Swap {
        uint256 sellAmt; // amount of sellToken the swapper is selling
        uint256 minOut; // minimum tokens to swapper of buyToken when finished aside from full refunds
        uint256 minFulfillLiquidity; // minimum amount of buyToken the matcher must put in the contract
        uint256 expiration; // timestamp at which swapper's swap can no longer be matched
        uint256 requiredBounty; // max reward in wei for oracle game initial reporter. bounty increases over time up to this number
        uint256 reportId; // oracle game reportId
        uint256 gasCompensation; // swapper pays matcher this amount of wei to call match
        uint48 start; // timestamp at which order is matched
        uint24 fulfillmentFee; // 1000 = 0.01%, fee paid to matcher
        address sellToken; // address for token swapper is selling
        address buyToken; // address for token swapper wants
        address swapper; // msg.sender of swapper
        address matcher; // msg.sender of matcher
        address feeRecipient; // contract holding protocol fees from oracle game
        bool active; // true means swap created
        bool matched; // true means swap matched by matcher
        bool finished; // true means swap finished
        bool cancelled; // true means swap cancelled by swapper
        OracleParams oracleParams;
        SlippageParams slippageParams;
        FulfillFeeParams fulfillFeeParams;
    }

    struct OracleParams {
        uint256 settlerReward; // settler reward in oracle game. settle function executes the swap.
        uint256 initialLiquidity; // oracle game initial liquidity in sellToken
        uint256 escalationHalt; // amount of sellToken at which oracle game stops escalating
        uint48 settlementTime; // round length in seconds of oracle game
        uint48 latencyBailout; // the swap can be can cancelled and refunded after this number of seconds pass with a matched swap but no oracle game initial report 
        uint48 maxGameTime; // if oracle game takes longer than this time in seconds, refund available
        uint24 disputeDelay; // disputes must wait this long in seconds after the last report to fire in the oracle game
        uint24 swapFee; // 1000 = 0.01%, swap fee amount paid to prior reporter in oracle game
        uint24 protocolFee; // 1000 = 0.01%, percentage levied of each swap in oracle game for protocolFeeRecipient's benefit.
    }

    struct SlippageParams {
        uint256 priceTolerated; // one of two max slippage inputs. current price at time of swap, formatted as priceTolerated = 225073570923495617630012810 => (1e30 / priceTolerated) = $4442.99 for WETH/USDC trading (sellToken WETH/ETH buyToken USDC)
                                //should match oracle game price calculation (respecting PRICE_PRECISION semantics)
        uint24 toleranceRange; // 100000 = 1%, max slippage against priceTolerated
    }

    struct FulfillFeeParams {
        uint48 startFulfillFeeIncrease; // timestamp at which order is created
        uint24 maxFee; // 1000 = 0.01%, max fulfillment fee you can pay
        uint24 startingFee; // 1000 = 0.01%, starting fee level
        uint24 roundLength; // round length in seconds
        uint16 growthRate; // 15000 = 1.5x per round
        uint16 maxRounds; // max rounds of increase
    }

    event SwapCreated(uint256 indexed swapId, uint256 sellAmt, address sellToken, uint256 minOut, address buyToken, uint256 minFulfillLiquidity, uint256 expiration, uint256 priceTolerated, uint256 toleranceRange, FulfillFeeParams fulfillFeeParams, uint256 blockTimestamp);
    event SwapCancelled(uint256 swapId);
    event SingleFee(uint256 swapId, uint256 fulfillmentFee);
    event SwapRefunded(uint256 swapId, address swapper, address matcher);
    event SwapExecuted(address indexed swapper, address indexed matcher, uint256 swapId, uint256 sellTokenAmt, uint256 buyTokenAmt);
    event SwapMatched(uint256 swapId, uint256 fulfillmentFee, address matcher);
    event FeesTransferred(address buyToken, address sellToken, address feeRecipientContract);

    /**
     * @notice Creates a swap, sending sellAmt of sellToken into the contract.
     * @param sellAmt Amount of sellToken to sell
     * @param sellToken Token address to sell
     * @param minOut Minimum amount of buyToken to receive
     * @param buyToken Token address to buy
     * @param minFulfillLiquidity Matcher must supply this amount of buyToken. Should include a buffer above market price to prevent refunds.
     * @param expiration Timestamp when swap can no longer be matched.
     * @param bountyAmount Max amount paid to initial reporter. Minimum paid is bountyAmount / 10 and increases over time up to bountyAmount.
     * @param oracleParams Oracle game parameters: see OracleParams for comments
     * @param slippageParams Slippage parameters: see SlippageParams for comments
     * @param fulfillFeeParams Fulfillment fee parameters: see FulfillFeeParams for comments
     * @return swapId The final settled price
     */
    function swap(uint256 sellAmt, address sellToken, uint256 minOut, address buyToken, uint256 minFulfillLiquidity, uint256 expiration, uint256 bountyAmount, uint256 gasCompensation, OracleParams memory oracleParams, SlippageParams memory slippageParams, FulfillFeeParams memory fulfillFeeParams) external payable nonReentrant returns(uint256 swapId) {
        uint256 settlerReward = oracleParams.settlerReward;
        uint256 extraEth = gasCompensation + bountyAmount + settlerReward + 1;
        if (sellToken != address(0) && msg.value != extraEth) revert InvalidInput("selling eth but no msg.value");
        if (sellToken == address(0) && msg.value != sellAmt + extraEth) revert InvalidInput("msg.value vs sellAmt mismatch");

        if (sellToken == buyToken) revert InvalidInput("sellToken = buyToken");
        if (sellToken == WETH && buyToken == address(0) || sellToken == address(0) && buyToken == WETH) revert InvalidInput("sellToken = buyToken");

        if (sellAmt == 0 || minOut == 0 || minFulfillLiquidity == 0) revert InvalidInput("zero amounts");
        if (fulfillFeeParams.maxFee >= 1e7) revert InvalidInput("fulfillmentFee");

        if (oracleParams.settlerReward < 100
            || oracleParams.swapFee == 0 
            || oracleParams.settlementTime == 0 
            || oracleParams.initialLiquidity == 0
            || oracleParams.disputeDelay >= oracleParams.settlementTime
            || oracleParams.escalationHalt < oracleParams.initialLiquidity
            || oracleParams.settlementTime > 4 * 60 * 60
            || oracleParams.swapFee + oracleParams.protocolFee >= 1e7
            || oracleParams.maxGameTime < oracleParams.settlementTime * 20
            ) revert InvalidInput("oracleParams");

        if (fulfillFeeParams.maxFee == 0
            || fulfillFeeParams.startingFee == 0
            || fulfillFeeParams.growthRate == 0
            || fulfillFeeParams.maxRounds == 0
            || fulfillFeeParams.roundLength == 0
            || fulfillFeeParams.maxFee < fulfillFeeParams.startingFee
            || fulfillFeeParams.maxFee > 1e7
            ) revert InvalidInput("fulfillFeeParams");

        swapId = nextSwapId++;
        Swap storage s = swaps[swapId];

        s.swapper = msg.sender;
        s.sellAmt = sellAmt;
        s.sellToken = sellToken;
        s.minOut = minOut;
        s.buyToken = buyToken;
        s.minFulfillLiquidity =  minFulfillLiquidity;
        s.expiration = expiration;
        s.active = true;
        s.requiredBounty = bountyAmount;
        s.oracleParams = oracleParams;
        s.slippageParams = slippageParams;
        s.gasCompensation = gasCompensation;
        s.fulfillFeeParams = fulfillFeeParams;
        s.fulfillFeeParams.startFulfillFeeIncrease = uint48(block.timestamp);

        if (sellToken != address(0)) {
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmt);
        }

        emit SwapCreated(swapId, sellAmt, sellToken, minOut, buyToken, minFulfillLiquidity, expiration, slippageParams.priceTolerated, slippageParams.toleranceRange, s.fulfillFeeParams, block.timestamp);
        if (fulfillFeeParams.maxFee == fulfillFeeParams.startingFee && fulfillFeeParams.maxRounds == 1) {
            emit SingleFee(swapId, fulfillFeeParams.maxFee);
        }

    }

    /**
     * @notice Matcher matches swap, sending tokens into contract.
     * @param swapId Unique identifier of swapping instance
     * @param paramHashExpected Hash of Swap struct expected. Helps protect against adversarial RPCs.
                                Checks against keccak256(abi.encode(swaps[swapId]))
    */
    function matchSwap(uint256 swapId, bytes32 paramHashExpected) external payable nonReentrant {
        Swap storage s = swaps[swapId];
        FulfillFeeParams memory f = s.fulfillFeeParams;
        if (paramHashExpected != keccak256(abi.encode(s))) revert InvalidInput("params");

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
        s.fulfillmentFee = uint24(calcFee(f.maxFee, f.startingFee, f.growthRate, f.maxRounds, f.startFulfillFeeIncrease, f.roundLength));

        payEth(msg.sender, s.gasCompensation);

        if(s.buyToken != address(0)) {
            IERC20(s.buyToken).safeTransferFrom(msg.sender, address(this), s.minFulfillLiquidity);
        }

        if (s.oracleParams.protocolFee > 0) {
            address sellToken;
            address buyToken;

            s.sellToken == address(0) ? sellToken = WETH : sellToken = s.sellToken;
            s.buyToken == address(0) ? buyToken = WETH : buyToken = s.buyToken;
            oracleFeeReceiver feeReceiver = new oracleFeeReceiver(address(this), swapId, address(oracle), sellToken, buyToken);
            s.feeRecipient = address(feeReceiver);
        }

        bounty.createOracleBountyFwd{value: s.requiredBounty} (
            oracle.nextReportId(),
            s.requiredBounty / 20,
            s.swapper,
            address(this),
            12247,
            20,
            true,
            0,
            address(0),
            s.requiredBounty,
            1
        );

        uint256 reportId = oracleGame(s);
        s.reportId = reportId;
        reportIdToSwapId[reportId] = swapId;

        emit SwapMatched(swapId, s.fulfillmentFee, s.matcher);

    }

    /**
     * @notice Swapper cancels swap, receiving tokens back.
               Must be called prior to match.
     * @param swapId Unique identifier of swapping instance
    */
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
            payEth(s.swapper, s.gasCompensation + s.requiredBounty + o.settlerReward + 1);
        } else {
            payEth(s.swapper, s.sellAmt + s.gasCompensation + s.requiredBounty + o.settlerReward + 1);
        }

        emit SwapCancelled(swapId);
    }

    function oracleGame(Swap memory s) internal returns (uint256 reportId) {
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
            protocolFeeRecipient: s.feeRecipient
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
            emit SwapRefunded(swapId, s.swapper, s.matcher);
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

            emit SwapExecuted(s.swapper, s.matcher, swapId, s.sellAmt, fulfillAmt);

        }

        if (s.oracleParams.protocolFee > 0) {
            grabOracleGameFees(s);
        }

        // maxRounds > 0 checks if bounty exists for this reportId
        IBountyERC20.Bounties memory b = bounty.Bounty(id);
        if (b.maxRounds > 0 && !b.recalled) {
            try bounty.recallBounty(id) {} catch {}
        }

    }

    /**
     * @notice Lets users bail out of a swapId and both swapper and matcher receive tokens back.
               Anyone-can-call.
               Three bail out conditions:
                    1. reportId distributed but swapId not finished
                    2. latencyBailout time in seconds has passed without an oracle initial report since oracle game started
                    3. maxGameTime has passed since oracle game started 
     * @param swapId Unique identifier of swapping instance
    */
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

        bool isGameTooLong = block.timestamp - s.start > s.oracleParams.maxGameTime;

        if (rs.isDistributed && !s.finished || isLatent || isGameTooLong){
            s.finished = true;

            IBountyERC20.Bounties memory b = bounty.Bounty(s.reportId);
            if (b.maxRounds > 0 && !b.recalled) {
                try bounty.recallBounty(s.reportId) {} catch {}
            }

            refund(s.sellToken, s.sellAmt, s.swapper, s.buyToken, s.minFulfillLiquidity, s.matcher);
            emit SwapRefunded(swapId, s.swapper, s.matcher);
        }
    }

    /**
     * @notice Anyone can distribute protocol fees from a given feeRecipient contract.
               Eventual oracle game callback should always clear these tokens out anyways.
     * @param swapId Unique identification number of swapping instance
     */
    function grabOracleGameFeesAny(uint256 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];
        address feeRecipient = s.feeRecipient;
        if (s.feeRecipient == address(0)) revert InvalidInput("no fee recipient");
        if (oracleFeeReceiver(feeRecipient).gameId() != swapId) revert InvalidInput("feeRecipient not for swapId");
        if (s.oracleParams.protocolFee == 0) revert InvalidInput("0 protocol fee");
        if (!s.matched) revert InvalidInput("not matched");

        grabOracleGameFees(s);
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

    function calcFee(uint256 maxFee, uint256 startingFee, uint256 growthRate, uint256 maxRounds, uint256 startFulfillFeeIncrease, uint256 roundLength) internal view returns (uint256) {
        uint256 timeDelta = block.timestamp - startFulfillFeeIncrease;
        
        timeDelta = timeDelta / roundLength;
        if (timeDelta > maxRounds) {
            timeDelta = maxRounds;
        }

        uint256 currentFee = startingFee;

        for (uint256 i = 0; i < timeDelta; i++) {
            currentFee = (currentFee * growthRate) / 10000;
            if (currentFee >= maxFee) {
                return maxFee;
            }
        }
        
        return currentFee;
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

    function grabOracleGameFees(Swap storage s) internal {
        address feeRecipient = s.feeRecipient;
        oracleFeeReceiver feeReceiver = oracleFeeReceiver(feeRecipient);
        address sellToken;
        address buyToken;

        s.sellToken == address(0) ? sellToken = WETH : sellToken = s.sellToken; 
        s.buyToken == address(0) ? buyToken = WETH : buyToken = s.buyToken; 

        try feeReceiver.collect() {} catch{}

        uint256 sellBalanceStart = IERC20(sellToken).balanceOf(address(this));
        try feeReceiver.sweep(sellToken) {} catch{}
        uint256 sellBalanceEnd = IERC20(sellToken).balanceOf(address(this));
        uint256 feesSellToken = sellBalanceEnd > sellBalanceStart ? sellBalanceEnd - sellBalanceStart : 0;

        uint256 buyBalanceStart = IERC20(buyToken).balanceOf(address(this));
        try feeReceiver.sweep(buyToken) {} catch{}
        uint256 buyBalanceEnd = IERC20(buyToken).balanceOf(address(this));
        uint256 feesBuyToken = buyBalanceEnd > buyBalanceStart ? buyBalanceEnd - buyBalanceStart : 0;

        uint256 swapperSellFeePiece = feesSellToken / 2;
        uint256 matcherSellFeePiece = feesSellToken - swapperSellFeePiece;

        _transferTokens(sellToken, address(this), s.swapper, swapperSellFeePiece);
        _transferTokens(sellToken, address(this), s.matcher, matcherSellFeePiece);

        uint256 swapperBuyFeePiece = feesBuyToken / 2;
        uint256 matcherBuyFeePiece = feesBuyToken - swapperBuyFeePiece;

        _transferTokens(buyToken, address(this), s.swapper, swapperBuyFeePiece);
        _transferTokens(buyToken, address(this), s.matcher, matcherBuyFeePiece);

        emit FeesTransferred(buyToken, sellToken, s.feeRecipient);

    }

    /* -------- VIEW FUNCTIONS -------- */

    /**
     * @notice Returns the full Swap struct for a given swapId
     * @param swapId Unique identifier of swapping instance
     */
    function getSwap(uint256 swapId) external view returns (Swap memory) {
        return swaps[swapId];
    }

    /**
     * @notice Returns oracle parameters for a given swapId
     * @param swapId Unique identifier of swapping instance
     */
    function getOracleParams(uint256 swapId) external view returns (OracleParams memory) {
        return swaps[swapId].oracleParams;
    }

    /**
     * @notice Returns slippage parameters for a given swapId
     * @param swapId Unique identifier of swapping instance
     */
    function getSlippageParams(uint256 swapId) external view returns (SlippageParams memory) {
        return swaps[swapId].slippageParams;
    }

    /**
     * @notice Returns fulfillment fee parameters for a given swapId
     * @param swapId Unique identifier of swapping instance
     */
    function getFulfillmentFeeParams(uint256 swapId) external view returns (FulfillFeeParams memory) {
        return swaps[swapId].fulfillFeeParams;
    }

    /**
     * @notice Returns the current fulfillment fee for a given swapId based on time elapsed
     * @dev Returns 0 if swap is already matched, otherwise calculates current fee
     * @param swapId Unique identifier of swapping instance
     */
    function getCurrentFulfillmentFee(uint256 swapId) external view returns (uint256) {
        Swap storage s = swaps[swapId];

        if (s.matched) {
            return 0;
        }

        FulfillFeeParams memory f = s.fulfillFeeParams;
        return calcFee(f.maxFee, f.startingFee, f.growthRate, f.maxRounds, f.startFulfillFeeIncrease, f.roundLength);
    }

    /**
     * @notice Returns the keccak256 hash of a Swap struct for optional matcher verification
     * @dev Risky if trusting an RPC - a malicious RPC can return false data. Use your own node or construct yourself with expected parameters for protection.
     * @param swapId Unique identifier of swapping instance
     */
    function getSwapHash(uint256 swapId) external view returns (bytes32) {
        return keccak256(abi.encode(swaps[swapId]));
    }

}
