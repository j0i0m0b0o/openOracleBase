// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IOpenOracle.sol";
import "./interfaces/IBountyERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BountyAndPriceRequest
 * @notice For Optimism growth grant.
 */

contract BountyAndPriceRequest is ReentrancyGuard {
    IOpenOracle public immutable oracle;
    IBountyERC20 public immutable bounty;
    address public immutable owner;

    using SafeERC20 for IERC20;

    struct BountyParamSet {
        uint256 bountyStartAmt;
        address creator;
        address editor;
        uint16 bountyMultiplier;
        uint16 maxRounds;
        bool timeType;
        uint256 forwardStartTime;
        address bountyToken;
        uint256 maxAmount;
        uint256 roundLength;
        bool recallOnClaim;
        uint48 recallDelay;
    }

    IOpenOracle.CreateReportParams[4] public games;
    uint256[4] public lastGameTime;
    uint256[4] public gameTimer;

    BountyParamSet[3] public bountyParams;

    uint256[4] public lastReportId;
    uint8[4] public bountyForGame;

    event GameCreated(uint256 reportId, uint8 gameId);
    error BadGameId();

    constructor(address _oracle, address _bounty, address _owner) {
        require(_oracle != address(0), "oracle address cannot be 0");
        require(_bounty != address(0), "bounty address cannot be 0");
        oracle = IOpenOracle(_oracle);
        bounty = IBountyERC20(_bounty);
        owner = _owner; // will be project multisig when grant is actually received

        gameTimer[0] = 60 * 3;
        gameTimer[1] = 60 * 10;
        gameTimer[2] = 60 * 60;
        gameTimer[3] = 60 * 60 * 24;

        bountyForGame[0] = 0;
        bountyForGame[1] = 0;
        bountyForGame[2] = 1;
        bountyForGame[3] = 2;

        games[0] = IOpenOracle.CreateReportParams({
            exactToken1Report: 2000000000000000,
            escalationHalt: 20000000000000000,
            settlerReward: 500000000000,
            token1Address: 0x4200000000000000000000000000000000000006,
            settlementTime: 10,
            disputeDelay: 2,
            protocolFee: 0,
            token2Address: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            callbackGasLimit: 0,
            feePercentage: 1,
            multiplier: 125,
            timeType: true,
            trackDisputes: false,
            keepFee: true,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: address(this)
        });

        games[1] = IOpenOracle.CreateReportParams({
            exactToken1Report: 20000000,
            escalationHalt: 100000000,
            settlerReward: 500000000000,
            token1Address: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            settlementTime: 4,
            disputeDelay: 0,
            protocolFee: 250,
            token2Address: 0x4200000000000000000000000000000000000006,
            callbackGasLimit: 100000,
            feePercentage: 1,
            multiplier: 110,
            timeType: false,
            trackDisputes: false,
            keepFee: true,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: address(this)
        });

        games[2] = IOpenOracle.CreateReportParams({
            exactToken1Report: 100000000,
            escalationHalt: 1000000000,
            settlerReward: 500000000000,
            token1Address: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            settlementTime: 600,
            disputeDelay: 0,
            protocolFee: 0,
            token2Address: 0x4200000000000000000000000000000000000006,
            callbackGasLimit: 100000,
            feePercentage: 1,
            multiplier: 150,
            timeType: true,
            trackDisputes: false,
            keepFee: true,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: address(this)
        });

        games[3] = IOpenOracle.CreateReportParams({
            exactToken1Report: 200000000000000000,
            escalationHalt: 1000000000000000000,
            settlerReward: 500000000000,
            token1Address: 0x4200000000000000000000000000000000000006,
            settlementTime: 600 * 6 * 4, // 4 hours
            disputeDelay: 0,
            protocolFee: 0,
            token2Address: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            callbackGasLimit: 100000,
            feePercentage: 1,
            multiplier: 115,
            timeType: true,
            trackDisputes: false,
            keepFee: true,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            protocolFeeRecipient: address(this)
        });

        bountyParams[0] = BountyParamSet({
            bountyStartAmt: 1666666660000000,
            creator: address(this),
            editor: address(this),
            bountyMultiplier: 11500,
            maxRounds: 35,
            timeType: true,
            forwardStartTime: 10,
            bountyToken: 0x4200000000000000000000000000000000000042,
            maxAmount: 53333333300000000,
            roundLength: 6,
            recallOnClaim: true,
            recallDelay: 0
        });

        bountyParams[1] = BountyParamSet({
            bountyStartAmt: 25866666660000000,
            creator: address(this),
            editor: address(this),
            bountyMultiplier: 12000,
            maxRounds: 35,
            timeType: true,
            forwardStartTime: 20,
            bountyToken: 0x4200000000000000000000000000000000000042,
            maxAmount: 1257666666600000000,
            roundLength: 6,
            recallOnClaim: true,
            recallDelay: 0
        });

        bountyParams[2] = BountyParamSet({
            bountyStartAmt: 200066666660000000,
            creator: address(this),
            editor: address(this),
            bountyMultiplier: 12000,
            maxRounds: 35,
            timeType: true,
            forwardStartTime: 20,
            bountyToken: 0x4200000000000000000000000000000000000042,
            maxAmount: 31257666666600000000,
            roundLength: 6,
            recallOnClaim: true,
            recallDelay: 0
        });

    }

    function bountyAndPriceRequest(uint8 gameId) external nonReentrant returns (uint256 reportId) {
        if (gameId >= 4) revert BadGameId();
        BountyParamSet memory bp = bountyParams[bountyForGame[gameId]];
        IOpenOracle.CreateReportParams memory reportParams = games[gameId];
        uint256 LastGameTime = lastGameTime[gameId];
        uint256 GameTimer = gameTimer[gameId];
        uint256 oracleFee;
        uint256 bountyValue;

        if (LastGameTime > 0){
            if (block.timestamp < LastGameTime + GameTimer) revert ("too early");
        }

        oracleFee = reportParams.settlerReward + 1;
        bountyValue = 0;
        lastGameTime[gameId] = block.timestamp;
        
        IERC20(bp.bountyToken).forceApprove(address(bounty), bp.maxAmount);

        // Create report instance
        reportId = oracle.createReportInstance{value: oracleFee}(reportParams);
        lastReportId[gameId] = reportId;

        // Create bounty
        bounty.createOracleBountyFwd{value: bountyValue}(
            reportId,
            bp.bountyStartAmt,
            bp.creator,
            bp.editor,
            bp.bountyMultiplier,
            bp.maxRounds,
            bp.timeType,
            bp.forwardStartTime,
            bp.bountyToken,
            bp.maxAmount,
            bp.roundLength,
            bp.recallOnClaim,
            bp.recallDelay
        );

        IERC20(bp.bountyToken).forceApprove(address(bounty), 0);
        emit GameCreated(reportId, gameId);
    }

    function sweep(address tokenToGet, uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert ("not owner");

        if (tokenToGet != address(0)){
            IERC20(tokenToGet).safeTransfer(owner, amount);
        } else {
            (bool success,) = payable(owner).call{value: amount}("");
            if (!success) revert("eth transfer failed");
        }
    }

    function recallBounties(uint256[] calldata reportIds) external nonReentrant {
        if (msg.sender != owner) revert("not owner");

        for (uint256 i = 0; i < reportIds.length; i++) {
            uint256 reportId = reportIds[i];
            try bounty.recallBounty(reportId) {
            } catch {
                // swallow
            }
        }
    }

    receive() external payable {}
}
