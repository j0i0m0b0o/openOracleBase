// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/OpenOracle.sol";
import "../src/ToxicWaste.sol";
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

    event ToxicFundsEjected(address indexed token, address indexed to, address airlock, uint256 amount);

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
    // Verifies airlock is deployed and tokens are recoverable
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

        // Alice disputes - Bob should receive tokens via airlock since he's blacklisted
        // newAmount2 (2100e18) > oldAmount2 (2000e18) - no refund to disputer
        vm.expectEmit(true, true, false, false);
        emit ToxicFundsEjected(address(token1), bob, address(0), 0); // We don't know airlock address yet

        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1),
            1.1e18,      // newAmount1
            2100e18,     // newAmount2 > oldAmount2, no refund to disputer
            2000e18,     // amt2Expected
            stateHash
        );

        // Bob's direct balance shouldn't have increased (tokens went to airlock)
        assertEq(token1.balanceOf(bob), bobToken1Before, "Bob balance should not change - tokens in airlock");

        // Find the airlock address from logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address airlockAddress;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("ToxicFundsEjected(address,address,address,uint256)")) {
                airlockAddress = address(uint160(uint256(logs[i].topics[2])));
            }
        }

        // Verify oracle balance - should have newAmount1 + protocolFee
        uint256 protocolFee = (1e18 * 1000) / 1e7;
        assertEq(token1.balanceOf(address(oracle)), 1.1e18 + protocolFee, "Oracle should have newAmount1 + protocolFee");

        // Unblacklist Bob so he can sweep from airlock
        token1.unblacklist(bob);

        // The dispute succeeded - oracle is not bricked
        // Now let's settle to verify the whole flow works
        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        (uint256 price,) = oracle.settle(reportId);

        assertGt(price, 0, "Price should be set after settlement");
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

        // Bob's token2 balance shouldn't have increased (tokens went to airlock)
        assertEq(token2.balanceOf(bob), bobToken2Before, "Bob token2 balance should not change - tokens in airlock");

        // Verify dispute succeeded and oracle not bricked
        vm.warp(block.timestamp + 300);

        vm.prank(charlie);
        (uint256 price,) = oracle.settle(reportId);

        assertGt(price, 0, "Price should be set after settlement");
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

        // Settle should succeed via airlock
        vm.prank(charlie);
        (uint256 price, uint256 settlementTimestamp) = oracle.settle(reportId);

        // Bob's balances should NOT have changed (tokens went to airlocks)
        assertEq(token1.balanceOf(bob), bobToken1Before, "Bob token1 should not change");
        assertEq(token2.balanceOf(bob), bobToken2Before, "Bob token2 should not change");

        // Charlie should still get settler reward
        assertEq(charlie.balance, charlieETHBefore + SETTLER_REWARD, "Charlie should get settler reward");

        // Settlement succeeded
        assertGt(price, 0, "Price should be set");
        assertEq(settlementTimestamp, block.timestamp, "Settlement timestamp should be set");

        // Verify oracle has no tokens left (all went to airlocks)
        assertEq(token1.balanceOf(address(oracle)), 0, "Oracle should have no token1");
        assertEq(token2.balanceOf(address(oracle)), 0, "Oracle should have no token2");
    }

    // -------------------------------------------------------------------------
    // Test: Full lifecycle with airlock sweep - verify beneficiary can recover if not blacklisted
    // -------------------------------------------------------------------------
    function testAirlockSweep_BeneficiaryCanRecover() public {
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

        // Start recording logs to capture airlock addresses
        vm.recordLogs();

        vm.prank(charlie);
        oracle.settle(reportId);

        // Get airlock addresses from logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address token1Airlock;
        address token2Airlock;

        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("ToxicFundsEjected(address,address,address,uint256)")) {
                address token = address(uint160(uint256(logs[i].topics[1])));
                address airlock = abi.decode(logs[i].data, (address));

                if (token == address(token1)) {
                    token1Airlock = airlock;
                } else if (token == address(token2)) {
                    token2Airlock = airlock;
                }
            }
        }

        // Verify airlocks were created
        assertTrue(token1Airlock != address(0), "Token1 airlock should be created");
        assertTrue(token2Airlock != address(0), "Token2 airlock should be created");

        // Verify airlocks have the tokens
        assertEq(token1.balanceOf(token1Airlock), 1e18, "Token1 airlock should have tokens");
        assertEq(token2.balanceOf(token2Airlock), 2000e18, "Token2 airlock should have tokens");

        // Verify airlock beneficiary is Bob
        assertEq(ToxicAirlock(token1Airlock).beneficiary(), bob, "Token1 airlock beneficiary should be Bob");
        assertEq(ToxicAirlock(token2Airlock).beneficiary(), bob, "Token2 airlock beneficiary should be Bob");

        // Unblacklist Bob
        token1.unblacklist(bob);
        token2.unblacklist(bob);

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);

        // Bob sweeps from airlocks
        ToxicAirlock(token1Airlock).sweep(address(token1));
        ToxicAirlock(token2Airlock).sweep(address(token2));

        // Verify Bob received the tokens
        assertEq(token1.balanceOf(bob), bobToken1Before + 1e18, "Bob should receive token1 from airlock");
        assertEq(token2.balanceOf(bob), bobToken2Before + 2000e18, "Bob should receive token2 from airlock");

        // Airlocks should be empty
        assertEq(token1.balanceOf(token1Airlock), 0, "Token1 airlock should be empty");
        assertEq(token2.balanceOf(token2Airlock), 0, "Token2 airlock should be empty");
    }
}
