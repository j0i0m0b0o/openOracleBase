// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
