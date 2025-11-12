// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/OpenOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }
}

contract GasOptimizationLifecycleTest is Test {
    OpenOracle oracle;
    MockERC20 token1;
    MockERC20 token2;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);

    uint256 constant ORACLE_FEE = 0.01 ether;
    uint256 constant SETTLER_REWARD = 0.001 ether;

    function setUp() public {
        oracle = new OpenOracle();
        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");

        // Fund accounts
        token1.transfer(alice, 100 * 10 ** 18);
        token1.transfer(bob, 100 * 10 ** 18);
        token1.transfer(charlie, 100 * 10 ** 18);
        token2.transfer(alice, 100000 * 10 ** 18);
        token2.transfer(bob, 100000 * 10 ** 18);
        token2.transfer(charlie, 100000 * 10 ** 18);

        // Give ETH
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);

        // Approve oracle
        vm.prank(alice);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(alice);
        token2.approve(address(oracle), type(uint256).max);

        vm.prank(bob);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        token2.approve(address(oracle), type(uint256).max);

        vm.prank(charlie);
        token1.approve(address(oracle), type(uint256).max);
        vm.prank(charlie);
        token2.approve(address(oracle), type(uint256).max);
    }

    function testOracleLifecycle() public {
        // Track initial balances
        uint256 aliceToken1Before = token1.balanceOf(alice);
        uint256 aliceToken2Before = token2.balanceOf(alice);
        uint256 aliceETHBefore = alice.balance;

        uint256 bobToken1Before = token1.balanceOf(bob);
        uint256 bobToken2Before = token2.balanceOf(bob);

        uint256 charlieETHBefore = charlie.balance;

        // Create report
        vm.prank(alice);
        uint256 reportId = oracle.createReportInstance{
            value: ORACLE_FEE
        }(
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
                keepFee: false,
                protocolFeeRecipient: address(0)
            })
        );

        // Check Alice paid the oracle fee
        assertEq(alice.balance, aliceETHBefore - ORACLE_FEE, "Alice should have paid oracle fee");
        assertEq(address(oracle).balance, ORACLE_FEE, "Oracle should have received fee");

        // Get state hash
        (bytes32 stateHash,,,,,,,) = oracle.extraData(reportId);

        // Submit initial report
        vm.prank(bob);
        oracle.submitInitialReport(reportId, 1e18, 2000e18, stateHash);

        // Check Bob's tokens were transferred to oracle
        assertEq(token1.balanceOf(bob), bobToken1Before - 1e18, "Bob should have sent 1 token1");
        assertEq(token2.balanceOf(bob), bobToken2Before - 2000e18, "Bob should have sent 2000 token2");
        assertEq(token1.balanceOf(address(oracle)), 1e18, "Oracle should have 1 token1");
        assertEq(token2.balanceOf(address(oracle)), 2000e18, "Oracle should have 2000 token2");

        // Wait for dispute delay
        vm.warp(block.timestamp + 6);

        // Track balances before dispute
        uint256 aliceToken1BeforeDispute = token1.balanceOf(alice);
        uint256 aliceToken2BeforeDispute = token2.balanceOf(alice);
        uint256 bobToken1BeforeDispute = token1.balanceOf(bob);
        uint256 bobToken2BeforeDispute = token2.balanceOf(bob);

        // Dispute and swap
        vm.prank(alice);
        oracle.disputeAndSwap(
            reportId,
            address(token1), // swap token1
            1.1e18, // new amount1 (1.1x)
            2100e18, // new amount2
            2000e18, // expected amount2
            stateHash
        );

        // Calculate fees
        uint256 fee = (1e18 * 3000) / 1e7; // 0.003e18
        uint256 protocolFee = (1e18 * 1000) / 1e7; // 0.001e18

        // Check dispute effects:
        // Alice paid: 1e18 + fee + protocolFee (for swap) + 1.1e18 (new contribution)
        uint256 aliceToken1Spent = 1e18 + fee + protocolFee + 1.1e18;
        assertEq(token1.balanceOf(alice), aliceToken1BeforeDispute - aliceToken1Spent, "Alice token1 after dispute");

        // Alice contributed 100e18 token2 (to make up difference from 2000 to 2100)
        assertEq(token2.balanceOf(alice), aliceToken2BeforeDispute - 100e18, "Alice should have sent 100 token2");

        // Bob (initial reporter) received: 2*1e18 + fee token1
        assertEq(token1.balanceOf(bob), bobToken1BeforeDispute + 2e18 + fee, "Bob should receive refund + fee");

        // Oracle balances after dispute: 1.1e18 token1, 2100e18 token2
        assertEq(token1.balanceOf(address(oracle)), 1.1e18 + protocolFee, "Oracle token1 after dispute");
        assertEq(token2.balanceOf(address(oracle)), 2100e18, "Oracle token2 after dispute");

        // Wait for settlement
        vm.warp(block.timestamp + 300);

        // Track balances before settlement
        uint256 aliceToken1BeforeSettle = token1.balanceOf(alice);
        uint256 aliceToken2BeforeSettle = token2.balanceOf(alice);

        // Settle
        vm.prank(charlie);
        (uint256 price, uint256 settlementTimestamp) = oracle.settle(reportId);

        // Check settlement effects:
        // Charlie gets settler reward
        assertEq(charlie.balance, charlieETHBefore + SETTLER_REWARD, "Charlie should get settler reward");

        // Alice (current reporter after dispute) gets back her tokens
        assertEq(token1.balanceOf(alice), aliceToken1BeforeSettle + 1.1e18, "Alice should get back 1.1 token1");
        assertEq(token2.balanceOf(alice), aliceToken2BeforeSettle + 2100e18, "Alice should get back 2100 token2");

        // Oracle should have no tokens left (except protocol fees)
        assertEq(token1.balanceOf(address(oracle)), protocolFee, "Oracle should only have protocol fee");
        assertEq(token2.balanceOf(address(oracle)), 0, "Oracle should have no token2");

        // Verify settlement data
        assertGt(price, 0, "Price should be set");
        assertEq(settlementTimestamp, block.timestamp, "Settlement timestamp should match");
    }
}
