// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";

contract openOracleBatcher is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error EthTransferFailed();
    error ActionSafetyFailure(string);

    /* ─── immutables & constants ────────────────────────────── */
    IOpenOracle public immutable oracle;

    /* ─── constructor ──────────────────────────────────────── */
    constructor(address oracleAddress) {
        require(oracleAddress != address(0), "oracle 0");
        oracle = IOpenOracle(oracleAddress);
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

    // converts adversarial RPC into just a revert on-chain
    function validate(uint256 reportId, oracleParams calldata p, bool isInitialReport) internal view returns (bool) {
        IOpenOracle.ReportMeta memory meta = oracle.reportMeta(reportId);
        IOpenOracle.ReportStatus memory status = oracle.reportStatus(reportId);
        IOpenOracle.extraReportData memory extra = oracle.extraData(reportId);

        //basic callbackGasLimit and settlement time checks
        if (meta.timeType && meta.settlementTime > 86400) return false;
        if (!meta.timeType && meta.settlementTime > 43200) return false;
        if (extra.callbackGasLimit > 1500000) return false;

        //oracle instance sanity checks
        if (isInitialReport) {
            if (p.exactToken1Report != meta.exactToken1Report) return false;
            if (p.keepFee != extra.keepFee) return false;
        }

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

    function keepFeeCheck(uint256 reportId, bool keepFee) internal view returns (bool) {
        IOpenOracle.extraReportData memory extra = oracle.extraData(reportId);

        if (!extra.keepFee) return false;
        if (!keepFee) return false;

        return true;

    }

    struct InitialReportData {
        uint256 reportId;
        uint256 amount1;
        uint256 amount2;
        bytes32 stateHash;
    }

    /**
     * @notice Submits one initial report with reportId validation checks.
     * @param reports Initial report data from struct InitialReportData
     * @param p Oracle parameter data from struct oracleParams
     * @param batchAmount1 Amount of oracle game token1 the batcher can draw from to attempt the initial report
     * @param batchAmount2 Amount of oracle game token2 the batcher can draw from to attempt the initial report
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     */
    function submitInitialReportSafe(
        InitialReportData[] calldata reports,
        oracleParams calldata p,
        uint256 batchAmount1,
        uint256 batchAmount2,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) revert ActionSafetyFailure("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert ActionSafetyFailure("block number");
        if (reports.length != 1) revert ActionSafetyFailure("too many reports");
        if (!keepFeeCheck(reports[0].reportId, p.keepFee)) revert ActionSafetyFailure("keepFee false");
        if (!validate(reports[0].reportId, p, true)) revert ActionSafetyFailure("params dont match");

        _submitInitialReports(reports, batchAmount1, batchAmount2);
    }

    /**
     * @notice Submits multiple initial reports. Does not sanity check oracle parameters.
               Note all initial reports must be of the same two tokens.
               Different orders of oracle game tokens are permissible so long as they are the same:
                   reportId 1: token1 WETH, token2 USDC 
                   reportId 2: token1 USDC, token WETH
                   reportId 3: token1 WETH, token2 USDC 
               This would be a permissible batch
     * @param reports Initial report data from struct InitialReportData
     * @param batchAmount1 Amount of oracle game token1 the batcher can draw from to attempt the initial reports
     * @param batchAmount2 Amount of oracle game token2 the batcher can draw from to attempt the initial reports
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     */
    function submitInitialReportsNoValidation(
        InitialReportData[] calldata reports,
        uint256 batchAmount1,
        uint256 batchAmount2,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) revert ActionSafetyFailure("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert ActionSafetyFailure("block number");

        _submitInitialReports(reports, batchAmount1, batchAmount2);
    }

    /**
     * @notice Submits multiple initial reports without validation or timing / block number checks. Legacy function.
               Note all initial reports must be of the same two tokens.
               Different orders of oracle game tokens are permissible so long as they are the same:
                   reportId 1: token1 WETH, token2 USDC 
                   reportId 2: token1 USDC, token WETH
                   reportId 3: token1 WETH, token2 USDC 
               This would be a permissible batch
     * @param reports Initial report data from struct InitialReportData
     * @param batchAmount1 Amount of oracle game token1 the batcher can draw from to attempt the initial reports
     * @param batchAmount2 Amount of oracle game token2 the batcher can draw from to attempt the initial reports
     */
    function submitInitialReports(InitialReportData[] calldata reports, uint256 batchAmount1, uint256 batchAmount2)
        external
        nonReentrant
    {
        _submitInitialReports(reports, batchAmount1, batchAmount2);
    }

    function _submitInitialReports(InitialReportData[] calldata reports, uint256 batchAmount1, uint256 batchAmount2)
        internal
    {
        address sender = msg.sender;
        uint256 startBal1;
        uint256 startBal2;

        // Get token addresses from 0th report
        address token1 = oracle.reportMeta(reports[0].reportId).token1;
        address token2 = oracle.reportMeta(reports[0].reportId).token2;

        startBal1 = IERC20(token1).balanceOf(address(this));
        startBal2 = IERC20(token2).balanceOf(address(this));

        // Transfer tokens to batcher
        IERC20(token1).safeTransferFrom(sender, address(this), batchAmount1);
        IERC20(token2).safeTransferFrom(sender, address(this), batchAmount2);

        // Approve oracle
        IERC20(token1).safeIncreaseAllowance(address(oracle), batchAmount1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), batchAmount2);

        for (uint256 i = 0; i < reports.length; i++) {
            InitialReportData memory report = reports[i];
            try oracle.submitInitialReport(report.reportId, report.amount1, report.amount2, report.stateHash, sender) {
                // Success - continue to next
            } catch {
                // Failed - skip and continue
                continue;
            }
        }

        // Calculate how much was actually spent
        uint256 spent1 = (startBal1 + batchAmount1) - IERC20(token1).balanceOf(address(this));
        uint256 spent2 = (startBal2 + batchAmount2) - IERC20(token2).balanceOf(address(this));

        // Return unspent tokens
        if (spent1 < batchAmount1) {
            IERC20(token1).safeTransfer(sender, batchAmount1 - spent1);
        }
        if (spent2 < batchAmount2) {
            IERC20(token2).safeTransfer(sender, batchAmount2 - spent2);
        }

        IERC20(token1).forceApprove(address(oracle), 0);
        IERC20(token2).forceApprove(address(oracle), 0);
    }

    struct DisputeData {
        uint256 reportId;
        address tokenToSwap;
        uint256 newAmount1;
        uint256 newAmount2;
        uint256 amt2Expected;
        bytes32 stateHash;
    }

    function disputeReports(DisputeData[] calldata disputes, uint256 batchAmount1, uint256 batchAmount2)
        external
        nonReentrant
    {
        _disputeReports(disputes, batchAmount1, batchAmount2);
    }

    /**
     * @notice Submits multiple disputes. Does not sanity check oracle parameters.
               Note all disputes must be of the same two tokens.
               Different orders of oracle game tokens are permissible so long as they are the same:
                   reportId 1: token1 WETH, token2 USDC 
                   reportId 2: token1 USDC, token WETH
                   reportId 3: token1 WETH, token2 USDC 
               This would be a permissible batch
     * @param disputes Dispute data from struct DisputeData
     * @param batchAmount1 Amount of oracle game token1 the batcher can draw from to attempt the disputes
     * @param batchAmount2 Amount of oracle game token2 the batcher can draw from to attempt the disputes
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     */
    function disputeReportsNoValidation(
        DisputeData[] calldata disputes,
        uint256 batchAmount1,
        uint256 batchAmount2,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound)revert ActionSafetyFailure("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert ActionSafetyFailure("block number");
        
        _disputeReports(disputes, batchAmount1, batchAmount2);
    }

    /**
     * @notice Submits one dispute with reportId validation checks.
     * @param disputes Dispute data from struct DisputeData
     * @param p Oracle parameter data from struct oracleParams
     * @param batchAmount1 Amount of oracle game token1 the batcher can draw from to attempt the dispute
     * @param batchAmount2 Amount of oracle game token2 the batcher can draw from to attempt the dispute
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     */
    function disputeReportSafe(
        DisputeData[] calldata disputes,
        oracleParams calldata p,
        uint256 batchAmount1,
        uint256 batchAmount2,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) revert ActionSafetyFailure("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert ActionSafetyFailure("block number");
        if (disputes.length != 1) revert ActionSafetyFailure("too many disputes");
        if (!validate(disputes[0].reportId, p, false)) revert ActionSafetyFailure("params dont match");

        _disputeReports(disputes, batchAmount1, batchAmount2);
    }

    /**
     * @notice Submits multiple disputes without validation or timing / block number checks. Legacy function.
               Note all disputes must be of the same two tokens.
               Different orders of oracle game tokens are permissible so long as they are the same:
                   reportId 1: token1 WETH, token2 USDC 
                   reportId 2: token1 USDC, token WETH
                   reportId 3: token1 WETH, token2 USDC 
               This would be a permissible batch
     * @param disputes Dispute data from struct DisputeData
     * @param batchAmount1 Amount of oracle game token1 the batcher can draw from to attempt the disputes
     * @param batchAmount2 Amount of oracle game token2 the batcher can draw from to attempt the disputes
     */
    function _disputeReports(DisputeData[] calldata disputes, uint256 batchAmount1, uint256 batchAmount2) internal {
        address sender = msg.sender;
        uint256 startBal1;
        uint256 startBal2;

        // Get token addresses from 0th report
        address token1 = oracle.reportMeta(disputes[0].reportId).token1;
        address token2 = oracle.reportMeta(disputes[0].reportId).token2;

        startBal1 = IERC20(token1).balanceOf(address(this));
        startBal2 = IERC20(token2).balanceOf(address(this));

        // Transfer tokens to batcher
        IERC20(token1).safeTransferFrom(sender, address(this), batchAmount1);
        IERC20(token2).safeTransferFrom(sender, address(this), batchAmount2);

        // Approve oracle
        IERC20(token1).safeIncreaseAllowance(address(oracle), batchAmount1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), batchAmount2);

        for (uint256 i = 0; i < disputes.length; i++) {
            DisputeData memory dispute = disputes[i];
            try oracle.disputeAndSwap(
                dispute.reportId,
                dispute.tokenToSwap,
                dispute.newAmount1,
                dispute.newAmount2,
                sender,
                dispute.amt2Expected,
                dispute.stateHash
            ) {
                // Success - continue to next
            } catch {
                // Failed - skip and continue
                continue;
            }
        }

        // Calculate how much was actually spent
        uint256 spent1 = (startBal1 + batchAmount1) - IERC20(token1).balanceOf(address(this));
        uint256 spent2 = (startBal2 + batchAmount2) - IERC20(token2).balanceOf(address(this));

        // Return unspent tokens
        if (spent1 < batchAmount1) {
            IERC20(token1).safeTransfer(sender, batchAmount1 - spent1);
        }
        if (spent2 < batchAmount2) {
            IERC20(token2).safeTransfer(sender, batchAmount2 - spent2);
        }

        IERC20(token1).forceApprove(address(oracle), 0);
        IERC20(token2).forceApprove(address(oracle), 0);
    }

    struct SettleData {
        uint256 reportId;
    }

    struct SafeSettleData {
        uint256 reportId;
        bytes32 stateHash;
    }

    /**
     * @notice Settles multiple reports without stateHash validation.
     * @param settles Settle data from struct SettleData
     */
    function settleReports(SettleData[] calldata settles) external nonReentrant {
        uint256 balanceBefore = address(this).balance;
        for (uint256 i = 0; i < settles.length; i++) {
            SettleData memory settle = settles[i];
            try oracle.settle(settle.reportId) {}
            catch {
                continue;
            }
        }
        uint256 total = address(this).balance - balanceBefore;
        (bool ok,) = payable(msg.sender).call{value: total}("");
        if (!ok) revert EthTransferFailed();
    }

    /**
     * @notice Settles multiple reports with stateHash validation and timing checks.
     * @param settles Settle data from struct SafeSettleData. Contains stateHash.
     * @param timestamp Current block.timestamp
     * @param blockNumber Current block number
     * @param timestampBound Transaction will revert if it lands +/- this number of seconds outside passed timestamp
     * @param blockNumber Transaction will revert if it lands +/- this number of blocks outside passed blockNumber
     */
    function safeSettleReports(
        SafeSettleData[] calldata settles,
        uint256 timestamp,
        uint256 blockNumber,
        uint256 timestampBound,
        uint256 blockNumberBound
    ) external nonReentrant {
        if (block.timestamp > timestamp + timestampBound || block.timestamp < timestamp - timestampBound) revert ActionSafetyFailure("timestamp");
        if (block.number > blockNumber + blockNumberBound || block.number < blockNumber - blockNumberBound) revert ActionSafetyFailure("block number");
        uint256 balanceBefore = address(this).balance;
        for (uint256 i = 0; i < settles.length; i++) {
            SafeSettleData memory settle = settles[i];
            if (oracle.extraData(settle.reportId).stateHash == settle.stateHash) {
                try oracle.settle(settle.reportId) {}
                catch {
                    continue;
                }
            } else {
                continue;
            }
        }
        uint256 total = address(this).balance - balanceBefore;
        (bool ok,) = payable(msg.sender).call{value: total}("");
        if (!ok) revert EthTransferFailed();
    }

    function requestPrices(IOpenOracle.CreateReportParams[] calldata priceRequests) external payable nonReentrant {
        for (uint256 i = 0; i < priceRequests.length; i++) {
            IOpenOracle.CreateReportParams memory req = priceRequests[i];
            oracle.createReportInstance{value: msg.value / priceRequests.length}(req);
        }

        (bool ok,) = payable(msg.sender).call{value: msg.value % priceRequests.length}("");
        if (!ok) revert EthTransferFailed();
    }

    /* -- accept ETH rewards ------------------------------------------------- */
    receive() external payable {}
}
