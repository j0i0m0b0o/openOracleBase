/**
 * Submitted for verification at basescan.org on 2025-08-01
 */

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOpenOracle {
    struct disputeRecord {
        uint256 amount1;
        uint256 amount2;
        address tokenToSwap;
        uint48 reportTimestamp;
    }

    struct extraReportData {
        bytes32 stateHash;
        address callbackContract;
        uint32 numReports;
        uint32 callbackGasLimit;
        bytes4 callbackSelector;
        bool trackDisputes;
        bool keepFee;
    }

    struct ReportMeta {
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
        uint24 disputeDelay;
    }

    struct ReportStatus {
        uint256 currentAmount1;
        uint256 currentAmount2;
        uint256 price;
        address payable currentReporter;
        uint48 reportTimestamp;
        uint48 settlementTimestamp;
        address payable initialReporter;
        uint48 lastReportOppoTime;
        bool disputeOccurred;
        bool isDistributed;
    }

    function nextReportId() external view returns (uint256);
    function reportMeta(uint256 id) external view returns (ReportMeta memory);
    function reportStatus(uint256 id) external view returns (ReportStatus memory);
    function extraData(uint256 id) external view returns (extraReportData memory);
}

contract openOracleDataProviderV3 {
    /* ─── immutables & constants ────────────────────────────── */
    IOpenOracle public immutable oracle;

    /* ─── constructor ──────────────────────────────────────── */
    constructor(address oracleAddress) {
        require(oracleAddress != address(0), "oracle 0");
        oracle = IOpenOracle(oracleAddress);
    }

    struct botStruct {
        //reportId
        uint256 reportId;
        //reportMeta
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
        uint24 disputeDelay;
        //reportStatus
        uint256 currentAmount1;
        uint256 currentAmount2;
        uint256 price;
        address payable currentReporter;
        uint48 reportTimestamp;
        uint48 settlementTimestamp;
        address payable initialReporter;
        uint48 lastReportOppoTime;
        bool disputeOccurred;
        bool isDistributed;
        //extraData
        bytes32 stateHash;
        address callbackContract;
        uint32 numReports;
        uint32 callbackGasLimit;
        bytes4 callbackSelector;
        bool trackDisputes;
        bool keepFee;
    }

    function getData(uint256 reportId) external view returns (botStruct[] memory) {
        botStruct[] memory data = new botStruct[](1);
        for (uint256 i = reportId; i < reportId + 1; i++) {
            IOpenOracle.ReportMeta memory _reportMeta = oracle.reportMeta(i);
            IOpenOracle.ReportStatus memory _reportStatus = oracle.reportStatus(i);
            IOpenOracle.extraReportData memory _reportExtra = oracle.extraData(i);

            data[0] = botStruct(
                i,
                _reportMeta.exactToken1Report,
                _reportMeta.escalationHalt,
                _reportMeta.fee,
                _reportMeta.settlerReward,
                _reportMeta.token1,
                _reportMeta.settlementTime,
                _reportMeta.token2,
                _reportMeta.timeType,
                _reportMeta.feePercentage,
                _reportMeta.protocolFee,
                _reportMeta.multiplier,
                _reportMeta.disputeDelay,
                _reportStatus.currentAmount1,
                _reportStatus.currentAmount2,
                _reportStatus.price,
                _reportStatus.currentReporter,
                _reportStatus.reportTimestamp,
                _reportStatus.settlementTimestamp,
                _reportStatus.initialReporter,
                _reportStatus.lastReportOppoTime,
                _reportStatus.disputeOccurred,
                _reportStatus.isDistributed,
                _reportExtra.stateHash,
                _reportExtra.callbackContract,
                _reportExtra.numReports,
                _reportExtra.callbackGasLimit,
                _reportExtra.callbackSelector,
                _reportExtra.trackDisputes,
                _reportExtra.keepFee
            );
        }
        return data;
    }

    function getData(uint256 startId, uint256 endId) external view returns (botStruct[] memory) {
        botStruct[] memory data = new botStruct[](endId - startId);
        for (uint256 i = 0; i < (endId - startId); i++) {
            IOpenOracle.ReportMeta memory _reportMeta = oracle.reportMeta(startId + i);
            IOpenOracle.ReportStatus memory _reportStatus = oracle.reportStatus(startId + i);
            IOpenOracle.extraReportData memory _reportExtra = oracle.extraData(startId + i);

            data[i] = botStruct(
                startId + i,
                _reportMeta.exactToken1Report,
                _reportMeta.escalationHalt,
                _reportMeta.fee,
                _reportMeta.settlerReward,
                _reportMeta.token1,
                _reportMeta.settlementTime,
                _reportMeta.token2,
                _reportMeta.timeType,
                _reportMeta.feePercentage,
                _reportMeta.protocolFee,
                _reportMeta.multiplier,
                _reportMeta.disputeDelay,
                _reportStatus.currentAmount1,
                _reportStatus.currentAmount2,
                _reportStatus.price,
                _reportStatus.currentReporter,
                _reportStatus.reportTimestamp,
                _reportStatus.settlementTimestamp,
                _reportStatus.initialReporter,
                _reportStatus.lastReportOppoTime,
                _reportStatus.disputeOccurred,
                _reportStatus.isDistributed,
                _reportExtra.stateHash,
                _reportExtra.callbackContract,
                _reportExtra.numReports,
                _reportExtra.callbackGasLimit,
                _reportExtra.callbackSelector,
                _reportExtra.trackDisputes,
                _reportExtra.keepFee
            );
        }
        return data;
    }
}
