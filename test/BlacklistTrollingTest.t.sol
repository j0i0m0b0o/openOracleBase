// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/OpenOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 with blacklist functionality (like USDC)
contract BlacklistableERC20 is ERC20 {
    mapping(address => bool) public blacklisted;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    function unblacklist(address account) external {
        blacklisted[account] = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[msg.sender], "Blacklisted sender");
        require(!blacklisted[to], "Blacklisted recipient");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blacklisted[from], "Blacklisted sender");
        require(!blacklisted[to], "Blacklisted recipient");
        return super.transferFrom(from, to, amount);
    }
}

/// @title BlacklistTrollingTest
/// @notice Tests that oracle handles blacklisted recipients by crediting protocolFees
/// When a transfer fails due to blacklist, funds go to protocolFees[recipient][token]
/// and can be claimed later via getProtocolFees once unblacklisted
contract BlacklistTrollingTest is Test {
    OpenOracle internal oracle;
    BlacklistableERC20 internal token1;
    BlacklistableERC20 internal token2;

    address internal alice = address(0x1);
    address internal bob = address(0x2);
    address internal charlie = address(0x3);
    address internal troll = address(0x666); // The blacklist troll
    address payable internal protocolFeeRecipient = payable(address(0x123456));

    uint256 constant ORACLE_FEE = 0.01 ether;
    uint256 constant SETTLER_REWARD = 0.001 ether;

    function setUp() public {
        oracle = new OpenOracle();
        token1 = new BlacklistableERC20("Token1", "TK1");
        token2 = new BlacklistableERC20("Token2", "TK2");

        // Fund accounts with tokens
        token1.transfer(alice, 100 ether);
        token1.transfer(bob, 100 ether);
        token1.transfer(charlie, 100 ether);
        token2.transfer(alice, 100_000 ether);
        token2.transfer(bob, 100_000 ether);
        token2.transfer(charlie, 100_000 ether);

        // Give ETH
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);

        // Approve oracle for all users
        vm.startPrank(alice);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(charlie);
        token1.approve(address(oracle), type(uint256).max);
        token2.approve(address(oracle), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Test: Dispute with token1 swap - previous reporter gets blacklisted
    // Funds should go to protocolFees and be claimable later
    // -------------------------------------------------------------------------
    function testDisputeToken1Swap_PreviousReporterBlacklisted() public {
        // Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                keepFee: true,
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Bob submits initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        // Wait for dispute delay
        vm.warp(block.timestamp + 6);

        // TROLL ACTION: Blacklist Bob (the initial reporter) before dispute
        token1.blacklist(bob);

        uint256 bobToken1Before = token1.balanceOf(bob);

        // Alice disputes - Bob should NOT receive tokens directly (he's blacklisted)
        // Tokens go to protocolFees[bob][token1] instead
        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1),
            1.1e18,      // newAmount1
            2100e18,     // newAmount2 > oldAmount2, no refund to disputer
            2000e18,     // amt2Expected
            stateHash
        );

        // Bob's direct balance shouldn't have increased (tokens went to protocolFees)
        assertEq(token1.balanceOf(bob), bobToken1Before, "Bob balance should not change - tokens in protocolFees");

        // Bob should have claimable tokens in protocolFees
        // When disputed: previous reporter gets 2 * oldAmount1 + swapFee
        // oldAmount1 = 1e18, swapFee = 1e18 * 3000 / 1e7 = 3e14
        uint256 expectedBobClaimable = 2 * 1e18 + (1e18 * 3000 / 1e7);
        assertEq(oracle.protocolFees(bob, address(token1)), expectedBobClaimable, "Bob protocolFees incorrect");

        // The dispute succeeded - oracle is not bricked
        // Settle to verify the whole flow works
        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        (uint256 price,) = oracle.settle(reportId);

        // Price = amount1 * 1e18 / amount2 = 1.1e18 * 1e18 / 2100e18
        uint256 finalAmount1 = 11e17;
        uint256 finalAmount2 = 2100e18;
        uint256 expectedPrice = (finalAmount1 * 1e18) / finalAmount2;
        assertEq(price, expectedPrice, "Price incorrect after settlement");

        // Bob can claim his funds via protocolFees once unblacklisted
        token1.unblacklist(bob);

        assertEq(oracle.protocolFees(bob, address(token1)), expectedBobClaimable, "Bob claimable should match");

        uint256 bobBalanceBefore = token1.balanceOf(bob);
        vm.prank(bob);
        oracle.getProtocolFees(address(token1));

        assertEq(token1.balanceOf(bob), bobBalanceBefore + expectedBobClaimable, "Bob should receive exact funds");
        assertEq(oracle.protocolFees(bob, address(token1)), 0, "Bob protocolFees should be zero after claim");
    }

    // -------------------------------------------------------------------------
    // Test: Dispute with token2 swap - previous reporter gets blacklisted
    // -------------------------------------------------------------------------
    function testDisputeToken2Swap_PreviousReporterBlacklisted() public {
        // Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                keepFee: true,
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Bob submits initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 6);

        // TROLL ACTION: Blacklist Bob on token2
        token2.blacklist(bob);

        uint256 bobToken2Before = token2.balanceOf(bob);

        // Alice disputes by swapping token2
        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token2),
            1.1e18,      // newAmount1
            2100e18,     // newAmount2
            2000e18,     // amt2Expected
            stateHash
        );

        // Bob's token2 balance shouldn't have increased (tokens went to protocolFees)
        assertEq(token2.balanceOf(bob), bobToken2Before, "Bob token2 balance should not change - tokens in protocolFees");

        // Bob should have claimable token2 in protocolFees
        // When disputed with token2 swap: previous reporter gets 2 * oldAmount2 + swapFee
        // oldAmount2 = 2000e18, swapFee = 2000e18 * 3000 / 1e7 = 6e17
        uint256 expectedBobToken2Claimable = 2 * 2000e18 + (2000e18 * 3000 / 1e7);
        assertEq(oracle.protocolFees(bob, address(token2)), expectedBobToken2Claimable, "Bob token2 protocolFees incorrect");

        // Verify dispute succeeded and oracle not bricked
        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        (uint256 price,) = oracle.settle(reportId);

        // Price = amount1 * 1e18 / amount2 = 1.1e18 * 1e18 / 2100e18
        uint256 finalAmount1 = 11e17;
        uint256 finalAmount2 = 2100e18;
        uint256 expectedPrice = (finalAmount1 * 1e18) / finalAmount2;
        assertEq(price, expectedPrice, "Price incorrect after settlement");
    }

    // -------------------------------------------------------------------------
    // Test: Settle where current reporter is blacklisted on BOTH tokens
    // -------------------------------------------------------------------------
    function testSettle_CurrentReporterBlacklistedBothTokens() public {
        // Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                keepFee: true,
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Bob submits initial report (he will be current reporter at settle time)
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        // Wait for settlement time
        vm.warp(block.timestamp + 301);

        // TROLL ACTION: Blacklist Bob on BOTH tokens before settlement
        token1.blacklist(bob);
        token2.blacklist(bob);

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);
        uint256 charlieETHBefore = charlie.balance;

        // Settle should succeed - funds go to protocolFees
        vm.prank(charlie);
        (uint256 price, uint256 settlementTimestamp) = oracle.settle(reportId);

        // Bob's balances should NOT have changed (tokens went to protocolFees)
        assertEq(token1.balanceOf(bob), bobToken1Before, "Bob token1 should not change");
        assertEq(token2.balanceOf(bob), bobToken2Before, "Bob token2 should not change");

        // Charlie should still get settler reward
        assertEq(charlie.balance, charlieETHBefore + SETTLER_REWARD, "Charlie should get settler reward");

        // Settlement succeeded
        // Price = amount1 * 1e18 / amount2 = 1e18 * 1e18 / 2000e18
        uint256 expectedPrice = (1e18 * 1e18) / 2000e18;
        assertEq(price, expectedPrice, "Price incorrect");
        assertEq(settlementTimestamp, block.timestamp, "Settlement timestamp should be set");

        // Verify Bob has claimable funds in protocolFees
        uint256 bobToken1Claimable = oracle.protocolFees(bob, address(token1));
        uint256 bobToken2Claimable = oracle.protocolFees(bob, address(token2));
        assertEq(bobToken1Claimable, 1e18, "Bob should have token1 in protocolFees");
        assertEq(bobToken2Claimable, 2000e18, "Bob should have token2 in protocolFees");

        // Oracle should still hold the funds (they're in protocolFees mapping)
        assertEq(token1.balanceOf(address(oracle)), 1e18, "Oracle should hold token1");
        assertEq(token2.balanceOf(address(oracle)), 2000e18, "Oracle should hold token2");
    }

    // -------------------------------------------------------------------------
    // Test: Full lifecycle - verify beneficiary can recover via getProtocolFees
    // -------------------------------------------------------------------------
    function testProtocolFeesClaim_BeneficiaryCanRecover() public {
        // Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{value: ORACLE_FEE}(
            OpenOracle.CreateReportParams({
                token1Address: address(token1),
                token2Address: address(token2),
                exactToken1Report: 1e18,
                feePercentage: uint24(3000),
                multiplier: uint16(110),
                settlementTime: uint48(300),
                escalationHalt: 10e18,
                disputeDelay: uint24(5),
                protocolFee: uint24(1000),
                settlerReward: SETTLER_REWARD,
                timeType: true,
                callbackContract: address(0),
                callbackSelector: bytes4(0),
                trackDisputes: false,
                callbackGasLimit: uint32(0),
                keepFee: true,
                protocolFeeRecipient: protocolFeeRecipient
            })
        );

        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        vm.warp(block.timestamp + 301);

        // Blacklist Bob
        token1.blacklist(bob);
        token2.blacklist(bob);

        vm.prank(charlie);
        oracle.settle(reportId);

        // Verify funds are in protocolFees
        assertEq(oracle.protocolFees(bob, address(token1)), 1e18, "Bob should have token1 claimable");
        assertEq(oracle.protocolFees(bob, address(token2)), 2000e18, "Bob should have token2 claimable");

        // Unblacklist Bob
        token1.unblacklist(bob);
        token2.unblacklist(bob);

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);

        // Bob claims via getProtocolFees
        vm.prank(bob);
        oracle.getProtocolFees(address(token1));

        vm.prank(bob);
        oracle.getProtocolFees(address(token2));

        // Verify Bob received the tokens
        assertEq(token1.balanceOf(bob), bobToken1Before + 1e18, "Bob should receive token1");
        assertEq(token2.balanceOf(bob), bobToken2Before + 2000e18, "Bob should receive token2");

        // protocolFees should be zeroed out
        assertEq(oracle.protocolFees(bob, address(token1)), 0, "Bob token1 protocolFees should be zero");
        assertEq(oracle.protocolFees(bob, address(token2)), 0, "Bob token2 protocolFees should be zero");
    }
}
