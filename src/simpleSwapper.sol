// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IBounty {
    function createOracleBountyFwd(uint256, uint256, address, address, uint16, uint16, bool, uint256) external payable;
    function recallBounty(uint256) external;
    function editBounty(uint256, uint256) external;

    struct Bounties {
        uint256 totalAmtDeposited;
        uint256 bountyStartAmt;
        uint256 bountyClaimed;
        uint256 start;
        uint256 forwardStartTime;
        address payable creator;
        address editor;
        uint16 bountyMultiplier;
        uint16 maxRounds;
        bool claimed;
        bool recalled;
        bool timeType;
    }

    function Bounty(uint256 id) external view returns (Bounties memory);

}
/* ------------ simpleSwapper ------------ */
// Uses openOracle: https://openprices.gitbook.io/openoracle-docs/openoracle
contract simpleSwapper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IBounty public immutable bounty;
    IOpenOracle public immutable oracle;
    address public immutable WETH = 0x4200000000000000000000000000000000000006;

    error InvalidInput(string);
    error EthTransferFailed();

    constructor(address oracle_, address bounty_) {
        require(oracle_ != address(0), "oracle addr 0");
        require(bounty_ != address(0), "bounty addr 0");

        oracle = IOpenOracle(oracle_);
        bounty = IBounty(bounty_);
    }

    mapping(address => mapping(address => uint256)) public userBalances; // user → token → balance

    struct SwapParams {
        address token1; // recommended Base WETH
        address token2; // recommended Base native USDC
        bool desiredToken; // true => sell token2 for token1, false => sell token1 for token2
        uint256 sellAmt; // amount in the token you are selling
        uint256 initialLiquidity; // initial oracle liquidity
        uint256 escalationHalt; // oracle escalation halt
        uint48 settlementTime; // oracle settlement time, if timeType = true, in seconds. if false, in blocks
        uint24 disputeDelay; // oracle dispute delay, if timeType = true, in seconds. if false, in blocks
        uint32 callbackGasLimit; // gas required for the onSettle function. recommended to set this to 275k
        uint24 feePercentage; // oracle swap fee. 2000 = 0.02%
        uint16 multiplier; // oracle escalation multiplier. 120 = 1.2x
        bool timeType; // oracle time mode, true for seconds, false for blocks
        uint24 fulfillmentFee; // fee paid to liquidity provider in this contract, discounted from the oracle price. 2000 = 0.02%
        uint256 gasComp; // gas compensation paid to liquidity provider. amount in token you are buying
        uint48 fulfillmentTime; // amount of time liquidity provider has to fulfill your swap after oracle price is settled
        uint256 settlerReward; // reward paid to oracle settler. reward paid to initial reporter is msg.value - settlerReward
        uint256 priceTolerated; // one of two max slippage inputs. current price at time of swap, formatted as priceTolerated = 225073570923495617630012810 => (1e30 / priceTolerated) = $4442.99 for WETH/USDC trading
        uint24 toleranceRange; // 100000 = 1% max slippage against priceTolerated
        uint8 retries; //number of retries if not fulfilled in optimal block
        uint256 retryBonus; //bonus paid to fulfiller in ETH for retry
        bool retryWait; //true => retrier must wait until fulfillmentTime is up. false => retry can fire in fulfillment block
    }

    struct BountyParams {
        uint256 totalAmtDeposited; // wei sent to bounty contract
        uint256 bountyStartAmt; // starting bounty amount in wei
        uint256 forward; // time past swap creation block the bounty starts escalating
        uint16 bountyMultiplier; // per-block or per-second exponential increase in bounty from start amount where 15000 = 1.5x
        uint16 maxRounds; // time window of seconds or blocks over which you allow the bounty to exponentially increase
    }

    struct Swap {
        uint256 sellAmt;
        uint256 price;
        uint256 gasComp;
        uint256 priceTolerated;
        uint256 retryBalance;
        uint256 retryBonus;
        address token1;
        uint48 settlementTime;
        uint48 activeTime;
        address token2;
        uint48 fulfillmentTime;
        uint24 fulfillmentFee;
        uint24 toleranceRange;
        address user;
        uint8 precision;
        uint8 retries;
        bool desiredToken;
        bool fulfilled;
        bool active;
        bool cancelled;
        bool timeType;
        bool retryWait;
    }

    mapping(uint256 => Swap) public swaps; // reportId → data

    event SwapCreated(uint256 reportId, uint256 sellAmt, address token1, address token2, bool desiredToken);
    event SwapActive(
        uint256 reportId,
        uint256 sellAmt,
        address token1,
        address token2,
        bool desiredToken,
        uint256 price,
        uint24 oracleFee,
        uint24 fulfillmentFee,
        address user,
        uint256 gasComp,
        uint256 retryBonus,
        uint48 fulfillmentTime,
        bool timeType,
        bool retryWait,
        uint256 blockTimestamp
    );

    event SwapCancelled(uint256 reportId);
    event SwapFulfilled(uint256 reportId, uint256 refund);
    event SwapRetried(uint256 previousReportId, uint256 newReportId);

    event blockPaceFlush(uint256 reportId);
    event settleTimingFlush(uint256 reportId);
    event maxSlippageFlush(uint256 reportId);

    function swap(SwapParams calldata params, BountyParams calldata bountyParams) external payable nonReentrant returns (uint256) {
        return _swap(params, bountyParams);
    }

    function safeSwap(
        SwapParams calldata params,
        BountyParams calldata bountyParams,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external payable nonReentrant returns (uint256) {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) {
            revert InvalidInput("timestamp");
        }
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) {
            revert InvalidInput("block number");
        }
        return _swap(params, bountyParams);
    }

    function _swap(SwapParams calldata params, BountyParams calldata bountyParams) internal returns (uint256) {
        if (params.settlementTime == 0) revert InvalidInput("settlementTime cannot be 0");
        if (params.feePercentage == 0) revert InvalidInput("swap fee cannot be 0");
        if (params.fulfillmentFee >= 1e7) revert InvalidInput("fulfillment fee too high");
        if (params.fulfillmentTime > 10000) revert InvalidInput("fulfillmentTime too high");
        if (params.settlementTime > 10000) revert InvalidInput("settlementTime too high");

        if (params.settlerReward == 0 || params.settlerReward > msg.value - 1) revert InvalidInput("settlerReward");

        if ((params.token1 == WETH && params.desiredToken == false) && msg.value < params.sellAmt + bountyParams.totalAmtDeposited) {
            revert InvalidInput("msg.value too small");
        }

        if (msg.value < bountyParams.totalAmtDeposited) revert InvalidInput("msg.value too small");

        if (params.token1 == WETH && params.desiredToken == false) {
            userBalances[msg.sender][params.token1] += params.sellAmt;
        } else {
            if (!params.desiredToken) {
                IERC20(params.token1).safeTransferFrom(msg.sender, address(this), params.sellAmt);
                userBalances[msg.sender][params.token1] += params.sellAmt;
            } else {
                IERC20(params.token2).safeTransferFrom(msg.sender, address(this), params.sellAmt);
                userBalances[msg.sender][params.token2] += params.sellAmt;
            }
        }

        IOpenOracle.CreateReportParams memory params2 = IOpenOracle.CreateReportParams({
            exactToken1Report: params.initialLiquidity,
            escalationHalt: params.escalationHalt,
            settlerReward: params.settlerReward,
            token1Address: params.token1,
            settlementTime: params.settlementTime,
            disputeDelay: params.disputeDelay,
            protocolFee: 0,
            token2Address: params.token2,
            callbackGasLimit: params.callbackGasLimit,
            feePercentage: params.feePercentage,
            multiplier: params.multiplier,
            timeType: params.timeType,
            trackDisputes: false,
            keepFee: true,
            callbackContract: address(this),
            callbackSelector: this.onSettle.selector,
            protocolFeeRecipient: address(0)
        });

        uint256 valueLeft;
        if (params.token1 == WETH && params.desiredToken == false) {
            valueLeft = msg.value - params.sellAmt - bountyParams.totalAmtDeposited;
            IWETH(WETH).deposit{value: params.sellAmt}();
        } else {
            valueLeft = msg.value - bountyParams.totalAmtDeposited;
        }

        uint256 _value;
        if (params.retries > 0) {
            uint256 R = params.retries;
            uint256 base = valueLeft - (R * params.retryBonus);
            _value = base / (R + 1);
        } else {
            _value = valueLeft;
        }

        /* ------------ create bounty ------------ */
        if (bountyParams.totalAmtDeposited > 0) {
            bounty.createOracleBountyFwd{value: bountyParams.totalAmtDeposited}(
                oracle.nextReportId(),
                bountyParams.bountyStartAmt,
                msg.sender,
                address(this),
                bountyParams.bountyMultiplier,
                bountyParams.maxRounds,
                params.timeType,
                bountyParams.forward
            );
        }

        /* ------------ create report instance ------------ */
        uint256 reportId = oracle.createReportInstance{value: _value}(params2);

        uint8 decimalsA = IERC20Metadata(params.token1).decimals();
        uint8 decimalsB = IERC20Metadata(params.token2).decimals();
        uint8 precision;

        if (decimalsA >= decimalsB) {
            precision = 18 + decimalsA - decimalsB; // Just store the exponent
        } else {
            precision = 18 - (decimalsB - decimalsA); // Just store the exponent
        }

        swaps[reportId] = Swap(
            params.sellAmt,
            0,
            params.gasComp,
            params.priceTolerated,
            valueLeft - _value,
            params.retryBonus,
            params.token1,
            params.settlementTime,
            0,
            params.token2,
            params.fulfillmentTime,
            params.fulfillmentFee,
            params.toleranceRange,
            msg.sender,
            precision,
            params.retries,
            params.desiredToken,
            false,
            false,
            false,
            params.timeType,
            params.retryWait
        );

        emit SwapCreated(reportId, params.sellAmt, params.token1, params.token2, params.desiredToken);
        return reportId;
    }

    /* -------- oracle callback -------- */
    function onSettle(uint256 id, uint256 price, uint256, /* ts   (unused) */ address, address)
        external
        payable
        nonReentrant
    {
        if (msg.sender != address(oracle)) revert InvalidInput("invalid sender");
        Swap memory s = swaps[id];
        if (s.user == address(0)) revert InvalidInput("wrong reportId");

        uint48 _settlementTime = oracle.reportMeta(id).settlementTime;
        uint48 _reportTimestamp = oracle.reportStatus(id).reportTimestamp;
        uint48 _lastReportOppoTime = oracle.reportStatus(id).lastReportOppoTime;
        bool _timeType = oracle.reportMeta(id).timeType;

        uint48 _time = _timeType ? _reportTimestamp : _lastReportOppoTime;

        bool _sanity = calculateSanityBounds(_timeType, _reportTimestamp, _lastReportOppoTime);
        bool _settleTimingOk = calculateSettleTiming(_timeType, _settlementTime, _reportTimestamp);
        bool priceTolerance = toleranceCheck(price, s.priceTolerated, s.toleranceRange, s.desiredToken);

        if (s.cancelled) {
            return;
        }

        if (!_sanity) emit blockPaceFlush(id);
        if (!_settleTimingOk) emit settleTimingFlush(id);
        if (!priceTolerance) emit maxSlippageFlush(id);

        if (
            !_sanity || !_settleTimingOk || block.timestamp > _time + 75 // chain halt guard
                || !priceTolerance
        ) {
            _flush(s.desiredToken ? s.token2 : s.token1, s.user, s.sellAmt);

            if (_flushETH(s.user, s.retryBalance)) {
                swaps[id].retryBalance = 0; // <-- clear the per-swap pool on success
            }
            swaps[id].cancelled = true;

            // maxRounds > 0 checks if bounty exists for this reportId
            IBounty.Bounties memory b = bounty.Bounty(id);
            if (b.maxRounds > 0 && !b.recalled) {
                try bounty.recallBounty(id) {} catch {}
            }

            return;
        }

        uint24 _feePercentage = oracle.reportMeta(id).feePercentage;

        swaps[id].active = true;
        swaps[id].price = price;
        swaps[id].activeTime = s.timeType ? uint48(block.timestamp) : uint48(block.number);

        uint256 R = s.retries;
        uint256 nextSend = 0;
        uint256 nextBonus = 0;

        if (R > 0) {
            uint256 baseLeft = s.retryBalance - (R * s.retryBonus);
            nextSend = (baseLeft / R) + (baseLeft % R);

            if (s.retryBalance >= nextSend + s.retryBonus) {
                nextBonus = s.retryBonus;
            } else if (s.retryBalance >= nextSend) {
                nextBonus = s.retryBalance - nextSend;
            }
        }

        emit SwapActive(
            id,
            s.sellAmt,
            s.token1,
            s.token2,
            s.desiredToken,
            price,
            _feePercentage,
            s.fulfillmentFee,
            s.user,
            s.gasComp,
            nextBonus,
            s.fulfillmentTime,
            s.timeType,
            s.retryWait,
            block.timestamp
        );
    }

    function _flush(address token, address to, uint256 amt) internal {
        if (amt == 0) return;
        userBalances[to][token] -= amt;
        if (token != WETH) {
            IERC20(token).safeTransfer(to, amt);
        } else {
            IWETH(WETH).withdraw(amt);
            (bool ok,) = payable(to).call{value: amt, gas: 40000}("");
            if (!ok) {
                IWETH(WETH).deposit{value: amt}();
                IERC20(WETH).safeTransfer(to, amt);
            }
        }
    }

    function _flushETH(address to, uint256 amt) internal returns (bool ok) {
        if (amt == 0) return true;
        (ok,) = payable(to).call{value: amt, gas: 40000}("");
    }

    // priceTolerated should be current price. Slippage is a function of this and toleranceRange (set at swap creation)
    // makes long retry chains easier to manage
    function changeSlippage(uint256 reportId, uint256 priceTolerated) external nonReentrant {
        Swap memory s = swaps[reportId];
        if (s.user != msg.sender) revert InvalidInput("not your swap");
        if (s.active) revert InvalidInput("swap active");
        if (s.fulfilled) revert InvalidInput("already fulfilled");
        if (s.cancelled) revert InvalidInput("already cancelled");

        swaps[reportId].priceTolerated = priceTolerated;
    }

    function cancel(uint256 reportId) external nonReentrant {
        Swap memory s = swaps[reportId];
        if (s.user != msg.sender) revert InvalidInput("not your swap");
        if (s.fulfilled) revert InvalidInput("already fulfilled");
        if (s.cancelled) revert InvalidInput("already cancelled");

        uint256 _currentTime = s.timeType ? block.timestamp : block.number;

        if (s.active) {
            if (_currentTime <= s.fulfillmentTime + s.activeTime) {
                revert InvalidInput("active swap cancelled too early");
            }
        }

        swaps[reportId].cancelled = true;

        _flush(s.desiredToken ? s.token2 : s.token1, s.user, s.sellAmt);

        if (_flushETH(s.user, s.retryBalance)) {
            swaps[reportId].retryBalance = 0;
        }

        // maxRounds > 0 checks if bounty exists for this reportId
        IBounty.Bounties memory b = bounty.Bounty(reportId);
        if (b.maxRounds > 0 && !b.recalled) {
            try bounty.recallBounty(reportId) {} catch {}
        }

        emit SwapCancelled(reportId);
    }

    function fulfill(uint256 reportId) external nonReentrant {
        _fulfill(reportId);
    }

    function safeFulfill(
        uint256 reportId,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) {
            revert InvalidInput("timestamp");
        }
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) {
            revert InvalidInput("block number");
        }
        _fulfill(reportId);
    }

    function _fulfill(uint256 reportId) internal {
        Swap memory s = swaps[reportId];
        if (s.fulfilled) revert InvalidInput("already fulfilled");
        if (s.cancelled) revert InvalidInput("already cancelled");
        if (!s.active) revert InvalidInput("not active");

        uint256 _currentTime = s.timeType ? block.timestamp : block.number;

        if (_currentTime > s.fulfillmentTime + s.activeTime) {
            retryInternal(reportId, s);
            return;
        }

        swaps[reportId].fulfilled = true;
        swaps[reportId].active = false;

        uint256 price = s.price;
        price = (1e18 * (10 ** s.precision)) / price;
        uint256 PRICE_PRECISION = 10 ** s.precision;

        uint256 fulfillmentAmt;
        if (s.desiredToken) {
            fulfillmentAmt = (s.sellAmt * PRICE_PRECISION) / price;
        } else {
            fulfillmentAmt = (s.sellAmt * price) / PRICE_PRECISION;
        }

        fulfillmentAmt = fulfillmentAmt * (1e7 - s.fulfillmentFee) / 1e7;
        fulfillmentAmt -= s.gasComp;

        if (s.desiredToken && s.token1 == WETH) {
            IERC20(s.token1).safeTransferFrom(msg.sender, address(this), fulfillmentAmt);
            IWETH(WETH).withdraw(fulfillmentAmt);
            IERC20(s.token2).safeTransfer(msg.sender, s.sellAmt);
            userBalances[s.user][s.token2] -= s.sellAmt;

            (bool ok,) = payable(s.user).call{value: fulfillmentAmt, gas: 40000}("");
            if (!ok) {
                IWETH(WETH).deposit{value: fulfillmentAmt}();
                IERC20(WETH).safeTransfer(s.user, fulfillmentAmt);
            }
        } else {
            if (s.desiredToken) {
                IERC20(s.token1).safeTransferFrom(msg.sender, address(this), fulfillmentAmt);
                IERC20(s.token2).safeTransfer(msg.sender, s.sellAmt);
                userBalances[s.user][s.token2] -= s.sellAmt;
                IERC20(s.token1).safeTransfer(s.user, fulfillmentAmt);
            } else {
                IERC20(s.token2).safeTransferFrom(msg.sender, address(this), fulfillmentAmt);
                IERC20(s.token1).safeTransfer(msg.sender, s.sellAmt);
                userBalances[s.user][s.token1] -= s.sellAmt;
                IERC20(s.token2).safeTransfer(s.user, fulfillmentAmt);
            }
        }

        uint256 pool = swaps[reportId].retryBalance;

        emit SwapFulfilled(reportId, pool);

        if (pool > 0 && _flushETH(s.user, pool)) {
            swaps[reportId].retryBalance = 0;
        }

        // maxRounds > 0 checks if bounty exists for this reportId
        IBounty.Bounties memory b = bounty.Bounty(reportId);
        if (b.maxRounds > 0 && !b.recalled) {
            try bounty.recallBounty(reportId) {} catch {}
        }

    }

    //only works if retryWait == false in swap initialization
    function retry(uint256 reportId) external nonReentrant {
        _retry(reportId);
    }

    function safeRetry(
        uint256 reportId,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) {
            revert InvalidInput("timestamp");
        }
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) {
            revert InvalidInput("block number");
        }
        _retry(reportId);
    }

    function _retry(uint256 reportId) internal {
        Swap memory s = swaps[reportId];
        if (s.fulfilled) revert InvalidInput("already fulfilled");
        if (s.cancelled) revert InvalidInput("already cancelled");
        if (!s.active) revert InvalidInput("not active");
        if (s.retryWait) revert InvalidInput("retryWait true");

        retryInternal(reportId, s);
    }

    function retryInternal(uint256 reportId, Swap memory s) internal {

        IOpenOracle.CreateReportParams memory params2 = IOpenOracle.CreateReportParams({
            exactToken1Report: oracle.reportMeta(reportId).exactToken1Report,
            escalationHalt: oracle.reportMeta(reportId).escalationHalt,
            settlerReward: oracle.reportMeta(reportId).settlerReward,
            token1Address: s.token1,
            settlementTime: s.settlementTime,
            disputeDelay: oracle.reportMeta(reportId).disputeDelay,
            protocolFee: 0,
            token2Address: s.token2,
            callbackGasLimit: oracle.extraData(reportId).callbackGasLimit,
            feePercentage: oracle.reportMeta(reportId).feePercentage,
            multiplier: oracle.reportMeta(reportId).multiplier,
            timeType: oracle.reportMeta(reportId).timeType,
            trackDisputes: false,
            keepFee: true,
            callbackContract: address(this),
            callbackSelector: this.onSettle.selector,
            protocolFeeRecipient: address(0)
        });

        uint256 R = s.retries;
        uint256 baseLeft = s.retryBalance - (R * s.retryBonus);
        uint256 perSend = baseLeft / R; //revert here if 0 retries
        uint256 remNow = baseLeft % R;
        uint256 _value = perSend + remNow;

        // maxRounds > 0 checks if bounty exists for this reportId
        IBounty.Bounties memory b = bounty.Bounty(reportId);
        if (b.maxRounds > 0 && !b.recalled) {
            try bounty.editBounty(reportId, oracle.nextReportId()) {} catch {}
        }

        /* ------------ create report instance ------------ */
        uint256 reportId2 = oracle.createReportInstance{value: _value}(params2);

        uint256 bonus = 0;
        {
            uint256 avail = s.retryBalance - _value;
            if (s.retryBonus > 0 && avail > 0) {
                bonus = s.retryBonus <= avail ? s.retryBonus : avail;
                (bool ok,) = payable(msg.sender).call{value: bonus, gas: 40000}("");
                if (!ok) {
                    bonus = 0;
                }
            }
        }

        swaps[reportId2] = Swap({
            sellAmt: s.sellAmt,
            price: 0,
            gasComp: s.gasComp,
            priceTolerated: s.priceTolerated,
            retryBalance: s.retryBalance - _value - bonus,
            retryBonus: s.retryBonus,
            token1: s.token1,
            settlementTime: s.settlementTime,
            activeTime: 0,
            token2: s.token2,
            fulfillmentTime: s.fulfillmentTime,
            fulfillmentFee: s.fulfillmentFee,
            toleranceRange: s.toleranceRange,
            user: s.user,
            precision: s.precision,
            retries: 0, // set later for stack management
            desiredToken: s.desiredToken,
            fulfilled: false,
            active: false,
            cancelled: false,
            timeType: s.timeType,
            retryWait: s.retryWait
        });

        //stack management
        swaps[reportId2].retries = s.retries > 0 ? s.retries - 1 : 0;

        swaps[reportId].retryBalance = 0;
        swaps[reportId].cancelled = true;

        emit SwapRetried(reportId, reportId2);
        emit SwapCreated(reportId2, s.sellAmt, s.token1, s.token2, s.desiredToken);
    }

    function calculateSettleTiming(bool timeType, uint48 _settlementTime, uint48 _reportTimestamp)
        internal
        view
        returns (bool)
    {
        uint48 optimalTime = _reportTimestamp + _settlementTime;
        return (timeType ? block.timestamp == optimalTime : block.number == optimalTime);
    }

    function calculateSanityBounds(bool timeType, uint48 _time, uint48 _timeOppo) internal view returns (bool) {
        uint48 _timeChangeTrue;
        uint48 _timeChangeBlock;
        uint48 expectedBlocks;
        uint48 _blocksPerSecond = 500; // 500 = 0.5 blocks per second

        if (timeType) {
            _timeChangeTrue = uint48(block.timestamp) - _time;
            _timeChangeBlock = uint48(block.number) - _timeOppo;
        } else {
            _timeChangeTrue = uint48(block.timestamp) - _timeOppo;
            _timeChangeBlock = uint48(block.number) - _time;
        }

        expectedBlocks = _timeChangeTrue * _blocksPerSecond;

        if (
            1000 * _timeChangeBlock > expectedBlocks + 2 * _blocksPerSecond
                || 1000 * _timeChangeBlock < expectedBlocks - 2 * _blocksPerSecond
        ) {
            return false;
        } else {
            return true;
        }
    }

    function toleranceCheck(uint256 price, uint256 priceTolerated, uint24 toleranceRange, bool desiredToken)
        internal
        pure
        returns (bool)
    {
        if (priceTolerated == 0 || toleranceRange == 0) return true;
        uint256 maxDiff = (priceTolerated * toleranceRange) / 1e7;
        
        if (desiredToken) {
            if (price >= priceTolerated) return true;
            return (priceTolerated - price) <= maxDiff;
        } else {
            if (price <= priceTolerated) return true;
            return (price - priceTolerated) <= maxDiff;
        }
    }

    receive() external payable {
        if (msg.sender != WETH) revert EthTransferFailed();
    }
}
