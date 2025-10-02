// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOpenOracle} from "./interfaces/IOpenOracle.sol";

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
        bool feeToken;
    }

    function getData(uint256 reportId) external view returns (botStruct[] memory){
        botStruct[] memory data = new botStruct[](1);
        for (uint256 i = reportId; i < reportId+1; i++) {
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
                _reportExtra.keepFee,
                _reportExtra.feeToken
                );
            }
        return data;
    }

    function getData(uint256 startId, uint256 endId) external view returns (botStruct[] memory){
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
                _reportExtra.keepFee,
                _reportExtra.feeToken
                );
            }
        return data;
    }

}
