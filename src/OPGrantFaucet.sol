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

    struct BountyParams {
        uint256 totalAmtDeposited; // wei sent to bounty contract
        uint256 bountyStartAmt; // starting bounty amount in wei
        uint256 forward; // time past report creation the bounty starts escalating
        uint16 bountyMultiplier; // per-block or per-second exponential increase (15000 = 1.5x)
        uint16 maxRounds; // time window for exponential increase
        address bountyToken; //token bounty is paid in
        uint256 roundLength; // round length
    }

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

    error InsufficientETH(uint256 sent, uint256 required);

    IOpenOracle.CreateReportParams public oracleGame1;
    IOpenOracle.CreateReportParams public oracleGame2;
    IOpenOracle.CreateReportParams public oracleGame3;
    IOpenOracle.CreateReportParams public oracleGame4;

    BountyParamSet public bountyParam1;
    BountyParamSet public bountyParam2;
    BountyParamSet public bountyParam3;

    uint256 LastGame1Time; //seconds
    uint256 LastGame2Time; //seconds
    uint256 LastGame3Time; //seconds
    uint256 LastGame4Time; //seconds

    uint256 Game1Timer = 60 * 10;
    uint256 Game2Timer = 60 * 20;
    uint256 Game3Timer = 60 * 60 * 4;
    uint256 Game4Timer = 60 * 60 * 24;

    constructor(address _oracle, address _bounty, address _owner) {
        require(_oracle != address(0), "oracle address cannot be 0");
        require(_bounty != address(0), "bounty address cannot be 0");
        oracle = IOpenOracle(_oracle);
        bounty = IBountyERC20(_bounty);
        owner = _owner;

    oracleGame1 = IOpenOracle.CreateReportParams({
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

    oracleGame2 = IOpenOracle.CreateReportParams({
        exactToken1Report: 10000000,
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

    oracleGame3 = IOpenOracle.CreateReportParams({
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

    oracleGame4 = IOpenOracle.CreateReportParams({
        exactToken1Report: 200000000000000000,
        escalationHalt: 1000000000000000000,
        settlerReward: 500000000000,
        token1Address: 0x4200000000000000000000000000000000000006,
        settlementTime: 600 * 10 * 4, // 4 hours
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

    bountyParam1 = BountyParamSet({
        bountyStartAmt: 1666666660000000,
        creator: address(this),
        editor: address(this),
        bountyMultiplier: 11000,
        maxRounds: 35,
        timeType: true,
        forwardStartTime: 10,
        bountyToken: 0x4200000000000000000000000000000000000042,
        maxAmount: 33333333300000000,
        roundLength: 6,
        recallOnClaim: true,
        recallDelay: 0
    });

    bountyParam2 = BountyParamSet({
        bountyStartAmt: 12866666660000000,
        creator: address(this),
        editor: address(this),
        bountyMultiplier: 11000,
        maxRounds: 35,
        timeType: true,
        forwardStartTime: 20,
        bountyToken: 0x4200000000000000000000000000000000000042,
        maxAmount: 257666666600000000,
        roundLength: 6,
        recallOnClaim: true,
        recallDelay: 0
    });

    bountyParam3 = BountyParamSet({
        bountyStartAmt: 80066666660000000,
        creator: address(this),
        editor: address(this),
        bountyMultiplier: 11000,
        maxRounds: 35,
        timeType: true,
        forwardStartTime: 20,
        bountyToken: 0x4200000000000000000000000000000000000042,
        maxAmount: 1257666666600000000,
        roundLength: 6,
        recallOnClaim: true,
        recallDelay: 0
    });

    }

    function bountyAndPriceRequest1() external nonReentrant returns (uint256 reportId) {
        BountyParamSet memory bountyParams = bountyParam1;
        IOpenOracle.CreateReportParams memory reportParams = oracleGame1;
        uint256 LastGameTime = LastGame1Time;
        uint256 GameTimer = Game1Timer;
        uint256 oracleFee;
        uint256 bountyValue;

        if (LastGameTime > 0){
            if (block.timestamp < LastGameTime + GameTimer) revert ("too early");
        }

        oracleFee = oracleGame1.settlerReward + 1;
        bountyValue = 0;
        LastGame1Time = block.timestamp;

        IERC20(bountyParams.bountyToken).forceApprove(address(bounty), bountyParams.maxAmount);

        // Create report instance
        reportId = oracle.createReportInstance{value: oracleFee}(reportParams);

        // Create bounty
        bounty.createOracleBountyFwd{value: bountyValue}(
            reportId,
            bountyParams.bountyStartAmt,
            bountyParams.creator,
            bountyParams.editor,
            bountyParams.bountyMultiplier,
            bountyParams.maxRounds,
            bountyParams.timeType,
            bountyParams.forwardStartTime,
            bountyParams.bountyToken,
            bountyParams.maxAmount,
            bountyParams.roundLength,
            bountyParams.recallOnClaim,
            bountyParams.recallDelay
        );

        IERC20(bountyParams.bountyToken).forceApprove(address(bounty), 0);

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
