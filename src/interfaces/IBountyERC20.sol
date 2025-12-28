// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBountyERC20 {
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

    event BountyInitialReportSubmitted(uint256 indexed reportId, uint256 bountyPaid, address bountyToken);
    event BountyRecalled(uint256 indexed reportId, uint256 amt, address bountyToken);
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

    function Bounty(uint256 id) external view returns (Bounties memory);

    function createOracleBounty(
        uint256 reportId,
        uint256 bountyStartAmt,
        address creator,
        address editor,
        uint16 bountyMultiplier,
        uint16 maxRounds,
        bool timeType,
        uint256 start,
        address bountyToken,
        uint256 maxAmount,
        uint256 roundLength,
	    bool recallOnClaim
    ) external payable;

    function createOracleBounty(
        uint256 reportId,
        uint256 bountyStartAmt,
        address creator,
        address editor,
        uint16 bountyMultiplier,
        uint16 maxRounds,
        bool timeType,
        address bountyToken,
        uint256 maxAmount,
        uint256 roundLength,
	    bool recallOnClaim
    ) external payable;

    function createOracleBountyFwd(
        uint256 reportId,
        uint256 bountyStartAmt,
        address creator,
        address editor,
        uint16 bountyMultiplier,
        uint16 maxRounds,
        bool timeType,
        uint256 forwardStartTime,
        address bountyToken,
        uint256 maxAmount,
        uint256 roundLength,
        bool recallOnClaim
    ) external payable;

    function recallBounty(uint256 reportId) external;

    function editBounty(uint256 reportId, uint256 newReportId) external;

    function submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash, address reporter) external;

    function submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash) external;
}
