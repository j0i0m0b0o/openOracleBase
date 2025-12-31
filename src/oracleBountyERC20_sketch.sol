// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";

/* *****************************************************
 *      openOracle Initial Report Bounty Contract      *
 ***************************************************** */
contract openOracleBounty is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* immutables */
    IOpenOracle public immutable oracle;

    /* -------- EVENTS -------- */
    event BountyInitialReportSubmitted(
        uint256 indexed reportId,
        uint256 bountyPaid,
        address bountyToken
    );

    event BountyRecalled(
        uint256 indexed reportId,
        uint256 amt,
        address bountyToken
    );

    event BountyCreated(
        uint256 indexed reportId,
        uint256 totalAmtDeposited,
        uint256 bountyStartAmt,
        uint256 maxRounds,
        uint256 bountyMultiplier,
        uint256 blockTimestamp,
        bool timeType,
        uint256 startTime,
        uint256 roundLength,
        address bountyToken
    );

    event BountyRetargeted(
        uint256 indexed newReportId,
        uint256 oldReportId,
        uint256 totalAmtDeposited,
        uint256 bountyStartAmt,
        uint256 maxRounds,
        uint256 bountyMultiplier,
        uint256 blockTimestamp,
        bool timeType,
        uint256 startTime,
        uint256 roundLength,
        address bountyToken
    );

    error InvalidInput(string parameter);

    //reportId to bounty
    mapping (uint256 => Bounties) public Bounty;

    //temp holding
    mapping (address => mapping(address => uint256)) public tempHolding;

    struct Bounties {
        uint256 totalAmtDeposited;
        uint256 bountyStartAmt;
        uint256 bountyClaimed;
        uint256 start;
        uint256 forwardStartTime;
        uint256 roundLength;
        address payable creator;
        address editor;
        address bountyToken;
        uint16 bountyMultiplier;
        uint16 maxRounds;
        bool claimed;
        bool recalled;
        bool timeType;
        bool recallOnClaim;
    }

    struct oracleParams {
        uint256 exactToken1Report;
        uint256 escalationHalt;
        uint256 fee;
        uint256 settlerReward;
        address token1;
        uint48 settlementTime;
        address token2;
        bool timeType;
        uint24 feePercentage;
        uint24 protocolFee;
        uint16 multiplier;
        uint24 disputeDelay;//reportMeta end
        uint256 currentAmount1;
        uint256 currentAmount2;//reportStatus end
        uint32 callbackGasLimit;
        address protocolFeeRecipient;
        bool keepFee; //extraData end
    }

    constructor(address oracle_) {
        require(oracle_ != address(0), "oracle addr 0");
        oracle = IOpenOracle(oracle_);
    }

    // overload to let user choose a start timestamp or block number for bounty
    // see _createOracleBounty for NatSpec
    function createOracleBounty(uint256 reportId, uint256 bountyStartAmt, address creator, address editor, uint16 bountyMultiplier, uint16 maxRounds, bool timeType, uint256 start, address bountyToken, uint256 maxAmount, uint256 roundLength, bool recallOnClaim) external payable nonReentrant {
        _createOracleBounty(reportId, bountyStartAmt, creator, editor, bountyMultiplier, maxRounds, timeType, start, 0, bountyToken, maxAmount, roundLength, recallOnClaim);
    }

    // overload to automatically set start to current block number or time
    // see _createOracleBounty for NatSpec
    function createOracleBounty(uint256 reportId, uint256 bountyStartAmt, address creator, address editor, uint16 bountyMultiplier, uint16 maxRounds, bool timeType, address bountyToken, uint256 maxAmount, uint256 roundLength, bool recallOnClaim) external payable nonReentrant {
        uint256 start = timeType ? block.timestamp : block.number;
        _createOracleBounty(reportId, bountyStartAmt, creator, editor, bountyMultiplier, maxRounds, timeType, start, 0, bountyToken, maxAmount, roundLength, recallOnClaim);
    }

    // overload to automatically set start to current block number or time plus forward start time
    // see _createOracleBounty for NatSpec
    function createOracleBountyFwd(uint256 reportId, uint256 bountyStartAmt, address creator, address editor, uint16 bountyMultiplier, uint16 maxRounds, bool timeType, uint256 forwardStartTime, address bountyToken, uint256 maxAmount, uint256 roundLength, bool recallOnClaim) external payable nonReentrant {
        uint256 start = timeType ? block.timestamp : block.number;
        start += forwardStartTime;
        _createOracleBounty(reportId, bountyStartAmt, creator, editor, bountyMultiplier, maxRounds, timeType, start, forwardStartTime, bountyToken, maxAmount, roundLength, recallOnClaim);
    }

    /**
     * @notice Exponential bounty for an initial reporter in openOracle. Must be called atomically and just after createReportInstance() in the oracle
     * @param reportId The unique identifier for the openOracle report instance. Must be oracle.nextReportId() - 1
     * @param bountyStartAmt Starting bounty amount in wei
     * @param creator Address to receive any unclaimed wei back
     * @param editor Optional address that can redirect your bounty to a new reportId
     * @param bountyMultiplier Per-block or per-second exponential increase in bounty from start amount where 15000 = 1.5x
     * @param maxRounds Time window of seconds or blocks over which you allow the bounty to exponentially increase
     * @param timeType True means time is measured in seconds, false means blocks
     * @param start Time past which the bounty starts escalating
     * @param bountyToken Token address bounty is paid in. address(0) means bounty paid in ETH.
     * @param maxAmount Maximum bounty paid
     * @param roundLength Time length of per-round bounty escalation
     * @param recallOnClaim If true, bounty is recalled to creator on claim (successful initial report)
     */
    function _createOracleBounty(uint256 reportId, uint256 bountyStartAmt, address creator, address editor, uint16 bountyMultiplier, uint16 maxRounds, bool timeType, uint256 start, uint256 forwardStartTime, address bountyToken, uint256 maxAmount, uint256 roundLength, bool recallOnClaim) internal {

        if (maxRounds == 0 || bountyStartAmt == 0 || bountyMultiplier == 0 || maxAmount == 0 || roundLength == 0) revert InvalidInput("amounts cannot = 0");
        if (maxRounds > 100) revert InvalidInput("too many rounds");
        if (Bounty[reportId].maxRounds > 0) revert InvalidInput("reportId has bounty");      
        if (bountyToken == address(0) && maxAmount != msg.value) revert InvalidInput("msg.value wrong");
        if (bountyStartAmt > maxAmount) revert InvalidInput("start > max");
        if (reportId != oracle.nextReportId() - 1) revert InvalidInput("wrong reportId"); // create report instance right before creating bounty
        if (oracle.reportStatus(reportId).currentReporter != address(0)) revert InvalidInput("reportId has a report");

        if (timeType ? block.timestamp > start : block.number > start) revert InvalidInput("startHeight too low");
        if (bountyMultiplier < 10001) revert InvalidInput("bountyMultiplier too low");
        if (bountyToken != address(0) && msg.value > 0) revert InvalidInput("msg.value with wrong bountyToken");

        Bounty[reportId].totalAmtDeposited = maxAmount;
        Bounty[reportId].bountyStartAmt = bountyStartAmt;
        Bounty[reportId].creator = payable(creator);
        Bounty[reportId].editor = editor;
        Bounty[reportId].bountyToken = bountyToken;
        Bounty[reportId].bountyMultiplier = bountyMultiplier;
        Bounty[reportId].maxRounds = maxRounds;
        Bounty[reportId].timeType = timeType;
        Bounty[reportId].start = start;
        Bounty[reportId].forwardStartTime = forwardStartTime;
        Bounty[reportId].roundLength = roundLength;
        Bounty[reportId].recallOnClaim = recallOnClaim;

        if (bountyToken != address(0)) {
            IERC20(bountyToken).safeTransferFrom(msg.sender, address(this), maxAmount);
        }

        emit BountyCreated(reportId, maxAmount, bountyStartAmt, maxRounds, bountyMultiplier, block.timestamp, timeType, start, roundLength, bountyToken);
    }

    /**
     * @notice Allows bounty creator or editor to recall either the full or unclaimed portion of a bounty back to the creator.
     * @param reportId The unique identifier for the openOracle report instance for which there is a bounty
     */
    function recallBounty(uint256 reportId) external nonReentrant {
        Bounties storage bounty = Bounty[reportId];

        if (bounty.maxRounds == 0) revert InvalidInput("bounty doesnt exist");        
        if (bounty.recalled) revert InvalidInput("bounty already recalled");
        if (msg.sender != bounty.creator && msg.sender != bounty.editor) revert InvalidInput("wrong sender");

        uint256 amount;

        if (bounty.claimed) {
            amount = bounty.totalAmtDeposited - bounty.bountyClaimed;
            bounty.recalled = true;
            if (bounty.bountyToken == address(0)){
                _sendEth(bounty.creator, amount);
            } else {
                IERC20(bounty.bountyToken).safeTransfer(bounty.creator, amount);
            }
            emit BountyRecalled(reportId, amount, bounty.bountyToken);
        } else {
            bounty.recalled = true;
            if (bounty.bountyToken == address(0)){
                _sendEth(bounty.creator, bounty.totalAmtDeposited);
            } else {
                IERC20(bounty.bountyToken).safeTransfer(bounty.creator, bounty.totalAmtDeposited);
            }
            emit BountyRecalled(reportId, bounty.totalAmtDeposited, bounty.bountyToken);
        }

    }

    /**
     * @notice Allows bounty editor to redirect the full or unclaimed bounty to a new reportId
     * @param reportId The unique identifier for the openOracle report instance for which there is a bounty
     * @param newReportId The unique identifier for the new openOracle report instance for which a bounty is desired
     */
    function editBounty(uint256 reportId, uint256 newReportId) external nonReentrant {
        Bounties storage bounty = Bounty[reportId];
        if (msg.sender != bounty.editor) revert InvalidInput("wrong caller");
        if (newReportId != oracle.nextReportId() - 1) revert InvalidInput("wrong reportId"); // create report instance right before creating bounty
        if (oracle.reportStatus(newReportId).currentReporter != address(0)) revert InvalidInput("reportId has a report");
        if (Bounty[newReportId].maxRounds > 0) revert InvalidInput("newReportId has bounty");
        if (bounty.recalled) revert InvalidInput("bounty recalled");
        if (bounty.maxRounds == 0) revert InvalidInput("bounty doesnt exist");

        uint256 amount;
        Bounty[newReportId] = Bounty[reportId];
        amount = bounty.claimed ? bounty.totalAmtDeposited - bounty.bountyClaimed : bounty.totalAmtDeposited;

        if (bounty.claimed){
            Bounty[newReportId].totalAmtDeposited = amount;

            if (amount < bounty.bountyStartAmt) {
                Bounty[newReportId].bountyStartAmt = amount;
            }

            Bounty[newReportId].bountyClaimed = 0;
            Bounty[newReportId].claimed = false;
        }

            Bounty[newReportId].start = bounty.timeType ? block.timestamp + bounty.forwardStartTime : block.number + bounty.forwardStartTime;
            Bounty[reportId].recalled = true;
            Bounty[reportId].totalAmtDeposited = 0;
            emit BountyRetargeted(newReportId, reportId, amount, Bounty[newReportId].bountyStartAmt, bounty.maxRounds, bounty.bountyMultiplier, block.timestamp, bounty.timeType, Bounty[newReportId].start, bounty.roundLength, bounty.bountyToken);
    }

    /**
     * @notice Submits the initial price report with a custom reporter address and claims the bounty to this address. Amounts use smallest unit for a given ERC-20.
     * @param reportId The unique identifier for the report
     * @param p Oracle parameter data from struct oracleParams
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Choose the amount of token2 that equals amount1 in value
     * @param stateHash State hash for a given reportId in the oracle game
     * @param reporter The address that will receive tokens back when this report is settled or disputed
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     * @dev Tokens are pulled from msg.sender but will be returned to reporter address
     * @dev This overload enables contracts to submit reports on behalf of users
     */
    function submitInitialReport(uint256 reportId, oracleParams calldata p, uint256 amount1, uint256 amount2, bytes32 stateHash, address reporter, uint256 timestamp, uint256 blockNumber, uint256 timestampBound, uint256 blockNumberBound) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) revert InvalidInput("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert InvalidInput("block number");
        if (!validate(reportId, p)) revert InvalidInput("params dont match");
        _submitInitialReport(reportId, amount1, amount2, stateHash, reporter);
    }

    /**
     * @notice Submits the initial price report and claims the bounty. Amounts use smallest unit for a given ERC-20.
     * @param reportId The unique identifier for the report
     * @param p Oracle parameter data from struct oracleParams which is checked against on-chain oracle state.
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Choose the amount of token2 that equals amount1 in value
     * @param stateHash State hash for a given reportId in the oracle game
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     * @dev Tokens are pulled from msg.sender and will be returned to msg.sender when settled or disputed
     */
    function submitInitialReport(uint256 reportId, oracleParams calldata p, uint256 amount1, uint256 amount2, bytes32 stateHash, uint256 timestamp, uint256 blockNumber, uint256 timestampBound, uint256 blockNumberBound) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) revert InvalidInput("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert InvalidInput("block number");
        if (!validate(reportId, p)) revert InvalidInput("params dont match");
        _submitInitialReport(reportId, amount1, amount2, stateHash, msg.sender);
    }

    /**
     * @notice Submits the initial price report for a given report ID and claims the bounty. Amounts use smallest unit for a given ERC-20.
               No validation other than stateHash is performed
     * @param reportId The unique identifier for the report
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Choose the amount of token2 that equals amount1 in value
     * @param stateHash State hash for a given reportId in the oracle game
     * @dev Tokens are pulled from msg.sender and will be returned to msg.sender when settled or disputed
     */
    function submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash) external nonReentrant {
        _submitInitialReport(reportId, amount1, amount2, stateHash, msg.sender);
    }

    /**
     * @notice Submits the initial price report with a custom reporter address and claims the bounty to this address. Amounts use smallest unit for a given ERC-20.
               No validation other than stateHash is performed
     * @param reportId The unique identifier for the report
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Choose the amount of token2 that equals amount1 in value
     * @param stateHash State hash for a given reportId in the oracle game
     * @param reporter The address that will receive tokens back when this report is settled or disputed
     * @dev Tokens are pulled from msg.sender and will be returned to reporter when settled or disputed
     */
    function submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash, address reporter) external nonReentrant {
        _submitInitialReport(reportId, amount1, amount2, stateHash, reporter);
    }

    function _submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash, address reporter) internal {
        Bounties storage bounty = Bounty[reportId];

        if (bounty.recalled) revert InvalidInput("bounty recalled");
        if (bounty.claimed) revert InvalidInput("bounty claimed");
        if (bounty.maxRounds == 0) revert InvalidInput("bounty doesnt exist");

        address token1 = oracle.reportMeta(reportId).token1;
        address token2 = oracle.reportMeta(reportId).token2;

        uint256 bountyAmt = calcBounty(bounty.start, bounty.bountyStartAmt, bounty.maxRounds, bounty.bountyMultiplier, bounty.totalAmtDeposited, bounty.timeType, bounty.roundLength);
        bounty.bountyClaimed = bountyAmt;
        bounty.claimed = true;

        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        IERC20(token2).safeTransferFrom(msg.sender, address(this), amount2);

        IERC20(token1).safeIncreaseAllowance(address(oracle), amount1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), amount2);

        oracle.submitInitialReport(reportId, amount1, amount2, stateHash, reporter);

        IERC20(token1).forceApprove(address(oracle), 0);
        IERC20(token2).forceApprove(address(oracle), 0);

        if (bounty.bountyToken == address(0)){
            _sendEth(payable(reporter), bountyAmt);
        } else {
            IERC20(bounty.bountyToken).safeTransfer(reporter, bountyAmt);
        }
        
        uint256 amount = bounty.totalAmtDeposited - bounty.bountyClaimed;

        if (bounty.recallOnClaim && amount > 0){
            bounty.recalled = true;
            if (bounty.bountyToken == address(0)){
                _sendEth(bounty.creator, amount);
            } else {
                _transferTokens(bounty.bountyToken, address(this), bounty.creator, amount);
            }
            emit BountyRecalled(reportId, amount, bounty.bountyToken);
        }

        emit BountyInitialReportSubmitted(reportId, bountyAmt, bounty.bountyToken);
    }


    /**
     * @notice Withdraws temp holdings for a specific token
     * @param tokenToGet The token address to withdraw tokens for
     */
    function getTempHolding(address tokenToGet, address _to) external nonReentrant {
        uint256 amount = tempHolding[_to][tokenToGet];
        if (amount > 0) {
            if (tokenToGet != address(0)){
                tempHolding[_to][tokenToGet] = 0;
                _transferTokens(tokenToGet, address(this), _to, amount);
            } else {
                tempHolding[_to][tokenToGet] = 0;
                _sendEth(payable(_to), amount);
            }
        }
    }

    function calcBounty(uint256 start, uint256 bountyStartAmt, uint256 maxRounds, uint256 bountyMultiplier, uint256 totalAmtDeposited, bool timeType, uint256 roundLength) internal view returns (uint256){

        uint256 currentTime = timeType ? block.timestamp : block.number;
        if (currentTime < start) revert InvalidInput("start time");

            uint256 rounds = (currentTime - start) / roundLength;
            if (rounds > maxRounds) {
                rounds = maxRounds;
            }

            uint256 bounty = bountyStartAmt;
            for (uint256 i = 0; i < rounds; i++) {
                bounty = (bounty * bountyMultiplier) / 10000;
            }

            if (bounty > totalAmtDeposited){
                bounty = totalAmtDeposited;
            }

            return bounty;

    }

    function validate(uint256 reportId, oracleParams calldata p) internal view returns (bool) {
        IOpenOracle.ReportMeta memory meta = oracle.reportMeta(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        IOpenOracle.extraReportData memory extra = oracle.extraData(reportId);

        //basic callbackGasLimit and settlement time checks
        if (meta.timeType && meta.settlementTime > 86400) return false;
        if (!meta.timeType && meta.settlementTime > 43200) return false;
        if (extra.callbackGasLimit > 1500000) return false;

        if (p.keepFee == false) return false;

        //oracle instance sanity checks
        if (p.exactToken1Report != meta.exactToken1Report) return false;
        if (p.keepFee != extra.keepFee) return false;

        if (p.escalationHalt != meta.escalationHalt) return false;
        if (p.fee != meta.fee) return false;
        if (p.settlerReward != meta.settlerReward) return false;
        if (p.token1 != meta.token1) return false;
        if (p.settlementTime != meta.settlementTime) return false;
        if (p.token2 != meta.token2) return false;
        if (p.timeType != meta.timeType) return false;
        if (p.feePercentage != meta.feePercentage) return false;
        if (p.protocolFee != meta.protocolFee) return false;
        if (p.multiplier != meta.multiplier) return false;
        if (p.disputeDelay != meta.disputeDelay) return false;

        if (p.currentAmount1 != status.currentAmount1) return false;
        if (p.currentAmount2 != status.currentAmount2) return false;

        if (p.callbackGasLimit != extra.callbackGasLimit) return false;
        if (p.protocolFeeRecipient != extra.protocolFeeRecipient) return false;

        return true;

    }


    /**
     * @dev Internal function to send ETH to a recipient
     */
    function _sendEth(address payable recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) =  recipient.call{value: amount, gas: 40000}("");
        if (!success){
            tempHolding[recipient][address(0)] += amount;
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

    /**
     * @notice Returns bounty data for an array of reportIds
     * @param reportIds Array of report IDs to query
     * @return Array of Bounties structs corresponding to each reportId
     */
    function getBounties(uint256[] calldata reportIds) external view returns (Bounties[] memory) {
        Bounties[] memory results = new Bounties[](reportIds.length);
        for (uint256 i = 0; i < reportIds.length; i++) {
            results[i] = Bounty[reportIds[i]];
        }
        return results;
    }

    receive() external payable {

    }
}
